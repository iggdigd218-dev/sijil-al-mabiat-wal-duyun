import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/accounting.dart';
import '../core/ids.dart';
import '../core/database.dart';
import '../core/secret_store.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/workspace_mode.dart';
import 'sync/device_id.dart';
import 'sync/google_auth_service.dart';
import 'sync/operation.dart';
import 'sync/recorder.dart';
import 'sync/sync_queue.dart';
import 'sync/workspace_service.dart';

/// خطأ استعادة واضح؛ لا تُعاد رسالة نجاح عند حدوثه.
class BackupImportException implements Exception {
  final String message;

  const BackupImportException(this.message);

  @override
  String toString() => message;
}

/// مستودع البيانات — كل قراءة وكتابة تمرّ من هنا.
class Repo {
  /// Optional injection keeps multi-device QA databases independent. Production
  /// callers still use the existing application database by default.
  Repo({Future<Database> Function()? databaseProvider})
      : _databaseProvider = databaseProvider;

  final Future<Database> Function()? _databaseProvider;
  Future<Database> get _db async => _databaseProvider != null
      ? _databaseProvider()
      : AppDatabase.instance.database;
  Future<Database> get database async => _db;

  String? _deviceId;
  String? _workspaceId;
  int? _currentUserId;

  /// تهيئة البنية التحتية للمزامنة (تُستدعى مرة واحدة عند بدء التطبيق).
  Future<void> initSyncInfra() async {
    final db = await _db;
    // إنشاء Workspace افتراضي إن لم يوجد.
    _workspaceId = await ensureWorkspace(db, repo: this);
    // توليد deviceId ثابت.
    _deviceId = await ensureDeviceId(this);
    // تسجيل هذا الجهاز في جدول devices إن لم يكن مسجلاً.
    final now = DateTime.now().toIso8601String();
    await db.insert(
        'devices',
        {
          'id': _deviceId,
          'workspace_id': _workspaceId,
          'name': await deviceName(this),
          'platform': Platform.operatingSystem,
          'is_paired': 1,
          'is_owner': 1, // الجهاز المحلي في الوضع المستقل هو المالك.
          // (دفعة 57) السر يُخزَّن معمّى — لا نص صريح على القرص.
          'auth_secret': await SecretStore.protect(generateDeviceSecret()),
          'revoked_at': '',
          'last_seen_at': now,
          'last_sync_at': '',
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);

    // 🛟 بذرة مستخدم مدير افتراضي في أول تشغيل (إذا كان جدول المستخدمين فارغًا).
    final existingUsers = await db.query('users', limit: 1);
    if (existingUsers.isEmpty) {
      final adminPerms = defaultPerms(UserRole.admin);
      final permStr =
          adminPerms.entries.where((e) => e.value).map((e) => e.key).join(',');
      await db.insert('users', {
        'name': 'المدير',
        'role': 'admin',
        'pin': '',
        'password': '',
        'permissions': permStr,
        'is_me': 1,
        'active': 1,
        'workspace_id': _workspaceId,
        'deleted_at': '',
        'created_at': now,
        'updated_at': now,
      });
    }

    // المستخدم الحالي.
    final me = await currentUser();
    _currentUserId = me?.id;

    // تأكد من أن جهازنا مرتبط بالمستخدم الحالي (في الوضع المستقل/المضيف).
    if (_deviceId != null && _currentUserId != null) {
      final myDev = await db.query(
        'devices',
        where: 'id = ?',
        whereArgs: [_deviceId],
        limit: 1,
      );
      if (myDev.isNotEmpty) {
        final existingUid = myDev.first['user_id'] as int?;
        final existingOwner = (myDev.first['is_owner'] ?? 0) as int;
        if (existingUid != _currentUserId || existingOwner == 1) {
          await db.update(
            'devices',
            {'user_id': _currentUserId, 'paired_by': _currentUserId},
            where: 'id = ?',
            whereArgs: [_deviceId],
          );
        }
      }
    }

    // استعادة جلسة Google بصمت (لا فتح نوافذ).
    try {
      final authSvc = GoogleAuthService(db);
      final ar = await authSvc.restoreSession();
      final gu = ar.user;
      if (gu != null && gu.id.isNotEmpty) {
        await linkWorkspaceToGoogle(
          db,
          workspaceId: _workspaceId!,
          googleId: gu.id,
          email: gu.email,
          name: gu.displayName ?? '',
        );
      }
    } catch (_) {}
  }

  String get requireDeviceId {
    if (_deviceId == null) {
      // (دفعة 57) إنهاء التراجع الصامت 'DEVICE-UNKNOWN': معرف زائف كان
      // يتسرب إلى سجل العمليات ويكسر نسب العمليات بين الأجهزة.
      // نطلق إصلاحاً ذاتياً في الخلفية ثم نفشل بصوت عالٍ — أي عملية
      // كتابة قبل اكتمال تهيئة المزامنة يجب أن تُرفض لا أن تُزوَّر.
      unawaited(initSyncInfra().catchError((_) {}));
      throw StateError(
          'هوية الجهاز غير مهيأة بعد — أعد المحاولة خلال لحظات '
          '(initSyncInfra لم يكتمل).');
    }
    return _deviceId!;
  }

  String get requireWorkspaceId => _workspaceId ?? defaultWorkspaceId;

  // ---------- حالة المساحة (مستقل/مرتبط) ----------

  Future<String> workspaceMode() async {
    final db = await _db;
    final r = await db.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['workspaceMode'],
      limit: 1,
    );
    if (r.isEmpty) return 'standalone';
    // تطبيع القيم القديمة: 'managed' كانت تُستخدم قديماً بمعنى 'host'.
    final mode =
        WorkspaceMode.parse(r.first['value'] as String?).storageValue;
    return mode;
  }

  /// وضع المساحة كـ enum مُطبَّع — الاستخدام المفضّل في الكود الجديد.
  Future<WorkspaceMode> workspaceModeEnum() async =>
      WorkspaceMode.parse(await workspaceMode());

  Future<bool> isWorkspaceOwner() async {
    if (_deviceId == null) return true; // قبل التهيئة اعتبره مستقلاً.
    final db = await _db;
    final r = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [_deviceId],
      limit: 1,
    );
    if (r.isEmpty) return true;
    return ((r.first['is_owner'] ?? 0) as int) == 1;
  }

  /// الجهاز الذي نحن عليه الآن (سجلنا في جدول devices).
  Future<Map<String, Object?>?> ownDeviceRow() async {
    if (_deviceId == null) return null;
    final db = await _db;
    final r = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [_deviceId],
      limit: 1,
    );
    return r.isEmpty ? null : r.first;
  }

  /// دور المستخدم الموكّل لهذا الجهاز، أو null إذا لم يُعيَّن بعد (عضو جديد بلا صلاحيات).
  Future<AppUser?> deviceAssignedUser() async {
    final row = await ownDeviceRow();
    if (row == null) return null;
    final uid = row['user_id'] as int?;
    if (uid == null) return null;
    return userById(uid);
  }

  Future<AppUser?> userById(int id) async {
    final db = await _db;
    final r = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (r.isEmpty) return null;
    return AppUser.fromMap(r.first);
  }

  /// تُستدعى على الجهاز المُضيف (المالك) عند استقبال طلب اقتران ناجح:
  /// يُحوّل الوضع إلى مُدار ويُسجّل الجهاز الجديد كعضو.
  Future<void> markAsHostAfterPairing(String newDeviceId) async {
    final db = await _db;
    // أنا المالك.
    if (_deviceId != null) {
      await db.update(
        'devices',
        {'is_owner': 1, 'is_paired': 1},
        where: 'id = ?',
        whereArgs: [_deviceId],
      );
    }
    await db.update(
      'devices',
      {'is_owner': 0, 'is_paired': 1},
      where: 'id = ?',
      whereArgs: [newDeviceId],
    );
    await db.insert(
        'sync_meta',
        {
          'key': 'workspaceMode',
          // توحيد التسمية: 'host' دائماً (كانت 'managed' قديماً).
          'value': WorkspaceMode.host.storageValue,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// (دفعة 55 — المدير فقط) حل المجموعة محلياً بعد بث شواهد الطرد للسحابة:
  /// - دفاتر المدير (حسابات/عمليات/أصناف/سندات...) تبقى كما هي — لا تُمس.
  /// - تُحذف كل أجهزة الأعضاء من devices (يبقى جهاز المدير وحده مالكاً).
  /// - يُحذف كل المستخدمين عدا مستخدم المدير نفسه.
  /// - تُحذف كل المحادثات والرسائل (فردية وجماعية) — لم يعد ثمة أعضاء.
  /// - يُفرَّغ طابور المزامنة (لا وجهات باقية).
  /// - الوضع يعود standalone، ويمكن للمدير إنشاء مجموعة جديدة فوراً
  ///   بدعوات جديدة (رابط السحابة يبقى محفوظاً لإعادة الاستخدام).
  Future<void> dissolveGroupLocally() async {
    if (!await isWorkspaceOwner()) {
      throw StateError('حل المجموعة متاح لجهاز المدير فقط.');
    }
    final db = await _db;
    // هوية جهازنا: المصدر الأول إعداد sync.deviceId (الحقيقة المعلنة
    // للسحابة)، ثم الهوية الداخلية كاحتياط.
    final ownId =
        (await settings())['sync.deviceId'] ?? _deviceId ?? '';
    await db.transaction((txn) async {
      // أجهزة الأعضاء تُحذف نهائياً — جهازنا يبقى مالكاً نظيفاً.
      await txn.delete('devices', where: 'id <> ?', whereArgs: [ownId]);
      await txn.update(
        'devices',
        {
          'is_owner': 1,
          'is_paired': 1,
          'revoked_at': '',
          'expelled_at': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [ownId],
      );
      // المستخدمون: يبقى مستخدم المدير (is_me) وحده.
      await txn.delete('users', where: 'is_me <> 1');
      // الدردشات كلها تسقط مع المجموعة.
      await txn.delete('messages');
      await txn.delete('conversations');
      // طابور المزامنة: لا وجهات باقية.
      await txn.delete('sync_queue');
      // الوضع مستقل.
      await txn.insert(
          'sync_meta',
          {'key': 'workspaceMode', 'value': 'standalone'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// العودة إلى الوضع المستقل (يُستخدم فقط بعد طرد المدير لنا أو كخطة استرداد).
  /// ملاحظة: لا يستطيع العضو طلب الخروج بنفسه — الطرد بيد المدير فقط.
  Future<void> _resetToStandalone() async {
    final db = await _db;
    final devName = await deviceName(this);
    final adminPerms = defaultPerms(UserRole.admin);
    final permStr =
        adminPerms.entries.where((e) => e.value).map((e) => e.key).join(',');
    final newSecret = await SecretStore.protect(generateDeviceSecret());
    await db.transaction((txn) async {
      const tables = [
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'operations',
        'sync_queue',
      ];
      for (final t in tables) {
        await txn.delete(t);
      }
      await txn.delete('devices');
      final now = DateTime.now().toIso8601String();
      await txn.insert('devices', {
        'id': _deviceId,
        'workspace_id': requireWorkspaceId,
        'name': devName,
        'platform': Platform.operatingSystem,
        'is_paired': 1,
        'is_owner': 1,
        'auth_secret': newSecret,
        'revoked_at': '',
        'last_seen_at': now,
        'last_sync_at': '',
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('users', {
        'name': 'المدير',
        'role': 'admin',
        'pin': '',
        'password': '',
        'permissions': permStr,
        'is_me': 1,
        'active': 1,
        'workspace_id': requireWorkspaceId,
        'deleted_at': '',
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert(
          'sync_meta',
          {
            'key': 'workspaceMode',
            'value': 'standalone',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _currentUserId = null;
    final me = await currentUser();
    _currentUserId = me?.id;
    // إبطال الجلسة بالكامل: الجهاز المطرود يعود لشاشة الإعداد الأول
    // (onboarding) عند التشغيل التالي — قاعدة نظيفة وهوية جديدة.
    try {
      final db2 = await _db;
      await db2.delete('settings',
          where: 'key IN (?, ?, ?)',
          whereArgs: [
            'has_completed_onboarding',
            'cloudBackendUrl',
            'cloudCode',
          ]);
    } catch (_) {}
  }

  /// مسح كل البيانات المحلية على العضو الجديد ليستبدلها بنسخة المضيف.
  /// العملية داخل transaction لضمان النزاهة.
  Future<void> wipeLocalDataForJoin() async {
    final db = await _db;
    await db.transaction((txn) async {
      const entityTables = [
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'operations',
        'sync_queue',
      ];
      for (final t in entityTables) {
        await txn.delete(t);
      }
      // لا نحذف devices (يبقى سجلنا وسجل المضيف)، ولا نحذف workspace ولا sync_meta.
      // جهازي لم يعد مالكاً.
      if (_deviceId != null) {
        await txn.update(
          'devices',
          {'is_owner': 0, 'user_id': null, 'is_paired': 1},
          where: 'id = ?',
          whereArgs: [_deviceId],
        );
      }
      // ضبط الوضع كـ عضو.
      await txn.insert(
          'sync_meta',
          {
            'key': 'workspaceMode',
            'value': 'member',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// مسجّل جديد داخل معاملة.
  Future<SyncRecorder> newRecorder(Transaction txn) async {
    return SyncRecorder(
      db: txn,
      deviceId: requireDeviceId,
      workspaceId: requireWorkspaceId,
      userId: _currentUserId,
    );
  }

  /// مسجّل بسيط خارج المعاملة — يُستخدم كحل آمن بعد الحفظ دون إعادة هيكلة الدوال.
  Future<void> queueOperation({
    required EntityKind entityType,
    required String entityId,
    required OpKind opType,
    required Map<String, Object?> payload,
  }) async {
    final db = await _db;
    final rec = SyncRecorder(
      db: db,
      deviceId: requireDeviceId,
      workspaceId: requireWorkspaceId,
      userId: _currentUserId,
    );
    await rec.record(
      entityType: entityType,
      entityId: entityId,
      opType: opType,
      payload: payload,
    );
  }

  // ==================== الحسابات ====================

  Future<List<Account>> accounts({
    bool includeArchived = false,
    bool includeDeleted = false,
  }) async {
    final db = await _db;
    final where = StringBuffer(includeArchived ? '1=1' : 'archived = 0');
    if (!includeDeleted) where.write(" AND COALESCE(deleted_at,'') = ''");
    final rows = await db.query(
      'accounts',
      where: where.toString(),
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(Account.fromMap).toList();
  }

  Future<Account?> account(int id) async {
    final db = await _db;
    final r = await db.query('accounts', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Account.fromMap(r.first);
  }

  Future<int> saveAccount(Account a) async {
    await _ensureCan(a.id == null ? 'add_tx' : 'edit_tx');
    final db = await _db;
    final id = await db.transaction<int>((txn) async {
      final map = a.toMap();
      map['workspace_id'] = requireWorkspaceId;
      map.remove('id');
      map['updated_at'] = DateTime.now().toIso8601String();
      late int newId;
      late OpKind op;
      if (a.id == null) {
        map['id'] = newGlobalId();
        newId = await txn.insert('accounts', map);
        op = OpKind.create;
      } else {
        newId = a.id!;
        await txn.update('accounts', map, where: 'id = ?', whereArgs: [newId]);
        op = OpKind.update;
      }
      await SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      ).record(
        entityType: EntityKind.account,
        entityId: '$newId',
        opType: op,
        payload: {...map, 'id': newId},
      );
      await txn.insert(
          'activity',
          {
            'text': op == OpKind.create
                ? 'إضافة حساب: ${a.name}'
                : 'تعديل حساب: ${a.name}',
            'ref_type': 'account',
            'ref_id': '$newId',
            'workspace_id': requireWorkspaceId,
            'created_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return newId;
    });
    return id;
  }

  /// الأرشفة بدل الحذف — كما في نسخة الويب.
  Future<void> archiveAccount(int id, bool archived) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'accounts',
        {'archived': archived ? 1 : 0, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      final rec = SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      );
      final row = (await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      ))
          .first;
      await rec.record(
        entityType: EntityKind.account,
        entityId: '$id',
        opType: OpKind.update,
        payload: Map<String, Object?>.from(row),
      );
    });
    await logActivity(
      archived ? 'أرشفة حساب' : 'استعادة حساب',
      'account',
      '$id',
    );
  }

  /// حذف ناعم (soft delete): لا يُحذف السجل فعليًا، بل يوضع deleted_at.
  /// يُضاف سجل متوافق مع جدول trash القديم لاستمرار عمل شاشة سلة المحذوفات.
  Future<void> deleteAccount(int id) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final a = await account(id);
    if (a == null) return;
    await db.transaction((txn) async {
      await txn.update(
        'accounts',
        {'deleted_at': now, 'deleted_by': _currentUserId, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      final updated = (await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      ))
          .first;
      await SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      ).record(
        entityType: EntityKind.account,
        entityId: '$id',
        opType: OpKind.delete_,
        payload: Map<String, Object?>.from(updated),
      );
      await txn.insert('trash', {
        'store': 'accounts',
        'payload': jsonEncode(a.toMap()),
        'label': 'حساب: ${a.name}',
        'created_at': now,
      });
    });
    await logActivity('حذف حساب: ${a.name}', 'account', '$id');
  }

  // ==================== العمليات ====================

  Future<Tx?> transactionById(int id) async {
    final db = await _db;
    final rows = await db.query('transactions',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Tx.fromMap(rows.first);
  }

  Future<void> updateTxImage(int id, String path) async {
    await _ensureCan('edit_tx');
    final db = await _db;
    final mode = await workspaceMode();
    final imgHash = await MediaPaths.fileHash(path);
    await db.transaction((txn) async {
      final rows = await txn.query('transactions',
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) throw StateError('العملية غير موجودة.');
      final patch = <String, Object?>{
        'image': MediaPaths.toRelative(path),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_state': mode == 'standalone' ? 'synced' : 'pending',
      };
      final hasAtt =
          ((rows.first['attachment'] as String?) ?? '').isNotEmpty;
      // لا نطمس تجزئة مرفق أصلي بصورة إيصال مولّدة.
      if (!hasAtt && imgHash.isNotEmpty) patch['attachment_hash'] = imgHash;
      await txn.update('transactions', patch, where: 'id = ?', whereArgs: [id]);
      await SyncRecorder(
              db: txn,
              deviceId: requireDeviceId,
              workspaceId: requireWorkspaceId,
              userId: _currentUserId)
          .record(
        entityType: EntityKind.tx,
        entityId: '$id',
        opType: OpKind.update,
        payload: {...rows.first, ...patch},
      );
    });
  }

  Future<List<Tx>> transactions({
    int? accountId,
    DateTime? from,
    DateTime? to,
    OpType? type,
    bool includeDeleted = false,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (!includeDeleted) {
      where.add("COALESCE(deleted_at,'') = ''");
    }
    if (accountId != null) {
      // التحويل يمسّ الحساب عبر from_id/to_id أيضًا.
      where.add('(account_id = ? OR from_id = ? OR to_id = ?)');
      args.addAll([accountId, accountId, accountId]);
    }
    if (from != null) {
      where.add('date >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('date <= ?');
      args.add(to.toIso8601String());
    }
    if (type != null) {
      where.add('type = ?');
      args.add(type.code);
    }
    final rows = await db.query(
      'transactions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC, id DESC',
    );
    return rows.map(Tx.fromMap).toList();
  }

  /// يحفظ العملية وسطور الفاتورة معًا. تمرير [items] (حتى لو كانت فارغة)
  /// يستبدل السطور القديمة، أما null فيُبقيها كما هي عند تحديث الصورة.
  Future<int> saveTx(Tx tx, {List<InvoiceLine>? items}) async {
    // معرّف الحساب 0 يعني "بدون حساب" (بيع نقدي لعميل عابر). نخزّنه NULL
    // حتى لا يكسر قيد المفتاح الأجنبي (FOREIGN KEY 787).
    final t = (tx.accountId == 0 || tx.fromId == 0 || tx.toId == 0)
        ? tx.copyWith(
            accountId: tx.accountId == 0 ? null : tx.accountId,
            clearAccountId: tx.accountId == 0,
            fromId: tx.fromId == 0 ? null : tx.fromId,
            clearFromId: tx.fromId == 0,
            toId: tx.toId == 0 ? null : tx.toId,
            clearToId: tx.toId == 0,
          )
        : tx;
    if (!t.amount.isFinite || t.amount <= 0) {
      throw StateError('أدخل مبلغًا صحيحًا أكبر من صفر.');
    }
    if (t.currency.trim().isEmpty) throw StateError('اختر العملة.');
    if (t.type == OpType.transfer) {
      if (t.fromId == null || t.toId == null || t.fromId == t.toId) {
        throw StateError('اختر حسابي تحويل مختلفين.');
      }
      if (!t.rate.isFinite || t.rate <= 0) {
        throw StateError('أدخل سعر صرف صحيحًا أكبر من صفر.');
      }
    } else if (t.accountId == null && !_allowsAnonymousAccount(t.type)) {
      throw StateError('اختر الحساب.');
    }
    await _ensureCan(t.id == null ? 'add_tx' : 'edit_tx')
        .timeout(const Duration(seconds: 4));
    // القفل التاريخي: تعديل سجل قديم محظور على غير المدير.
    if (t.id != null) await _ensureNotAuditLocked(t.id!);
    final db = await _db;
    String mode;
    try {
      mode = await workspaceMode().timeout(
        const Duration(seconds: 2),
        onTimeout: () => 'standalone',
      );
    } catch (_) {
      mode = 'standalone';
    }
    final newSync = mode == 'standalone' ? 'synced' : 'pending';
    // تجزئة SHA-256 للمرفق/صورة الإيصال (إن وجدت) — تُحسب خارج المعاملة
    // لأنها قراءة ملف، وتُخزَّن في attachment_hash لجلب الملف عبر LAN.
    var attHash = '';
    final attSource = t.attachment.isNotEmpty ? t.attachment : t.image;
    if (attSource.isNotEmpty) {
      attHash = await MediaPaths.fileHash(attSource);
    }
    // نخزّن المسارات نسبيةً من جذر documents حتى تبقى صالحة بعد تحديث
    // التطبيق ولا تُسرَّب مسارات مطلقة بلا معنى للأجهزة الأخرى في المزامنة.
    final relAttachment = MediaPaths.toRelative(t.attachment);
    final relImage = MediaPaths.toRelative(t.image);
    late final int id;
    await db.transaction((txn) async {
      final rec = SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      );
      final now = DateTime.now().toIso8601String();
      if (t.id == null) {
        var ref = t.reference.trim();
        if (ref.isEmpty) {
          ref = await _nextSequence(txn, 'counter_tx', table: 'transactions');
        }
        final toSave = t.copyWith(
          reference: ref,
          syncState: newSync,
          attachmentHash: attHash,
          attachment: relAttachment,
          image: relImage,
        );
        final map = toSave.toMap();
        map['workspace_id'] = requireWorkspaceId;
        map['id'] = newGlobalId();
        map['updated_at'] = now;
        id = await txn.insert('transactions', map);
        final saved = Map<String, Object?>.from(map)..['id'] = id;
        if (items != null) {
          await txn.delete(
            'transaction_items',
            where: 'tx_id = ?',
            whereArgs: [id],
          );
          for (final line in items) {
            final lm = line.toMap(transactionId: id);
            lm['workspace_id'] = requireWorkspaceId;
            lm['id'] = newGlobalId();
            await txn.insert('transaction_items', lm);
          }
        }
        await rec.record(
          entityType: EntityKind.tx,
          entityId: '$id',
          opType: OpKind.create,
          payload: saved..['items'] = await _lineMaps(txn, id),
        );
      } else {
        id = t.id!;
        final toSave = t.copyWith(
          syncState: newSync,
          attachmentHash: attHash,
          attachment: relAttachment,
          image: relImage,
        );
        final map = toSave.toMap();
        map['workspace_id'] = requireWorkspaceId;
        map.remove('id');
        map['updated_at'] = now;
        await txn.update('transactions', map, where: 'id = ?', whereArgs: [id]);
        if (items != null) {
          await txn.delete(
            'transaction_items',
            where: 'tx_id = ?',
            whereArgs: [id],
          );
          for (final line in items) {
            final lm = line.toMap(transactionId: id);
            lm['workspace_id'] = requireWorkspaceId;
            lm['id'] = newGlobalId();
            await txn.insert('transaction_items', lm);
          }
        }
        final saved = Map<String, Object?>.from(map)..['id'] = id;
        await rec.record(
          entityType: EntityKind.tx,
          entityId: '$id',
          opType: OpKind.update,
          payload: saved..['items'] = await _lineMaps(txn, id),
        );
      }
      await logActivityTx(
        txn,
        t.id == null ? '${t.type.label}: ${t.amount}' : 'تعديل عملية',
        'tx',
        '$id',
      );
    });
    return id;
  }

  /// سطور الفاتورة بصيغة خرائط لإرفاقها في حمولة المزامنة.
  Future<List<Map<String, Object?>>> _lineMaps(
      DatabaseExecutor txn, int txId) async {
    final rows = await txn.query('transaction_items',
        where: 'tx_id = ?', whereArgs: [txId], orderBy: 'id ASC');
    return rows.map(Map<String, Object?>.from).toList();
  }

  /// العمليات النقدية (إيراد/مصروف/قبض/صرف) يمكن حفظها بدون حساب مرتبط،
  /// مثل بيع نقدي لعميل عابر في نقطة البيع.
  static bool _allowsAnonymousAccount(OpType type) =>
      type == OpType.revenue ||
      type == OpType.expense ||
      type == OpType.inflow ||
      type == OpType.outflow;

  /// تفاصيل الأصناف المرتبطة بعملية مالية.
  Future<List<InvoiceLine>> transactionItems(int txId) async {
    final db = await _db;
    final rows = await db.query(
      'transaction_items',
      where: 'tx_id = ?',
      whereArgs: [txId],
      orderBy: 'id ASC',
    );
    return rows.map(InvoiceLine.fromMap).toList();
  }

  /// القفل التاريخي للتدقيق: إعداد `auditLockDays` (0 = معطل) يمنع غير
  /// المدير من تعديل/حذف عملية مالية أقدم من المدة المحددة — حماية دفترية
  /// من العبث بالسجلات المُقفلة محاسبياً.
  Future<void> _ensureNotAuditLocked(int txId) async {
    final st = await settings();
    final days = int.tryParse(st['auditLockDays'] ?? '0') ?? 0;
    if (days <= 0) return;
    final me = await currentUser();
    if (me == null || me.role == UserRole.admin) return; // المدير مستثنى.
    final db = await _db;
    final rows = await db.query('transactions',
        columns: ['date'], where: 'id = ?', whereArgs: [txId], limit: 1);
    if (rows.isEmpty) return;
    final d = DateTime.tryParse('${rows.first['date']}');
    if (d == null) return;
    if (DateTime.now().difference(d).inDays >= days) {
      throw StateError(
          'هذا السجل أقدم من $days يوماً ومقفل ضد التعديل والحذف. '
          'يتطلب صلاحية المدير.');
    }
  }

  Future<void> deleteTx(int id) async {
    await _ensureCan('delete_tx');
    await _ensureNotAuditLocked(id);
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return;
    await db.transaction((txn) async {
      await txn.update(
        'transactions',
        {'deleted_at': now, 'deleted_by': _currentUserId, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      final updated = (await txn.query(
        'transactions',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      ))
          .first;
      await SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      ).record(
        entityType: EntityKind.tx,
        entityId: '$id',
        opType: OpKind.delete_,
        payload: Map<String, Object?>.from(updated),
      );
      await txn.insert('trash', {
        'store': 'transactions',
        'payload': jsonEncode({
          'transaction': Map.from(rows.first),
          'items': [],
        }),
        'label':
            'عملية بمبلغ ${rows.first['amount']} ${rows.first['currency']}',
        'created_at': now,
      });
    });
    await logActivity('حذف عملية', 'tx', '$id');
  }

  /// كشف العمليات المكررة — تحذير لا منع، كما في نسخة الويب.
  Future<List<Tx>> findDuplicates(Tx t) async {
    final all = await transactions(accountId: t.accountId);
    return all.where((x) {
      if (x.id == t.id) return false;
      if (x.type != t.type || x.amount != t.amount) return false;
      if (x.currency != t.currency) return false;
      if (x.date.difference(t.date).inDays.abs() > 0) return false;
      return x.createdAt.difference(t.createdAt).inMilliseconds.abs() < 120000;
    }).toList();
  }

  // ==================== الأرصدة ====================

  /// رصيد حساب واحد = الافتتاحي + أثر كل العمليات.
  ///
  /// يُحسب دائمًا من السجل ولا يُخزَّن أبدًا، فلا يمكن أن يتعارض.
  Future<double> balanceOf(Account a) async {
    if (a.id == null) return a.openingBalance;
    final txs = await transactions(accountId: a.id);
    var bal = a.openingBalance;
    for (final t in txs) {
      final e = t.effectOn(a.id!);
      if (e != null) bal += e;
    }
    return bal;
  }

  /// أرصدة كل الحسابات دفعة واحدة — استعلام واحد بدل استعلام لكل حساب.
  Future<Map<int, double>> allBalances(List<Account> accounts) async {
    final db = await _db;
    final rows = await db.query(
      'transactions',
      where: "COALESCE(deleted_at, '') = ''",
    );
    final txs = rows.map(Tx.fromMap).toList();
    final out = <int, double>{};
    for (final a in accounts) {
      if (a.id == null) continue;
      var bal = a.openingBalance;
      for (final t in txs) {
        final e = t.effectOn(a.id!);
        if (e != null) bal += e;
      }
      out[a.id!] = bal;
    }
    return out;
  }

  // ==================== العملات ====================

  Future<List<CurrencyDef>> currencies() async {
    final db = await _db;
    // (دفعة 57) عزل بالمساحة النشطة: أسعار صرف مجموعة لا تلوّث الأخرى.
    final rows = await db.query('currencies',
        where: 'workspace_id = ?', whereArgs: [requireWorkspaceId]);
    if (rows.isEmpty) return kDefaultCurrencies;
    return rows.map(CurrencyDef.fromMap).toList();
  }

  Future<void> saveCurrency(CurrencyDef c, {double rate = 1}) async {
    final db = await _db;
    final payload = {
      ...c.toMap(),
      'rate': rate,
      // (دفعة 57) المفتاح المركّب (code, workspace_id) — ختم المساحة.
      'workspace_id': requireWorkspaceId,
    };
    await db.insert(
      'currencies',
      payload,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await queueOperation(
      entityType: EntityKind.currency,
      entityId: c.code,
      opType: OpKind.update,
      payload: payload,
    );
  }

  Future<void> deleteCurrency(String code) async {
    final db = await _db;
    await db.delete('currencies',
        where: 'code = ? AND workspace_id = ?',
        whereArgs: [code, requireWorkspaceId]);
    await queueOperation(
      entityType: EntityKind.currency,
      entityId: code,
      opType: OpKind.delete_,
      payload: {'code': code},
    );
  }

  // ==================== الإعدادات ====================

  Future<Map<String, String>> settings() async {
    final db = await _db;
    final rows = await db.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  Future<void> setSetting(String key, String value) async {
    final db = await _db;
    await db.insert(
        'settings',
        {
          'key': key,
          'value': value,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ==================== سجل النشاط ====================

  Future<void> logActivity(String text, String refType, String refId) async {
    final db = await _db;
    await db.insert('activity', {
      'text': text,
      'ref_type': refType,
      'ref_id': refId,
      'user_name': 'المدير',
      'workspace_id': _workspaceId ?? defaultWorkspaceId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> logActivityTx(
    Transaction txn,
    String text,
    String refType,
    String refId,
  ) async {
    await txn.insert('activity', {
      'text': text,
      'ref_type': refType,
      'ref_id': refId,
      'user_name': 'المدير',
      'workspace_id': _workspaceId ?? defaultWorkspaceId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> recentActivity({int limit = 50}) async {
    final db = await _db;
    return db.query('activity', orderBy: 'id DESC', limit: limit);
  }

  // ==================== السندات ====================

  Future<List<Voucher>> vouchers({
    VoucherKind? kind,
    String? status,
    bool includeDeleted = false,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (!includeDeleted) where.add("COALESCE(deleted_at,'') = ''");
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind.code);
    }
    if (status != null && status.isNotEmpty) {
      where.add('status = ?');
      args.add(status);
    }
    final rows = await db.query(
      'vouchers',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id DESC',
    );
    return rows.map(Voucher.fromMap).toList();
  }

  Future<Voucher?> voucher(int id) async {
    final db = await _db;
    final r = await db.query('vouchers', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Voucher.fromMap(r.first);
  }

  /// ترقيم رقمي تسلسلي بحت (بدون أحرف/بادئات).
  Future<String> nextSeq(String counterKey, {String? table}) async {
    final db = await _db;
    return db
        .transaction((txn) => _nextSequence(txn, counterKey, table: table));
  }

  Future<String> _nextSequence(DatabaseExecutor db, String counterKey,
      {String? table}) async {
    final rows = await db.query('settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [counterKey],
        limit: 1);
    var counter =
        rows.isEmpty ? 0 : int.tryParse('${rows.first['value']}') ?? 0;
    if (table != null && !const {'transactions', 'vouchers'}.contains(table)) {
      throw ArgumentError.value(table, 'table');
    }
    // ملاحظة: المعرّفات (id) صارت عالمية غير متسلسلة، لذلك لم يعد العدّاد
    // يعتمد على MAX(id)؛ الرقم التسلسلي هنا للعرض على الإيصال/إشعار العميل فقط.
    if (table == 'transactions') {
      final r = await db.rawQuery(
          "SELECT MAX(CAST(reference AS INTEGER)) AS m FROM transactions "
          "WHERE reference GLOB '[0-9]*'");
      final maxRef = (r.first['m'] as int?) ?? 0;
      if (maxRef > counter) counter = maxRef;
    }
    final nextNum = counter + 1;
    await db.insert('settings', {'key': counterKey, 'value': '$nextNum'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    // داخل مجموعة: رقم الفاتورة المعروض يسبقه رمز الجهاز حتى لا يتصادم
    // جهازان أنشآ الفاتورة نفسها بالتوازي (POS1-00142 مقابل POS2-00142).
    // المعرّف الداخلي (id) يبقى Snowflake عالمي الفرادة — هذا للعرض فقط.
    if (table == 'transactions') {
      try {
        final wm = await db.query('sync_meta',
            columns: ['value'],
            where: 'key = ?',
            whereArgs: ['workspaceMode'],
            limit: 1);
        final mode = WorkspaceMode.parse(
            wm.isEmpty ? null : wm.first['value'] as String?);
        if (mode.inGroup) {
          final devRows = await db.query('settings',
              columns: ['value'],
              where: 'key = ?',
              whereArgs: ['sync.deviceId'],
              limit: 1);
          final devId =
              devRows.isEmpty ? '' : '${devRows.first['value'] ?? ''}';
          final code = devId.replaceFirst('DEVICE-', '');
          if (code.length >= 4) {
            final prefix = code.substring(0, 4);
            return '$prefix-${'$nextNum'.padLeft(5, '0')}';
          }
        }
      } catch (_) {
        // بيئة اختبار بلا sync_meta — رقم بحت.
      }
    }
    return '$nextNum';
  }

  /// الرقم التسلسلي التالي لأي عملية مالية (رقمي بحت).
  Future<String> nextTxNumber() => nextSeq('counter_tx', table: 'transactions');

  /// الرقم التسلسلي التالي للسند مع البادئة الحرفية حسب النوع.
  Future<String> nextVoucherNumber(VoucherKind kind) async {
    final key = 'counter_voucher_${kind.code}';
    final seq = await nextSeq(key);
    return '${kind.prefix}${seq.padLeft(4, '0')}';
  }

  Future<int> saveVoucher(Voucher v) async {
    final db = await _db;
    // فحص الصلاحيات: إنشاء = add_tx، تعديل = edit_tx، وتغيير حالة
    // الاعتماد/الإلغاء يتطلب صلاحية approve_vouchers صراحةً.
    if (v.id == null) {
      await _ensureCan('add_tx');
    } else {
      final prev = await db.query('vouchers',
          columns: ['status'], where: 'id = ?', whereArgs: [v.id], limit: 1);
      final prevStatus =
          prev.isEmpty ? '' : ((prev.first['status'] as String?) ?? '');
      final statusChanged = prevStatus != v.status &&
          (v.status == 'approved' || v.status == 'cancelled');
      await _ensureCan(statusChanged ? 'approve_vouchers' : 'edit_tx');
    }
    late final int id;
    if (v.id == null) {
      id = await db.insert('vouchers', v.toMap()..['id'] = newGlobalId());
      await queueOperation(
        entityType: EntityKind.voucher,
        entityId: '$id',
        opType: OpKind.create,
        payload: v.toMap()..['id'] = id,
      );
      await logActivity('${v.kind.label} ${v.number}', 'voucher', '$id');
    } else {
      id = v.id!;
      await db.update('vouchers', v.toMap(), where: 'id = ?', whereArgs: [id]);
      await queueOperation(
        entityType: EntityKind.voucher,
        entityId: '$id',
        opType: OpKind.update,
        payload: v.toMap(),
      );
      await logActivity('تعديل ${v.kind.label} ${v.number}', 'voucher', '$id');
    }
    return id;
  }

  Future<void> deleteVoucher(int id) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    final r = await db.query('vouchers', where: 'id = ?', whereArgs: [id]);
    if (r.isNotEmpty) {
      await db.insert('trash', {
        'store': 'vouchers',
        'payload': jsonEncode(r.first),
        'label': 'سند ${r.first['number']}',
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    await db.delete('vouchers', where: 'id = ?', whereArgs: [id]);
    await queueOperation(
      entityType: EntityKind.voucher,
      entityId: '$id',
      opType: OpKind.delete_,
      payload: {'id': id},
    );
    await logActivity('حذف سند', 'voucher', '$id');
  }

  // ==================== المستخدمون ====================

  Future<List<AppUser>> users({bool includeDeleted = false}) async {
    final db = await _db;
    final rows = await db.query(
      'users',
      where: includeDeleted ? null : "COALESCE(deleted_at,'') = ''",
      orderBy: 'id ASC',
    );
    return rows.map(AppUser.fromMap).toList();
  }

  Future<AppUser?> currentUser() async {
    final mode = await workspaceMode();
    // المالك (is_owner=1) يملك كل الصلاحيات دائمًا في أي وضع — هذا يضمن أن
    // المنقولة له الملكية يصبح مديرًا فعليًا فور وصول علامة is_owner، وأن
    // فقدان ربط المستخدم لا يحرم المالك من إدارة مجموعته.
    if (await isWorkspaceOwner()) {
      final all = await users();
      final admin = all.where((u) => u.role == UserRole.admin).toList();
      if (admin.isNotEmpty) {
        return admin.first.copyWith(
          active: true,
          permissions: defaultPerms(UserRole.admin),
        );
      }
      // لا يوجد مستخدم مدير بعد (عضو رُقّي للملكية) — نرجع هوية مدير افتراضية.
      final now = DateTime.now();
      return AppUser(
        id: null,
        name: 'المدير',
        role: UserRole.admin,
        permissions: defaultPerms(UserRole.admin),
        active: true,
        isMe: true,
        createdAt: now,
        updatedAt: now,
      );
    }
    if (mode == 'member') {
      // في وضع العضو: المستخدم الفعّال هو المُعيّن لهذا الجهاز من قِبل المدير.
      // إن لم يُعيَّن بعد = لا صلاحيات على الإطلاق.
      return deviceAssignedUser();
    }
    // وضع مستقل: المستخدم "أنا" (is_me=1) أو المدير.
    final all = await users();
    if (all.isEmpty) return null;
    return all.firstWhere(
      (u) => u.isMe,
      orElse: () => all.firstWhere(
        (u) => u.role == UserRole.admin,
        orElse: () => all.first,
      ),
    );
  }

  /// يمنع المستخدم غير المصرّح من إجراء حُرج. المدير يمر دائمًا.
  Future<void> _ensureCan(String perm) async {
    final allowed = await can(perm).timeout(
      const Duration(seconds: 3),
      onTimeout: () => false,
    );
    if (!allowed) {
      throw StateError(
          'ليس لديك صلاحية لهذا الإجراء أو تعذّر التحقق منها. أعد المحاولة.');
    }
  }

  /// Failure to verify identity never grants privileges (fail closed).
  Future<bool> can(String perm) async {
    try {
      final me = await currentUser().timeout(const Duration(seconds: 2));
      return me != null && me.active && me.can(perm);
    } catch (_) {
      return false;
    }
  }

  /// حماية المدير الوحيد.
  Future<void> _guardSingleAdmin(AppUser? existing, AppUser updated) async {
    if (existing != null &&
        existing.role == UserRole.admin &&
        updated.role != UserRole.admin) {
      final all = await users();
      final admins = all.where((u) => u.role == UserRole.admin).toList();
      if (admins.length <= 1) {
        throw StateError('لا يمكن إزالة صلاحية المدير الوحيد.');
      }
    }
  }

  Future<int> saveUser(AppUser u) async {
    final db = await _db;
    AppUser? existing;
    if (u.id != null) {
      final r = await db.query('users', where: 'id = ?', whereArgs: [u.id]);
      if (r.isNotEmpty) existing = AppUser.fromMap(r.first);
    }

    final allUsers = await users();
    final admins = allUsers.where((x) => x.role == UserRole.admin).toList();

    // 🛟 وضع الاسترداد/البذرة: لا يُسمح أبداً بأن لا يوجد مدير في النظام.
    // - لا مستخدمين بعد → أول مستخدم يصبح مديراً والمستخدم الحالي.
    // - لا مديرين (حذف/استيراد/ترقية) → يُرقّى هذا المستخدم تلقائياً.
    var effective = u;
    final needsSeed = allUsers.isEmpty || admins.isEmpty;
    if (needsSeed && u.role != UserRole.admin) {
      effective = u.copyWith(
        role: UserRole.admin,
        permissions: defaultPerms(UserRole.admin),
      );
    }
    await _guardSingleAdmin(existing, effective);

    // فحص الصلاحية بعد تحديد المستخدم الفعلي؛ المدير يمر دائماً، ووضع
    // الاسترداد (لا مدير) يُسمح له بإنقاذ النظام قبل قفله نهائياً.
    if (!needsSeed) await _ensureCan('manage_users');

    if (effective.id == null) {
      final map = effective.toMap();
      if (allUsers.isEmpty) map['is_me'] = 1; // أول مستخدم = المستخدم الحالي
      map['id'] = newGlobalId();
      final id = await db.insert('users', map);
      await queueOperation(
        entityType: EntityKind.user,
        entityId: '$id',
        opType: OpKind.create,
        payload: map..['id'] = id,
      );
      await logActivity('إضافة مستخدم: ${effective.name}', 'user', '$id');
      return id;
    }
    final id = effective.id!;
    final map = effective.toMap();
    await db.update('users', map, where: 'id = ?', whereArgs: [id]);
    await queueOperation(
      entityType: EntityKind.user,
      entityId: '$id',
      opType: OpKind.update,
      payload: map,
    );
    await logActivity('تعديل مستخدم: ${effective.name}', 'user', '$id');
    return id;
  }

  Future<void> deleteUser(int id) async {
    await _ensureCan('manage_users');
    final db = await _db;
    final r = await db.query('users', where: 'id = ?', whereArgs: [id]);
    if (r.isNotEmpty) {
      final victim = AppUser.fromMap(r.first);
      if (victim.role == UserRole.admin) {
        final all = await users();
        if (all.where((u) => u.role == UserRole.admin).length <= 1) {
          throw StateError('لا يمكن حذف المدير الوحيد.');
        }
      }
      final me = await currentUser();
      if (me?.id == id) {
        throw StateError('لا يمكن حذف الحساب المستخدم حاليًا.');
      }
    }
    // Soft-delete بدلاً من الحذف النهائي (للمزامنة).
    final now = DateTime.now().toIso8601String();
    await db.update(
      'users',
      {'deleted_at': now, 'active': 0, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
    await queueOperation(
      entityType: EntityKind.user,
      entityId: '$id',
      opType: OpKind.delete_,
      payload: {'id': id, 'deleted_at': now},
    );
    await logActivity('حذف مستخدم', 'user', '$id');
  }

  /// يجعل مستخدمًا واحدًا هو المستخدم الحالي.
  Future<void> setCurrentUser(int id) async {
    final db = await _db;
    await db.update('users', {'is_me': 0});
    await db.update('users', {'is_me': 1}, where: 'id = ?', whereArgs: [id]);
  }

  // ==================== إدارة الأجهزة ====================

  /// قائمة الأجهزة المرتبطة بالـ workspace مع اسم المستخدم الموكّل لكل جهاز.
  Future<List<Map<String, Object?>>> devices() async {
    await _ensureCan('manage_users'); // فقط المدير/من يملك إدارة المستخدمين.
    final db = await _db;
    return db.rawQuery(
      '''
      SELECT d.*, u.name AS user_name, u.role AS user_role
      FROM devices d
      LEFT JOIN users u ON u.id = d.user_id
      WHERE d.workspace_id = ?
      ORDER BY
        CASE WHEN COALESCE(d.revoked_at,'') = '' THEN 0 ELSE 1 END,
        d.last_seen_at DESC
    ''',
      [requireWorkspaceId],
    );
  }

  /// (دفعة 56) «حذف نهائي من السجل» لجهاز مطرود/محظور: يمحو سجل الجهاز
  /// من devices ويحذف مستخدم الظل المرتبط به إن لم يعد أي جهاز آخر
  /// يستعمله (تنظيف الحسابات اليتيمة). للمدير فقط، ولا يُحذف جهاز نشط.
  Future<void> purgeDeviceRecord(String deviceId) async {
    await _ensureCan('manage_users');
    final db = await _db;
    final rows = await db.query('devices',
        where: 'id = ?', whereArgs: [deviceId], limit: 1);
    if (rows.isEmpty) return;
    final row = rows.first;
    if (((row['is_owner'] ?? 0) as int) == 1) {
      throw StateError('لا يمكن حذف سجل جهاز المدير.');
    }
    final expelled = '${row['expelled_at'] ?? ''}'.isNotEmpty;
    final revoked = '${row['revoked_at'] ?? ''}'.isNotEmpty;
    if (!expelled && !revoked) {
      throw StateError('الحذف النهائي متاح للأجهزة المطرودة/المحظورة فقط.');
    }
    final uid = row['user_id'] as int?;
    await db.transaction((txn) async {
      await txn.delete('devices', where: 'id = ?', whereArgs: [deviceId]);
      if (uid != null) {
        // مستخدم الظل يُحذف فقط إن لم يبق جهاز آخر مرتبطاً به
        // ولم يكن حساباً حقيقياً مستخدَماً حالياً.
        final still = await txn.query('devices',
            where: 'user_id = ?', whereArgs: [uid], limit: 1);
        if (still.isEmpty) {
          await txn.delete('users',
              where: 'id = ? AND is_me <> 1', whereArgs: [uid]);
        }
      }
    });
    await logActivity('حذف نهائي لجهاز من السجل', 'device', deviceId);
  }

  /// (دفعة 56) قائمة معرفات الأجهزة المطرودة — لزر «تنظيف المطرودين».
  Future<List<String>> expelledDeviceIds() async {
    await _ensureCan('manage_users');
    final db = await _db;
    final rows = await db.query('devices',
        columns: ['id'],
        where: "COALESCE(expelled_at,'') <> '' AND COALESCE(is_owner,0) <> 1");
    return [for (final r in rows) '${r['id']}'];
  }

  /// تعيين/تغيير المستخدم (والصلاحيات) المرتبط بجهاز.
  Future<void> assignDeviceUser(String deviceId, int? userId) async =>
      assignDeviceToUser(deviceId, userId);

  /// (دفعة 57) توحيد مسار الهوية: ربط الجهاز بمستخدم أصبح معاملة واحدة
  /// تُحدّث السجل وتبثّ عملية device متزامنة — لا انفصال بعد اليوم بين
  /// «الجهاز المربوط» و«دور المستخدم» عبر الأجهزة.
  Future<void> assignDeviceToUser(String deviceId, int? userId) =>
      setDeviceIdentity(deviceId, userId: userId, assignUser: true);

  /// يضبط صلاحيات جهاز عضو بدقة: يُنشئ/يحدّث المستخدم المرتبط بالجهاز بالدور
  /// ومجموعة الصلاحيات المحددة، ثم يزامن التغيير لبقية الأجهزة.
  /// للمدير (owner) فقط. (دفعة 57) غلاف رقيق حول setDeviceIdentity.
  Future<void> setDevicePermissions(
    String deviceId,
    UserRole role,
    Set<String> perms,
  ) =>
      setDeviceIdentity(deviceId, role: role, perms: perms);

  /// (دفعة 57) المعاملة الموحّدة الموثوقة لهوية الجهاز: ربط مستخدم
  /// و/أو ضبط دور+صلاحيات في معاملة SQLite واحدة، ثم بثّ عمليات
  /// المزامنة الناتجة — تعالج انفصال assignDeviceUser/setDevicePermissions
  /// الذي كان يسمح بحالة وسيطة غير متسقة بين الأجهزة.
  Future<void> setDeviceIdentity(
    String deviceId, {
    int? userId,
    bool assignUser = false,
    UserRole? role,
    Set<String>? perms,
  }) async {
    await _ensureCan('manage_users');
    if (role == null) {
      // مسار الربط فقط (بدون تعديل دور).
      if (!assignUser) return;
      final db = await _db;
      final now = DateTime.now().toIso8601String();
      await db.transaction((txn) async {
        await txn.update(
          'devices',
          {
            'user_id': userId,
            'paired_by': _currentUserId,
            'updated_at': now,
            if (userId != null) 'is_paired': 1,
          },
          where: 'id = ?',
          whereArgs: [deviceId],
        );
      });
      return;
    }
    await _setDeviceRoleAndPerms(deviceId, role, perms ?? const {},
        overrideUserId: assignUser ? userId : null);
  }

  Future<void> _setDeviceRoleAndPerms(
    String deviceId,
    UserRole role,
    Set<String> perms, {
    int? overrideUserId,
  }) async {
    // دور «مدير النظام» لا يُمنح لأي عضو إطلاقاً — الوكيل هو أعلى دور
    // يمكن للمدير منحه (يقوم بعمله أثناء غيابه).
    if (role == UserRole.admin) {
      throw StateError(
        'لا يمكن منح دور المدير لأي عضو — امنح دور «وكيل المدير» بدلاً منه.',
      );
    }
    final db = await _db;
    final dev = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (dev.isEmpty) throw StateError('الجهاز غير موجود.');
    final devName =
        (dev.first['name'] as String?)?.trim().isNotEmpty == true
            ? (dev.first['name'] as String)
            : 'جهاز';
    int? uid = overrideUserId ?? dev.first['user_id'] as int?;
    final now = DateTime.now().toIso8601String();
    // المدير يأخذ كل الصلاحيات دائمًا.
    final effectivePerms = role == UserRole.admin
        ? kPerms.map((p) => p.key).toSet()
        : perms;
    final permStr = effectivePerms.join(',');

    await db.transaction((txn) async {
      final userMap = <String, Object?>{
        'name': devName,
        'role': role.code,
        'pin': '',
        'password': '',
        'permissions': permStr,
        'is_me': 0,
        'active': 1,
        'workspace_id': requireWorkspaceId,
        'deleted_at': '',
        'updated_at': now,
      };
      if (uid == null) {
        uid = newGlobalId();
        userMap['id'] = uid;
        userMap['created_at'] = now;
        await txn.insert('users', userMap);
      } else {
        final ex = await txn.query('users',
            where: 'id = ?', whereArgs: [uid], limit: 1);
        if (ex.isEmpty) {
          userMap['id'] = uid;
          userMap['created_at'] = now;
          await txn.insert('users', userMap);
        } else {
          await txn.update('users', userMap,
              where: 'id = ?', whereArgs: [uid]);
        }
      }
      await txn.update('devices',
          {'user_id': uid, 'updated_at': now, 'is_paired': 1},
          where: 'id = ?', whereArgs: [deviceId]);
    });

    // مزامنة المستخدم المحدّث لبقية الأجهزة.
    final urow = await db.query('users',
        where: 'id = ?', whereArgs: [uid], limit: 1);
    if (urow.isNotEmpty) {
      await queueOperation(
        entityType: EntityKind.user,
        entityId: '$uid',
        opType: OpKind.update,
        payload: Map<String, Object?>.from(urow.first),
      );
    }
  }

  /// إعادة تسمية هذا الجهاز نفسه — متاحة للمستخدم دائماً بلا صلاحيات
  /// (يحدد اسمه الظاهر أعلى القائمة الجانبية والرئيسية).
  Future<void> renameSelfDevice(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    if (_deviceId == null) await initSyncInfra(); // ضمان تسجيل الجهاز أولاً.
    final db = await _db;
    await db.update(
      'devices',
      {'name': n, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [requireDeviceId],
    );
    // نحفظه أيضاً في الإعدادات ليبقى الاسم بعد إعادة التسجيل الذاتي.
    await setSetting('sync.deviceName', n);
  }

  /// تحديث اسم جهاز (ليتعرّف المدير عليه).
  Future<void> renameDevice(String deviceId, String name) async {
    await _ensureCan('manage_users');
    final db = await _db;
    await db.update(
      'devices',
      {'name': name.trim(), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [deviceId],
    );
  }

  /// إلغاء اقتران/حظر جهاز — يمنعه من المزامنة حتى يُعاد اقترانه.
  Future<void> revokeDevice(String deviceId) async {
    await _ensureCan('manage_users');
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'devices',
      {
        'revoked_at': now,
        'is_paired': 0,
        'auth_secret': '',
        'pair_token': '',
        'pair_token_exp': '',
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [deviceId],
    );
    // حذف أي عمليات في قائمة المزامنة لهذا الجهاز حتى لا يرسل شيئًا.
    await db.delete(
      'sync_queue',
      where: 'operation_id IN (SELECT id FROM operations WHERE device_id = ?)',
      whereArgs: [deviceId],
    );
  }

  /// إعادة السماح لجهاز سبق إلغاؤه.
  Future<void> restoreDevice(String deviceId) async {
    await _ensureCan('manage_users');
    final db = await _db;
    await db.update(
      'devices',
      {
        'revoked_at': '',
        'is_paired': 1,
        'auth_secret': await SecretStore.protect(generateDeviceSecret()),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [deviceId],
    );
  }

  /// إعادة توليد المفتاح السرّي للجهاز (يُستخدم بعد تسريب أو للتحكم بكلمة مرور
  /// جهاز عن بُعد). بعدها يجب على الجهاز إعادة الاقتران.
  Future<String> resetDeviceSecret(String deviceId) async {
    await _ensureCan('manage_users');
    final db = await _db;
    final secret = generateDeviceSecret();
    await db.update(
      'devices',
      {
        // يُعاد النص الصريح للمستخدم (لإدخاله في الجهاز الآخر)
        // بينما يُخزَّن معمّى محلياً.
        'auth_secret': await SecretStore.protect(secret),
        'pair_token': '',
        'pair_token_exp': '',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [deviceId],
    );
    return secret;
  }

  /// تغيير كلمة مرور/رمز PIN للمستخدم المرتبط بجهاز ما (يُعيدها للمدير ليخبرها
  /// للعضو). لا تُعدّل كلمة مرور المستخدم الأصلي إلا إذا كان المستخدم هو نفسه.
  Future<void> setDeviceUserCredentials(
    String userId, {
    String? pin,
    String? password,
  }) async {
    await _ensureCan('manage_users');
    final db = await _db;
    final patch = <String, Object?>{};
    if (pin != null) patch['pin'] = pin;
    if (password != null) patch['password'] = password;
    if (patch.isEmpty) return;
    patch['updated_at'] = DateTime.now().toIso8601String();
    await db.update('users', patch, where: 'id = ?', whereArgs: [userId]);
  }

  // (دفعة 58) حُذفت createPairingToken (اقتران LAN عبر QR بعنوان IP) —
  // الاقتران أصبح سحابياً حصرياً عبر CloudJoin.createInvite (رمز/QR سحابي).

  /// يُنفَّذ دوريًا على المضيف: أي جهاز لم يظهر لمدة 30 يومًا يُطرَد تلقائيًا.
  /// يعيد قائمة الأجهزة المطرودة حديثًا (للعرض في الإشعارات).
  Future<List<String>> autoExpireStaleDevices() async {
    final db = await _db;
    if (!(await isWorkspaceOwner())) return const [];
    final cutoff =
        DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    final now = DateTime.now().toIso8601String();
    // طرد الأجهزة التي لم تُرَ منذ 30 يوم ولم تُطرَد/تُلغَ سابقاً.
    final stale = await db.query(
      'devices',
      where: "is_paired = 1 AND COALESCE(expelled_at,'') = '' "
          "AND COALESCE(revoked_at,'') = '' "
          "AND COALESCE(last_seen_at,'') <> '' AND last_seen_at < ? "
          "AND is_owner = 0",
      whereArgs: [cutoff],
    );
    final ids = stale.map((r) => r['id'] as String).toList();
    for (final id in ids) {
      await db.update(
        'devices',
        {
          'revoked_at': now,
          'expelled_at': now,
          'is_paired': 0,
          'auth_secret': '',
          'pair_token': '',
          'pair_token_exp': '',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    return ids;
  }

  /// المدير يطرد جهازًا من المجموعة يدويًا.
  Future<void> expelDevice(String deviceId) async {
    await _ensureCan('manage_users');
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'devices',
      {
        'revoked_at': now,
        'expelled_at': now,
        'is_paired': 0,
        'auth_secret': '',
        'pair_token': '',
        'pair_token_exp': '',
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [deviceId],
    );
    // تطهير الدردشة: المحادثة الفردية مع الجهاز المطرود تُحذف برسائلها —
    // لا يبقى المطرود في قوائم المحادثات ولا في بيانات الرسائل الوصفية.
    await purgePeerChat(deviceId);
  }

  /// يحذف محادثة القرين الفردية (peer:<deviceId>) ورسائلها بالكامل.
  /// تُستدعى عند الطرد/الإلغاء لدى المدير، وعبر مصالحة الـ roster لدى
  /// بقية الأعضاء عندما يصلهم خبر الطرد.
  Future<void> purgePeerChat(String deviceId) async {
    final db = await _db;
    final convs = await db.query(
      'conversations',
      columns: ['id'],
      where: 'title = ?',
      whereArgs: ['peer:$deviceId'],
    );
    for (final c in convs) {
      final cid = c['id'];
      await db.delete('messages',
          where: 'conversation_id = ?', whereArgs: [cid]);
      await db.delete('conversations', where: 'id = ?', whereArgs: [cid]);
    }
  }

  /// ينقل ملكية/إدارة المجموعة لجهاز آخر (يعينه is_owner=1 ويُعيّن له المستخدم
  /// صاحب دور المدير إن لم يكن معيّناً، ويجعل جهازنا الحالي عضواً عادياً بصلاحيات
  /// الدور الذي يختاره المدير السابق أو viewer كافتراضي).
  /// المتطلب: أنا المالك حالياً، والجهاز المستهدف مقترن وغير مطرود/محظور.
  Future<void> transferOwnership(
    String newOwnerDeviceId, {
    String? newUserRoleForMe,
  }) async {
    await _ensureCan('manage_users');
    final db = await _db;
    if (_deviceId == null) {
      throw StateError('جهازك غير مُعرَّف — أعد تشغيل التطبيق.');
    }
    if (newOwnerDeviceId == _deviceId) return; // لا شيء يفعله.

    final peer = await db.query(
      'devices',
      where:
          "id = ? AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''",
      whereArgs: [newOwnerDeviceId],
      limit: 1,
    );
    if (peer.isEmpty) {
      throw StateError('الجهاز المطلوب غير موجود أو مطرود/محظور.');
    }

    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      // 1) إلغاء is_owner عن كل الأجهزة.
      await txn.update('devices', {'is_owner': 0});

      // 2) تعيين الجهاز الجديد كمالك، وضمان وجود مستخدم مدير فعلي مربوط به.
      int? newOwnerUserId = peer.first['user_id'] as int?;
      String newOwnerName =
          (peer.first['name'] as String?)?.trim().isNotEmpty == true
              ? peer.first['name'] as String
              : 'المدير';
      if (newOwnerUserId != null) {
        // ارفع المستخدم المربوط إلى مدير إن لم يكن.
        final urows = await txn.query('users',
            where: 'id = ?', whereArgs: [newOwnerUserId], limit: 1);
        if (urows.isNotEmpty) {
          final u = AppUser.fromMap(urows.first);
          if (u.role != UserRole.admin) {
            final perms = defaultPerms(UserRole.admin);
            final permStr =
                perms.entries.where((e) => e.value).map((e) => e.key).join(',');
            await txn.update('users',
                {'role': 'admin', 'permissions': permStr, 'active': 1,
                 'deleted_at': '', 'updated_at': now},
                where: 'id = ?', whereArgs: [newOwnerUserId]);
          }
        } else {
          newOwnerUserId = null;
        }
      }
      if (newOwnerUserId == null) {
        // أنشئ مستخدم مدير جديدًا خاصًا بالمالك الجديد.
        final adminPerms = defaultPerms(UserRole.admin);
        final permStr = adminPerms.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .join(',');
        final id = newGlobalId();
        await txn.insert('users', {
          'id': id,
          'name': newOwnerName,
          'role': 'admin',
          'pin': '',
          'password': '',
          'permissions': permStr,
          'is_me': 0,
          'active': 1,
          'workspace_id': requireWorkspaceId,
          'deleted_at': '',
          'created_at': now,
          'updated_at': now,
        });
        newOwnerUserId = id;
      }
      await txn.update(
        'devices',
        {
          'is_owner': 1,
          'user_id': newOwnerUserId,
          'paired_by': _currentUserId,
          'revoked_at': '',
          'expelled_at': '',
          'is_paired': 1,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [newOwnerDeviceId],
      );

      // 3) جهازي الحالي: أُصبح عضواً عادياً بالدور المطلوب (viewer افتراضيًا).
      final demoteRole = newUserRoleForMe ?? 'viewer';
      final demotePerms = defaultPerms(UserRole.fromCode(demoteRole));
      final demoteStr =
          demotePerms.entries.where((e) => e.value).map((e) => e.key).join(',');
      final myUser = await txn.query(
        'users',
        where: 'id = ?',
        whereArgs: [_currentUserId],
        limit: 1,
      );
      if (myUser.isNotEmpty && _currentUserId != newOwnerUserId) {
        await txn.update(
          'users',
          {
            'role': demoteRole,
            'permissions': demoteStr,
            'is_me': 1, // نظل أنا المستخدم الفعال على جهازنا.
            'active': 1,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [_currentUserId],
        );
      }
      await txn.update(
        'devices',
        {'is_owner': 0, 'user_id': _currentUserId, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [_deviceId],
      );

      await txn.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'host'}, // دائماً مدار.
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    // مزامنة تغييرات الأدوار (users) مع الأعضاء الآخرين عبر العمليات.
    try {
      final usersRows = await db.query('users');
      for (final u in usersRows) {
        await queueOperation(
          entityType: EntityKind.user,
          entityId: '${u['id']}',
          opType: OpKind.update,
          payload: Map<String, Object?>.from(u),
        );
      }
      // علِّمة تغيير ملكية تدفع الأعضاء لسحب لقطة منعشة عند المزامنة التالية.
      await setSetting('ownershipEpoch', now);
      await queueOperation(
        entityType: EntityKind.setting,
        entityId: 'ownershipEpoch',
        opType: OpKind.settings,
        payload: {'key': 'ownershipEpoch', 'value': now},
      );
    } catch (_) {}
  }

  /// يُعيد الجهاز إلى الوضع المستقل بعد الطرد من قِبل المدير.
  /// يستدعيها العضو عندما يكتشف أنه مطرود (من استجابة 410 في /ops).
  Future<void> resetToStandaloneAfterExpulsion() => _resetToStandalone();

  // ==================== تهيئة المجموعة من الصفر (المدير فقط) ====================

  /// مفتاح آخر تهيئة كاملة (يمنع تكرارها قبل شهر).
  static const _kLastGroupWipe = 'lastGroupWipeAt';

  /// متى تُتاح التهيئة القادمة؟ null = متاحة الآن.
  Future<DateTime?> groupWipeAvailableAt() async {
    final st = await settings();
    final last = DateTime.tryParse(st[_kLastGroupWipe] ?? '');
    if (last == null) return null;
    final next = last.add(const Duration(days: 30));
    return DateTime.now().isBefore(next) ? next : null;
  }

  /// «تنظيف وحذف كامل لبيانات التطبيق والأعضاء وتهيئة المجموعة من الصفر»:
  /// - للمدير (owner) فقط، وبعد مصادقة النظام (بصمة/رمز القفل) في الواجهة.
  /// - يحذف كل بيانات الأعمال (حسابات/عمليات/سندات/أصناف/مخزون/دردشة/سلة/
  ///   نشاط/إشعارات) من جهاز المدير، ويبث عمليات حذف متزامنة تُفرغ أجهزة
  ///   الأعضاء كذلك.
  /// - لا يمسّ الإعدادات ولا الصلاحيات ولا المستخدمين ولا الأجهزة المقترنة —
  ///   تبقى المجموعة قائمة ببنيتها وتبدأ بدفاتر فارغة.
  /// - يقفل نفسه شهراً كاملاً بعد التنفيذ.
  Future<void> wipeGroupData() async {
    final mode = await workspaceMode();
    if (mode != 'standalone' && !await isWorkspaceOwner()) {
      throw StateError('تهيئة المجموعة متاحة لجهاز المدير فقط.');
    }
    final nextAt = await groupWipeAvailableAt();
    if (nextAt != null) {
      throw StateError(
        'خيار التهيئة مقفل حتى ${nextAt.toIso8601String().substring(0, 10)} '
        '(مرة واحدة كل شهر).',
      );
    }
    final db = await _db;
    final inGroup = mode != 'standalone';
    // 1) بث عمليات حذف للأعضاء قبل مسح السجلات محلياً (داخل مجموعة فقط):
    //    delete_ لكل كيان أعمال حتى تنتقل دفاتر الأعضاء إلى سلاتهم ثم تُفرغ.
    if (inGroup) {
      final rec = SyncRecorder(
        db: db,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      );
      const wipeTables = <(String, EntityKind)>[
        ('transactions', EntityKind.tx),
        ('vouchers', EntityKind.voucher),
        ('stock_moves', EntityKind.stockMove),
        ('items', EntityKind.item),
        ('item_categories', EntityKind.itemCategory),
        ('accounts', EntityKind.account),
      ];
      for (final (table, kind) in wipeTables) {
        final rows = await db.query(table, columns: ['id']);
        for (final r in rows) {
          await rec.record(
            entityType: kind,
            entityId: '${r['id']}',
            opType: OpKind.delete_,
            payload: {'id': r['id'], '__wipe': 1},
          );
        }
      }
    }
    // 2) المسح المحلي الكامل لبيانات الأعمال — الإعدادات والمستخدمون
    //    والأجهزة والصلاحيات تبقى كما هي.
    await db.transaction((txn) async {
      const tables = [
        'transaction_items',
        'transactions',
        'stock_moves',
        'items',
        'item_categories',
        'vouchers',
        'accounts',
        'messages',
        'conversations',
        'trash',
        'activity',
        'notifications',
      ];
      for (final t in tables) {
        await txn.delete(t);
      }
      await txn.insert('activity', {
        'text': 'تهيئة المجموعة: حذف كامل لبيانات التطبيق والأعضاء',
        'ref_type': 'wipe',
        'ref_id': '',
        'user_name': 'المدير',
        'created_at': DateTime.now().toIso8601String(),
      });
    });
    // 3) قفل الخيار شهراً.
    await setSetting(_kLastGroupWipe, DateTime.now().toIso8601String());
  }

  /// يتحقق العضو مما إذا كان قد طُرِد (بناءً على سجلنا المحلي للأجهزة).
  Future<bool> amIExpelled() async {
    if (_deviceId == null) return false;
    final me = await ownDeviceRow();
    if (me == null) return false;
    final expelled = (me['expelled_at'] ?? '') as String;
    final revoked = (me['revoked_at'] ?? '') as String;
    return expelled.isNotEmpty || revoked.isNotEmpty;
  }

  // ==================== الدردشة ====================

  /// معرّف ثابت لمحادثة المجموعة — نفسه على كل الأجهزة حتى تتلاقى الرسائل.
  static const int groupConversationId = 777000111;

  /// محادثة المجموعة (بين أجهزة المجموعة فقط) — تُنشأ عند أول استخدام.
  Future<int> groupConversation() async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.insert(
        'conversations',
        {
          'id': groupConversationId,
          'workspace_id': requireWorkspaceId,
          'title': 'دردشة المجموعة',
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return groupConversationId;
  }

  /// يرسل رسالة في دردشة المجموعة ويزامنها فورياً لكل الأجهزة.
  /// متاحة لكل جهاز مقترن حتى بلا صلاحيات — قناة تواصل العضو مع المدير.
  Future<int> sendGroupMessage(String body) async {
    final db = await _db;
    await groupConversation();
    final now = DateTime.now().toIso8601String();
    final id = newGlobalId();
    final row = {
      'id': id,
      'conversation_id': groupConversationId,
      'workspace_id': requireWorkspaceId,
      'sender': requireDeviceId, // هوية الجهاز المرسل (تُعرض باسمه)
      'body': body.trim(),
      'kind': 'text',
      'payload': '',
      'created_at': now,
    };
    await db.insert('messages', row);
    await db.update('conversations', {'updated_at': now},
        where: 'id = ?', whereArgs: [groupConversationId]);
    await queueOperation(
      entityType: EntityKind.message,
      entityId: '$id',
      opType: OpKind.create,
      payload: {...row, 'conv_title': 'دردشة المجموعة'},
    );
    return id;
  }

  /// يرسل مرفقاً (صورة/فيديو/ملف/تسجيل صوتي) في دردشة المجموعة.
  /// الملف يُحفظ محلياً في documents/chat_media ويُضمّن base64 في حمولة
  /// المزامنة ليصل لكل أجهزة المجموعة (حد أقصى 6 MB بعد الترميز).
  /// [kind]: image / video / audio / file — [name]: اسم الملف الأصلي.
  Future<int> sendGroupAttachment({
    required List<int> bytes,
    required String name,
    required String kind,
    String caption = '',
  }) async {
    if (bytes.isEmpty) throw StateError('الملف فارغ.');
    // 6 MB خام ≈ 8 MB بعد base64 — حد ناقل LAN.
    if (bytes.length > 6 * 1024 * 1024) {
      throw StateError(
        'حجم الملف يتجاوز الحد المسموح (6 MB) — اختر ملفاً أصغر.',
      );
    }
    final db = await _db;
    await groupConversation();
    final now = DateTime.now().toIso8601String();
    final id = newGlobalId();
    // حفظ محلي: مجلد chat_media داخل documents.
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/chat_media');
    await folder.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final local = File('${folder.path}/${id}_$safeName');
    await local.writeAsBytes(bytes, flush: true);

    // المسار يُخزَّن نسبياً (chat_media/...) — المطلق يتغيّر بين الأجهزة
    // وبعد تحديثات النظام؛ التحويل للمطلق يحدث وقت العرض فقط.
    await MediaPaths.ensureDocsDir();
    final storedPath = MediaPaths.toRelative(local.path);
    final meta = jsonEncode({
      'name': name,
      'size': bytes.length,
      'path': storedPath,
    });
    final row = {
      'id': id,
      'conversation_id': groupConversationId,
      'workspace_id': requireWorkspaceId,
      'sender': requireDeviceId,
      'body': caption.trim(),
      'kind': kind,
      'payload': meta,
      'created_at': now,
    };
    await db.insert('messages', row);
    await db.update('conversations', {'updated_at': now},
        where: 'id = ?', whereArgs: [groupConversationId]);
    // الحمولة المزامنة تتضمن الملف نفسه base64 — يعيد الطرف الآخر بناءه.
    await queueOperation(
      entityType: EntityKind.message,
      entityId: '$id',
      opType: OpKind.create,
      payload: {
        ...row,
        'conv_title': 'دردشة المجموعة',
        'file_b64': base64Encode(bytes),
        'file_name': name,
      },
    );
    return id;
  }

  /// يرسل مرفقاً (صورة/فيديو/ملف/تسجيل صوتي) في محادثة 1:1 مع حساب.
  /// المحادثات الفردية محلية فقط (خارج نطاق المزامنة) — لذلك يُحفظ الملف
  /// محلياً في documents/chat_media دون أي عملية مزامنة.
  Future<int> sendConversationAttachment({
    required int conversationId,
    required List<int> bytes,
    required String name,
    required String kind,
    String caption = '',
  }) async {
    if (bytes.isEmpty) throw StateError('الملف فارغ.');
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    // حفظ محلي: مجلد chat_media داخل documents (نفس مجلد دردشة المجموعة).
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/chat_media');
    await folder.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final local = File(
        '${folder.path}/c${conversationId}_${DateTime.now().millisecondsSinceEpoch}_$safeName');
    await local.writeAsBytes(bytes, flush: true);

    await MediaPaths.ensureDocsDir();
    final meta = jsonEncode({
      'name': name,
      'size': bytes.length,
      'path': MediaPaths.toRelative(local.path),
    });
    final id = await db.insert('messages', {
      'conversation_id': conversationId,
      'workspace_id': requireWorkspaceId,
      'sender': 'me',
      'body': caption.trim(),
      'kind': kind,
      'payload': meta,
      'created_at': now,
    });
    await db.update('conversations', {'updated_at': now},
        where: 'id = ?', whereArgs: [conversationId]);
    return id;
  }

  /// رسائل دردشة المجموعة (الأقدم أولاً).
  Future<List<ChatMessage>> groupMessages({int limit = 300}) async {
    final db = await _db;
    final rows = await db.query(
      'messages',
      where: "conversation_id = ? AND COALESCE(deleted_at,'') = ''",
      whereArgs: [groupConversationId],
      orderBy: 'created_at ASC, id ASC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// محادثة فردية مع عضو مجموعة (جهاز مقترن) — تُنشأ عند أول فتح.
  /// المحادثات الفردية محصورة بأعضاء المجموعة فقط (لا عملاء خارجيين)،
  /// مفتاح التمييز معرف الجهاز peer:<deviceId> ثابت حتى لو تغيّر الاسم.
  Future<int> conversationForPeer(String deviceId, String name) async {
    final db = await _db;
    final key = 'peer:$deviceId';
    final r = await db.query(
      'conversations',
      where: 'title = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (r.isNotEmpty) return r.first['id'] as int;
    final now = DateTime.now().toIso8601String();
    return db.insert('conversations', {
      'title': key,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// محادثة لكل حساب، تُنشأ عند أول رسالة.
  Future<int> conversationFor(Account a) async {
    final db = await _db;
    final r = await db.query(
      'conversations',
      where: 'title = ?',
      whereArgs: [a.name],
    );
    if (r.isNotEmpty) return r.first['id'] as int;
    final now = DateTime.now().toIso8601String();
    return db.insert('conversations', {
      'title': a.name,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<Map<String, Object?>>> conversations() async {
    final db = await _db;
    // (دفعة 57) المحذوف ناعماً لا يظهر.
    return db.query('conversations',
        where: "COALESCE(deleted_at,'') = ''", orderBy: 'updated_at DESC');
  }

  Future<List<ChatMessage>> messages(int conversationId) async {
    final db = await _db;
    final rows = await db.query(
      'messages',
      where: "conversation_id = ? AND COALESCE(deleted_at,'') = ''",
      whereArgs: [conversationId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<int> sendMessage(ChatMessage m) async {
    final db = await _db;
    final id = await db.insert('messages', m.toMap());
    await db.update(
      'conversations',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [m.conversationId],
    );
    return id;
  }

  /// (دفعة 57) حذف ناعم متماثل: الرسالة تُوسم deleted_at/deleted_by ولا
  /// تُمحى فيزيائياً — عملية delete_message تُقيَّد في سجل العمليات وتنتشر
  /// لكل الأجهزة (apply_remote يسوّم deleted_at تلقائياً عند وجود العمود).
  Future<void> deleteMessage(int id) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query('messages',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    await db.update(
      'messages',
      {
        'deleted_at': now,
        'deleted_by': requireDeviceId,
        'sync_state': 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await queueOperation(
      entityType: EntityKind.message,
      entityId: '$id',
      opType: OpKind.delete_,
      payload: {
        ...rows.first,
        'deleted_at': now,
        'deleted_by': requireDeviceId,
      },
    );
  }

  /// (دفعة 57) حذف ناعم لمحادثة كاملة: توسم المحادثة وكل رسائلها
  /// deleted_at/deleted_by في معاملة واحدة، وتُبث عملية delete_conversation
  /// متماثلة للأقران (كلٌّ منهم يسوّم نسخته المحلية بنفس الطريقة).
  Future<void> deleteConversation(int id) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query('conversations',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    await db.transaction((txn) async {
      await txn.update(
        'conversations',
        {
          'deleted_at': now,
          'deleted_by': requireDeviceId,
          'sync_state': 'pending',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'messages',
        {
          'deleted_at': now,
          'deleted_by': requireDeviceId,
          'sync_state': 'pending',
        },
        where: "conversation_id = ? AND COALESCE(deleted_at,'') = ''",
        whereArgs: [id],
      );
    });
    await queueOperation(
      entityType: EntityKind.conversation,
      entityId: '$id',
      opType: OpKind.delete_,
      payload: {
        ...rows.first,
        'deleted_at': now,
        'deleted_by': requireDeviceId,
      },
    );
  }

  /// (دفعة 58 — متطلب 4) التنظيف التلقائي للدردشة: كل رسالة (مجموعة أو
  /// فردية) أقدم من 24 ساعة تُحذف نهائياً من هذا الجهاز مع ملف مرفقها من
  /// documents/chat_media. تعمل دورياً عند الإقلاع وفي دورة الصيانة —
  /// على كل جهاز محلياً، والمدير يطهّر المسار السحابي بالتوازي
  /// (CloudJoin.purgeOldChatOperations). يعيد عدد الرسائل المحذوفة.
  Future<int> purgeExpiredChatMessages(
      {Duration ttl = const Duration(hours: 24)}) async {
    final db = await _db;
    final cutoff = DateTime.now().subtract(ttl).toIso8601String();
    List<Map<String, Object?>> old;
    try {
      old = await db.query('messages',
          columns: ['id', 'kind', 'payload'],
          where: 'created_at < ?',
          whereArgs: [cutoff]);
    } catch (_) {
      old = const [];
    }
    // 1) ملفات المرفقات على القرص (المسار النسبي داخل payload).
    for (final m in old) {
      final kind = '${m['kind'] ?? ''}';
      if (!const {'image', 'video', 'audio', 'file'}.contains(kind)) continue;
      var path = '${m['payload'] ?? ''}'.trim();
      if (path.isEmpty) continue;
      // الحمولة قد تكون JSON فيها path — أو المسار مباشرة.
      if (path.startsWith('{')) {
        try {
          final d = jsonDecode(path);
          if (d is Map) path = '${d['path'] ?? ''}'.trim();
        } catch (_) {}
      }
      if (path.isEmpty) continue;
      try {
        final f = File(MediaPaths.toAbsolute(path));
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    // 2) صفوف الرسائل نفسها (حذف صلب — انتهى عمرها المقرر).
    var n = 0;
    if (old.isNotEmpty) {
      n = await db.delete('messages',
          where: 'created_at < ?', whereArgs: [cutoff]);
    }
    // 3) عمليات message المحلية المرفوعة (synced) الأقدم من المهلة —
    //    حمولاتها قد تتضمن base64 ضخماً ولا فائدة من بقائها.
    try {
      await db.rawDelete('''
        DELETE FROM operations
        WHERE entity_type = 'message' AND synced = 1 AND timestamp < ?
          AND NOT EXISTS (
            SELECT 1 FROM sync_queue q
            WHERE q.operation_id = operations.id
              AND q.status IN ('pending', 'syncing')
          )
      ''', [cutoff]);
    } catch (_) {}
    return n;
  }

  // ==================== التصنيفات ====================

  Future<List<String>> categories() async {
    final db = await _db;
    final rows = await db.query('categories', orderBy: 'name ASC');
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<void> addCategory(String name) async {
    final db = await _db;
    final row = {
      'id': newGlobalId(),
      'workspace_id': requireWorkspaceId,
      'name': name,
      'scope': 'account',
      'created_at': DateTime.now().toIso8601String(),
    };
    await db.insert('categories', row);
    // مزامنة التصنيف لكل الأجهزة مثل أي كيان آخر.
    await queueOperation(
      entityType: EntityKind.category,
      entityId: '${row['id']}',
      opType: OpKind.create,
      payload: row,
    );
  }

  Future<void> deleteCategory(String name) async {
    final db = await _db;
    final rows = await db.query('categories',
        columns: ['id'], where: 'name = ?', whereArgs: [name]);
    await db.delete('categories', where: 'name = ?', whereArgs: [name]);
    for (final r in rows) {
      await queueOperation(
        entityType: EntityKind.category,
        entityId: '${r['id']}',
        opType: OpKind.delete_,
        payload: {'id': r['id'], 'name': name},
      );
    }
  }

  // ==================== سلة المهملات ====================

  Future<List<Map<String, Object?>>> trash() async {
    final db = await _db;
    // ندمج سلة المحذوفات القديمة مع العناصر المحذوفة ناعمًا حتى ننقل بالكامل.
    final legacy = await db.query('trash', orderBy: 'id DESC');
    return legacy;
  }

  /// يعيد سجلًا محذوفًا إلى جدوله الأصلي.
  /// يدعم السجلات القديمة (hard delete مع payload محفوظ) والسجلات الجديدة التي تحمل entity_id.
  Future<void> restoreFromTrash(int trashId) async {
    await _ensureCan('add_tx'); // الاسترجاع = إعادة إنشاء السجل.
    final db = await _db;
    final r = await db.query('trash', where: 'id = ?', whereArgs: [trashId]);
    if (r.isEmpty) return;
    final store = r.first['store'] as String;
    final now = DateTime.now().toIso8601String();
    Object? decoded;
    try {
      decoded = jsonDecode(r.first['payload'] as String);
    } catch (_) {
      decoded = null;
    }
    await db.transaction((txn) async {
      final rec = SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      );
      if (store == 'transactions' &&
          decoded is Map &&
          decoded['transaction'] is Map) {
        final tx = Map<String, Object?>.from(decoded['transaction'] as Map);
        // وسوم المزامنة الداخلية (مثل __sync_entity) ليست أعمدة حقيقية.
        tx.removeWhere((k, _) => k.startsWith('__'));
        tx['deleted_at'] = '';
        tx['updated_at'] = now;
        await txn.insert(
          'transactions',
          tx,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        final txId = tx['id'];
        if (txId != null) {
          await rec.record(
            entityType: EntityKind.tx,
            entityId: '$txId',
            opType: OpKind.restore,
            payload: tx,
            parentOpId: '',
          );
        }
      } else if (decoded is Map && decoded['id'] != null) {
        final payload = Map<String, Object?>.from(decoded);
        // وسوم المزامنة الداخلية (مثل __sync_entity) ليست أعمدة حقيقية.
        payload.removeWhere((k, _) => k.startsWith('__'));
        // إن كان السجل الأصلي ما زال موجودًا (soft delete)، نُلغِ deleted_at.
        final id = payload['id'];
        final exists = await txn.query(
          store,
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (exists.isNotEmpty) {
          await txn.update(
            store,
            {'deleted_at': '', 'restore_op_id': '', 'updated_at': now},
            where: 'id = ?',
            whereArgs: [id],
          );
          final restored = (await txn.query(
            store,
            where: 'id = ?',
            whereArgs: [id],
            limit: 1,
          ))
              .first;
          await rec.record(
            entityType: _entityKindFor(store),
            entityId: '$id',
            opType: OpKind.restore,
            payload: Map<String, Object?>.from(restored),
          );
        } else {
          payload.remove('deleted_at');
          payload['updated_at'] = now;
          await txn.insert(
            store,
            payload,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          await rec.record(
            entityType: _entityKindFor(store),
            entityId: '$id',
            opType: OpKind.restore,
            payload: payload,
          );
        }
      }
      await txn.delete('trash', where: 'id = ?', whereArgs: [trashId]);
    });
    await logActivity('استرجاع من سلة المهملات', store, '$trashId');
  }

  EntityKind _entityKindFor(String table) => switch (table) {
        'accounts' => EntityKind.account,
        'transactions' => EntityKind.tx,
        'items' => EntityKind.item,
        'vouchers' => EntityKind.voucher,
        'users' => EntityKind.user,
        'item_categories' => EntityKind.itemCategory,
        'stock_moves' => EntityKind.stockMove,
        _ => EntityKind.tx,
      };

  /// حذف عنصر واحد من السلة نهائيًا.
  Future<void> deleteFromTrash(int trashId) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    await db.delete('trash', where: 'id = ?', whereArgs: [trashId]);
  }

  Future<void> emptyTrash() async {
    await _ensureCan('delete_tx');
    final db = await _db;
    await db.delete('trash');
    await logActivity('تفريغ سلة المهملات', 'trash', '');
  }

  Future<void> clearActivity() async {
    final db = await _db;
    await db.delete('activity');
  }

  // ==================== النسخ الاحتياطي ====================

  /// الجداول الدائمة التي تدخل في النسخة.
  ///
  /// نُبقي `trash` و`notifications` خارج النسخة عمدًا: الأولى سجل محلي
  /// للعناصر المحذوفة والثانية تنبيهات مشتقة/مؤقتة، ويُفرغان عند الاستعادة
  /// حتى لا تظهر إحالات قديمة بعد استبدال قاعدة البيانات. أما `activity` و
  /// `templates` فهما بيانات مفيدة للمستخدم ولذلك تُحفظ.
  static const backupTables = [
    'accounts',
    'transactions',
    'transaction_items',
    'vouchers',
    'currencies',
    'categories',
    'item_categories',
    'users',
    'conversations',
    'messages',
    'activity',
    'settings',
    'items',
    'stock_moves',
    'templates',
  ];

  /// ترتيب الإدخال مستقل عن ترتيب مفاتيح JSON، ويحافظ على المفاتيح الأجنبية.
  static const _importOrder = [
    'currencies',
    'categories',
    'users',
    'accounts',
    'transactions',
    'item_categories',
    'items',
    'transaction_items',
    'vouchers',
    'conversations',
    'messages',
    'stock_moves',
    'templates',
    'settings',
    'activity',
  ];

  /// الجداول التي تعتمد على معرف SQLite ثابت عند نقل نسخة نكسورا.
  static const _stableIdTables = [
    'accounts',
    'transactions',
    'transaction_items',
    'vouchers',
    'categories',
    'item_categories',
    'users',
    'conversations',
    'messages',
    'activity',
    'items',
    'stock_moves',
    'templates',
  ];

  /// أسماء أعمدة شائعة بصيغة camelCase في ملفات JSON.
  static const _columnAliases = <String, String>{
    'accountId': 'account_id',
    'accountKind': 'account_kind',
    'transactionId': 'tx_id',
    'transaction_id': 'tx_id',
    'openingBalance': 'opening_balance',
    'fromId': 'from_id',
    'toId': 'to_id',
    'buyPrice': 'buy_price',
    'sellPrice': 'sell_price',
    'minQuantity': 'min_quantity',
    'categoryId': 'category_id',
    'conversationId': 'conversation_id',
    'createdAt': 'created_at',
    'updatedAt': 'updated_at',
    'userName': 'user_name',
    'refType': 'ref_type',
    'refId': 'ref_id',
    'isMe': 'is_me',
    'itemId': 'item_id',
    'unitPrice': 'unit_price',
    'txId': 'tx_id',
  };

  /// كل بيانات التطبيق في خريطة واحدة قابلة للتحويل إلى JSON.
  ///
  /// [withImages] يضمّن صور العمليات والحسابات والأصناف مرمّزة base64 داخل
  /// الملف، فلا تضيع عند النقل إلى هاتف آخر.
  /// نسخة احتياطية محلية فقط (تُحفظ داخل مجلد التطبيق) — متاحة لكل
  /// الأجهزة بمن فيهم الأعضاء بلا صلاحية تصدير: الملف لا يغادر الجهاز،
  /// ولا يمكن استيراده في مجموعة أخرى بفضل بصمة المجموعة.
  Future<Map<String, Object?>> exportForLocalBackup({
    bool withImages = false,
  }) =>
      exportAll(withImages: withImages, localOnly: true);

  Future<Map<String, Object?>> exportAll({
    bool withImages = true,
    bool localOnly = false,
  }) async {
    if (!localOnly) await _ensureCan('export');
    final db = await _db;
    final data = <String, Object?>{};
    for (final t in backupTables) {
      try {
        data[t] = await db.query(t);
      } catch (e) {
        throw StateError('تعذّر تصدير جدول $t؛ لم تُنشأ نسخة ناقصة: $e');
      }
    }

    final images = <String, String>{};
    if (withImages) {
      for (final entry in [
        (data['transactions'], 'image'),
        (data['transactions'], 'attachment'),
        (data['accounts'], 'image'),
        (data['items'], 'image'),
      ]) {
        final rows = entry.$1;
        if (rows is! List) continue;
        for (final row in rows) {
          if (row is! Map) continue;
          final path = (row[entry.$2] ?? '') as String? ?? '';
          if (path.isEmpty || images.containsKey(path)) continue;
          try {
            final f = File(MediaPaths.toAbsolute(path));
            if (!f.existsSync()) {
              throw StateError('الصورة المشار إليها غير موجودة: $path');
            }
            if (f.lengthSync() > 10 * 1024 * 1024) {
              throw StateError('حجم الصورة أكبر من 10 م.ب: $path');
            }
            images[path] = base64Encode(await f.readAsBytes());
          } catch (e) {
            throw StateError(
              'تعذّر تضمين الصورة $path؛ لم تُنشأ نسخة ناقصة: $e',
            );
          }
        }
      }

      // شعار المؤسسة محفوظ في settings.value، لذلك نضمّنه صراحةً في
      // ملف النسخة حتى يظهر على السندات بعد النقل إلى جهاز آخر.
      final settingsRows = data['settings'];
      if (settingsRows is List) {
        for (final row in settingsRows) {
          if (row is! Map || row['key'] != 'logo') continue;
          final path = (row['value'] ?? '') as String? ?? '';
          if (path.isEmpty || images.containsKey(path)) continue;
          try {
            final f = File(path);
            if (!f.existsSync()) {
              throw StateError('شعار المؤسسة المشار إليه غير موجود: $path');
            }
            if (f.lengthSync() > 10 * 1024 * 1024) {
              throw StateError('حجم شعار المؤسسة أكبر من 10 م.ب: $path');
            }
            images[path] = base64Encode(await f.readAsBytes());
          } catch (e) {
            throw StateError(
              'تعذّر تضمين شعار المؤسسة $path؛ لم تُنشأ نسخة ناقصة: $e',
            );
          }
        }
      }
    }

    // بصمة المجموعة: معرّف جهاز المدير (المالك) يميّز كل مجموعة عن غيرها،
    // فلا تُستورد نسخة احتياطية صادرة من مجموعة أخرى.
    return {
      'app': 'nexora',
      'format': 2,
      'db_version': AppDatabase.schemaVersion,
      'created_at': DateTime.now().toIso8601String(),
      'group_fingerprint': await _groupFingerprint(),
      'workspace_mode': await workspaceMode(),
      'data': data,
      'images': images,
    };
  }

  /// معرّف جهاز مالك المجموعة (يُميّز المجموعة). فارغ إن لم يوجد مالك.
  Future<String> _groupFingerprint() async {
    final db = await _db;
    final owner = await db.query('devices',
        columns: ['id'], where: 'is_owner = 1', limit: 1);
    return owner.isEmpty ? '' : (owner.first['id'] as String? ?? '');
  }

  /// يستبدل كل البيانات بمحتوى نسخة احتياطية ذرّيًا.
  ///
  /// اختلاف ترتيب الجداول لا يؤثر؛ أما الصف غير الصالح أو المرجع المفقود
  /// فيفشل العملية كلها ويعيد SQLite الحالة السابقة بدل استعادة جزئية صامتة.
  Future<int> importAll(Map<String, Object?> backup) async {
    await _ensureCan('manage_backup');
    final db = await _db;
    final mode = await workspaceMode();
    // داخل مجموعة: الاستعادة (محلية أو من Google) حكر على جهاز المدير —
    // العضو يستعيد نسخة قديمة فتتضارب دفاتره مع بقية الأجهزة عند المزامنة.
    if (mode == 'member') {
      throw const BackupImportException(
        'استعادة نسخة احتياطية داخل المجموعة متاحة لجهاز المدير فقط — '
        'وتُزامن بياناتها تلقائياً إلى بقية الأجهزة.',
      );
    }
    if (WorkspaceMode.parse(mode).isHost && !await isWorkspaceOwner()) {
      throw const BackupImportException(
        'استعادة نسخة احتياطية متاحة لجهاز المدير فقط.',
      );
    }
    // داخل مجموعة: تُرفض أي نسخة غير صادرة من المجموعة نفسها — استيراد
    // بيانات غريبة يفسد دفاتر كل الأجهزة عند أول مزامنة.
    if (mode == 'member' || mode == 'host') {
      final ourFp = await _groupFingerprint();
      final theirFp = (backup['group_fingerprint'] as String?) ?? '';
      if (ourFp.isNotEmpty && theirFp != ourFp) {
        throw const BackupImportException(
          'هذه النسخة الاحتياطية غير صادرة من مجموعتك — '
          'لا يُسمح باستيراد نسخة من خارج المجموعة.',
        );
      }
    }
    final data = _normalize(backup);
    if (data.isEmpty) {
      throw const BackupImportException(
        'ملف غير صالح أو لا يحتوي جداول مفهومة.',
      );
    }

    // تفعيل المفاتيح الأجنبية أيضًا في قواعد الاختبار/القواعد المحقونة.
    await db.execute('PRAGMA foreign_keys = ON');
    final createdFiles = <File>[];

    try {
      // الصور خارج SQLite، لذلك نسجل الملفات الجديدة ونحذفها إذا فشلت المعاملة.
      final remap = await _restoreImages(backup, createdFiles);
      final isNexora = backup['app'] == 'nexora';

      return await db.transaction((txn) async {
        for (final table in [
          'messages',
          'conversations',
          'activity',
          'stock_moves',
          'transaction_items',
          'items',
          'vouchers',
          'transactions',
          'accounts',
          'categories',
          'item_categories',
          'users',
          'currencies',
          'settings',
          'templates',
          'trash',
          'notifications',
        ]) {
          await txn.delete(table);
        }
        // استعادة نظيفة: صفوف الطابور المعلقة تشير لعمليات ما قبل الاستعادة
        // وقد تتضارب مع الحالة المستعادة — تُلغى، وresyncAllToGroup يعيد
        // جدولة كل البيانات المستعادة كعمليات جديدة. مؤشر السحب السحابي
        // يُصفَّر أيضاً (السحب idempotent فلا ضرر من إعادة الجلب).
        try {
          await txn.delete('sync_queue',
              where: 'status IN (?, ?)', whereArgs: ['pending', 'syncing']);
          await txn.delete('sync_meta',
              where: "key LIKE 'lastCloudTs:%' OR key LIKE 'lastRosterPush:%'");
        } catch (_) {
          // قواعد قديمة بلا جداول مزامنة.
        }

        var imported = 0;
        for (final table in _importOrder) {
          final rows = data[table];
          if (rows == null) continue;
          final cols = await _columnsOf(txn, table);
          if (cols.isEmpty) {
            throw BackupImportException(
              'جدول غير مدعوم أثناء الاستعادة: $table',
            );
          }

          for (var index = 0; index < rows.length; index++) {
            final row = rows[index];
            final clean = <String, Object?>{};
            for (final entry in row.entries) {
              final column = _columnAliases[entry.key] ?? entry.key;
              if (!cols.contains(column)) continue;
              if (clean.containsKey(column)) {
                throw BackupImportException(
                  'الصف ${index + 1} في $table يحتوي العمود $column مرتين.',
                );
              }
              clean[column] = _valueForDatabase(
                table,
                column,
                entry.value,
                remap,
              );
            }
            // مسار شعار المؤسسة يحتاج إعادة ربط مثل صور الحسابات والأصناف.
            // إذا لم تُضمّن الصورة في النسخة نُفرغ المسار القديم بدل ترك رابطًا
            // معطّلًا على الجهاز الجديد.
            if (table == 'settings' && clean['key'] == 'logo') {
              final oldPath = clean['value'];
              clean['value'] = oldPath is String ? (remap[oldPath] ?? '') : '';
            }
            if (clean.isEmpty) {
              throw BackupImportException(
                'الصف ${index + 1} في $table لا يحتوي أعمدة مفهومة.',
              );
            }
            if (isNexora &&
                _stableIdTables.contains(table) &&
                (clean['id'] == null || !clean.containsKey('id'))) {
              throw BackupImportException(
                'الصف ${index + 1} في $table يفتقد المعرّف الثابت.',
              );
            }
            if (isNexora &&
                table == 'settings' &&
                (clean['key'] == null || !clean.containsKey('key'))) {
              throw BackupImportException(
                'الصف ${index + 1} في settings يفتقد المفتاح.',
              );
            }

            try {
              await txn.insert(
                table,
                clean,
                conflictAlgorithm: ConflictAlgorithm.abort,
              );
            } catch (e) {
              throw BackupImportException(
                'تعذّر استيراد الصف ${index + 1} من $table؛ أُلغيت الاستعادة بالكامل: $e',
              );
            }
            imported++;
          }
        }

        await _validateOptionalReferences(txn);
        await txn.insert('activity', {
          'text': 'استيراد نسخة احتياطية ($imported سجلًا)',
          'ref_type': 'backup',
          'ref_id': '',
          'user_name': 'المدير',
          'created_at': DateTime.now().toIso8601String(),
        });
        return imported;
      });
    } catch (e) {
      await _deleteFiles(createdFiles);
      if (e is BackupImportException) rethrow;
      throw BackupImportException(
        'فشلت الاستعادة بالكامل ولم تُطبّق أي تغييرات: $e',
      );
    }
  }

  /// بعد استعادة المدير لنسخة احتياطية: يعيد تسجيل كل البيانات المستعادة
  /// كعمليات مزامنة جديدة (upsert) فتُدفع رأساً إلى كل أجهزة المجموعة —
  /// دون هذا تبقى النسخة المستعادة حبيسة جهاز المدير.
  /// يعيد عدد السجلات التي جُدولت للمزامنة (0 خارج المجموعة).
  Future<int> resyncAllToGroup() async {
    final mode = await workspaceMode();
    if (mode == 'standalone') return 0;
    if (!await isWorkspaceOwner()) return 0;
    final db = await _db;
    final rec = SyncRecorder(
      db: db,
      deviceId: requireDeviceId,
      workspaceId: requireWorkspaceId,
      userId: _currentUserId,
    );
    // (جدول، كيان) بترتيب يحترم الاعتمادية عند التطبيق على الطرف الآخر.
    const tables = <(String, EntityKind)>[
      ('categories', EntityKind.category),
      ('currencies', EntityKind.currency),
      ('accounts', EntityKind.account),
      ('item_categories', EntityKind.itemCategory),
      ('items', EntityKind.item),
      ('transactions', EntityKind.tx),
      ('stock_moves', EntityKind.stockMove),
      ('vouchers', EntityKind.voucher),
      ('users', EntityKind.user),
    ];
    var queued = 0;
    for (final (table, kind) in tables) {
      final rows = await db.query(table);
      for (final row in rows) {
        final payload = Map<String, Object?>.from(row);
        // سطور الفاتورة تُرحّل داخل حمولة العملية المالية نفسها.
        if (kind == EntityKind.tx) {
          payload['items'] = await _lineMaps(db, row['id'] as int);
        }
        final entityId = kind == EntityKind.currency
            ? '${row['code']}'
            : '${row['id']}';
        await rec.record(
          entityType: kind,
          entityId: entityId,
          opType: OpKind.update, // upsert على الطرف المستقبل
          payload: payload,
        );
        queued++;
      }
    }
    return queued;
  }

  /// يحوّل القيم إلى أنواع تقبلها sqflite، ويعيد ربط الصور.
  Object? _valueForDatabase(
    String table,
    String column,
    Object? value,
    Map<String, String> remap,
  ) {
    if (_isImageColumn(table, column) && value is String && value.isNotEmpty) {
      // النسخة بلا صورة مضمّنة لا تترك مسار الهاتف القديم معطّلًا.
      return remap[value] ?? '';
    }
    if (value is bool) return value ? 1 : 0;
    if (value == null || value is String || value is num) return value;
    if (value is List<int>) return value;
    throw BackupImportException(
      'قيمة غير مدعومة في $table.$column؛ أُلغيت الاستعادة.',
    );
  }

  bool _isImageColumn(String table, String column) =>
      (table == 'transactions' &&
          (column == 'image' || column == 'attachment')) ||
      ((table == 'accounts' || table == 'items') && column == 'image');

  /// يتحقق من العلاقات التي لم يفرضها المخطط صراحةً.
  Future<void> _validateOptionalReferences(DatabaseExecutor db) async {
    final checks = <({String table, String column, String parent})>[
      (table: 'stock_moves', column: 'account_id', parent: 'accounts'),
      (table: 'vouchers', column: 'tx_id', parent: 'transactions'),
      (table: 'items', column: 'category_id', parent: 'item_categories'),
      (table: 'transaction_items', column: 'item_id', parent: 'items'),
    ];
    for (final check in checks) {
      final rows = await db.rawQuery('''
        SELECT COUNT(*) AS count
        FROM ${check.table} child
        WHERE child.${check.column} IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM ${check.parent} parent
            WHERE parent.id = child.${check.column}
          )
      ''');
      final count = (rows.first['count'] as num?)?.toInt() ?? 0;
      if (count > 0) {
        throw BackupImportException(
          'وجدت $count إحالة غير صالحة في ${check.table}.${check.column}.',
        );
      }
    }
  }

  /// أسماء أعمدة جدول، أو مجموعة فارغة إن لم يكن موجودًا.
  Future<Set<String>> _columnsOf(DatabaseExecutor db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.map((c) => c['name'] as String).toSet();
  }

  /// يكتب الصور المضمّنة إلى القرص ويعيد خريطة المسار القديم ← الجديد.
  Future<Map<String, String>> _restoreImages(
    Map<String, Object?> backup,
    List<File> createdFiles,
  ) async {
    final raw = backup['images'];
    if (raw == null) return const {};
    if (raw is! Map) {
      throw const BackupImportException('حقل images في النسخة غير صالح.');
    }
    if (raw.isEmpty) return const {};

    final out = <String, String>{};
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/images');
    await folder.create(recursive: true);
    var i = 0;

    for (final entry in raw.entries) {
      final oldPath = '${entry.key}';
      final b64 = entry.value;
      if (oldPath.isEmpty || b64 is! String || b64.isEmpty) {
        throw const BackupImportException('توجد صورة مضمّنة ناقصة أو فارغة.');
      }
      if (out.containsKey(oldPath)) {
        throw BackupImportException('مسار صورة مكرر في النسخة: $oldPath');
      }

      late final List<int> bytes;
      try {
        bytes = base64Decode(b64);
      } catch (e) {
        throw BackupImportException(
          'ترميز الصورة غير صالح للمسار $oldPath: $e',
        );
      }
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw BackupImportException('حجم الصورة غير صالح للمسار: $oldPath');
      }
      final extension = _imageExtension(oldPath);
      final name =
          'restored-${DateTime.now().millisecondsSinceEpoch}-${i++}$extension';
      final file = File('${folder.path}/$name');
      createdFiles.add(file);
      try {
        await file.writeAsBytes(bytes, flush: true);
      } catch (e) {
        throw BackupImportException('تعذّر حفظ الصورة $oldPath: $e');
      }
      out[oldPath] = file.path;
    }
    return out;
  }

  String _imageExtension(String path) {
    final extension = p.extension(path).toLowerCase();
    return const {
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.heic',
      '.pdf',
      '.mp4',
      '.mov',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
    }.contains(extension)
        ? extension
        : '.png';
  }

  Future<void> _deleteFiles(Iterable<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // لا نغيّر رسالة فشل المعاملة بسبب ملف مؤقت يتعذر حذفه.
      }
    }
  }

  /// يحوّل أي ملف نسخ احتياطي إلى `{جدول: [صفوف]}`.
  ///
  /// يدعم `{data:{...}}` (نكسورا)، والخريطة المسطّحة، وأسماء مرادفة مثل
  /// `customers` و`entries`. القوائم الفارغة تبقى موجودة حتى تُقبل نسخة
  /// صحيحة لا تحتوي سجلات بعد.
  Map<String, List<Map<String, Object?>>> _normalize(Map<String, Object?> b) {
    Map? src;
    final d = b['data'];
    if (d is Map) {
      src = d;
    } else if (b.values.any((v) => v is List)) {
      src = b;
    }
    if (src == null) return {};

    const alias = <String, String>{
      'accounts': 'accounts',
      'customers': 'accounts',
      'contacts': 'accounts',
      'parties': 'accounts',
      'transactions': 'transactions',
      'entries': 'transactions',
      'operations': 'transactions',
      'records': 'transactions',
      'transaction_items': 'transaction_items',
      'transactionitems': 'transaction_items',
      'tx_items': 'transaction_items',
      'txitems': 'transaction_items',
      'invoice_items': 'transaction_items',
      'invoiceitems': 'transaction_items',
      'vouchers': 'vouchers',
      'receipts': 'vouchers',
      'currencies': 'currencies',
      'categories': 'categories',
      'item_categories': 'item_categories',
      'itemcategories': 'item_categories',
      'inventory_categories': 'item_categories',
      'product_categories': 'item_categories',
      'users': 'users',
      'conversations': 'conversations',
      'messages': 'messages',
      'activity': 'activity',
      'settings': 'settings',
      'items': 'items',
      'products': 'items',
      'inventory': 'items',
      'stock_moves': 'stock_moves',
      'stockmoves': 'stock_moves',
      'templates': 'templates',
    };

    final out = <String, List<Map<String, Object?>>>{};
    src.forEach((k, v) {
      final table = alias['$k'.toLowerCase()];
      if (table == null) return;
      if (v is! List) {
        throw BackupImportException('جدول $table ليس قائمة صفوف صالحة.');
      }
      final rows = <Map<String, Object?>>[];
      for (final r in v) {
        if (r is! Map) {
          throw BackupImportException(
            'يحتوي جدول $table على عنصر ليس صفًا صالحًا.',
          );
        }
        rows.add(r.map((a, b) => MapEntry('$a', b)));
      }
      out.putIfAbsent(table, () => []).addAll(rows);
    });
    return out;
  }

  // ==================== فئات الأصناف ====================

  /// فئات المخزون فقط؛ لا تختلط بتصنيفات الحسابات.
  Future<List<ItemCategory>> itemCategories() async {
    final db = await _db;
    final rows = await db.query(
      'item_categories',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(ItemCategory.fromMap).toList();
  }

  /// إضافة فئة أو تعديل اسمها مع تحديث اسم الفئة في الأصناف التابعة لها.
  Future<int> saveItemCategory(ItemCategory category) async {
    await _ensureCan(category.id == null ? 'add_tx' : 'edit_tx');
    final name = category.name.trim();
    if (name.isEmpty) throw ArgumentError('اسم الفئة مطلوب');

    final db = await _db;
    final duplicate = await db.query(
      'item_categories',
      columns: ['id'],
      where: 'name = ? COLLATE NOCASE AND id != ?',
      whereArgs: [name, category.id ?? -1],
      limit: 1,
    );
    if (duplicate.isNotEmpty) {
      throw StateError('توجد فئة بهذا الاسم مسبقًا');
    }

    late final int id;
    if (category.id == null) {
      final now = DateTime.now().toIso8601String();
      id = await db.insert('item_categories', {
        'id': newGlobalId(),
        'name': name,
        'created_at': category.createdAt.toIso8601String(),
        'updated_at': now,
      });
      await queueOperation(
        entityType: EntityKind.itemCategory,
        entityId: '$id',
        opType: OpKind.create,
        payload: {
          'id': id,
          'name': name,
          'created_at': category.createdAt.toIso8601String(),
          'updated_at': now,
        },
      );
      await logActivity('إضافة فئة أصناف: $name', 'item_category', '$id');
      return id;
    }

    id = category.id!;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'item_categories',
        {'name': name, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'items',
        {'category': name, 'updated_at': now},
        where: 'category_id = ?',
        whereArgs: [id],
      );
      final rec = await newRecorder(txn);
      await rec.record(
        entityType: EntityKind.itemCategory,
        entityId: '$id',
        opType: OpKind.update,
        payload: {'id': id, 'name': name, 'updated_at': now},
      );
    });
    await logActivity('تعديل فئة أصناف: $name', 'item_category', '$id');
    return id;
  }

  /// يحذف الفئة فقط، ويفك ربط أصنافها لتبقى بيانات الأصناف محفوظة.
  Future<void> deleteItemCategory(int id) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    final rows = await db.query(
      'item_categories',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return;
    final name = rows.first['name'] as String;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update(
        'items',
        {'category_id': null, 'category': '', 'updated_at': now},
        where: 'category_id = ?',
        whereArgs: [id],
      );
      await txn.delete('item_categories', where: 'id = ?', whereArgs: [id]);
      final rec = await newRecorder(txn);
      await rec.record(
        entityType: EntityKind.itemCategory,
        entityId: '$id',
        opType: OpKind.delete_,
        payload: {'id': id},
      );
    });
    await logActivity('حذف فئة أصناف: $name', 'item_category', '$id');
  }

  // ==================== الأصناف والمخزون ====================

  Future<List<Item>> items({
    bool includeArchived = false,
    String q = '',
    bool includeDeleted = false,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (!includeArchived) where.add('archived = 0');
    if (!includeDeleted) where.add("COALESCE(deleted_at,'') = ''");
    if (q.trim().isNotEmpty) {
      where.add('(name LIKE ? OR sku LIKE ? OR category LIKE ?)');
      final like = '%${q.trim()}%';
      args.addAll([like, like, like]);
    }
    final rows = await db.query(
      'items',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(Item.fromMap).toList();
  }

  Future<Item?> item(int id) async {
    final db = await _db;
    final r = await db.query('items', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Item.fromMap(r.first);
  }

  Future<int> saveItem(Item it) async {
    await _ensureCan(it.id == null ? 'add_tx' : 'edit_tx');
    final db = await _db;
    // فرادة الباركود/SKU: صنفان بنفس الباركود يفسدان مسح نقطة البيع.
    final sku = it.sku.trim();
    if (sku.isNotEmpty) {
      final dup = await db.query('items',
          columns: ['id', 'name'],
          where: "sku = ? AND COALESCE(deleted_at,'') = ''"
              "${it.id != null ? ' AND id != ?' : ''}",
          whereArgs: it.id != null ? [sku, it.id] : [sku],
          limit: 1);
      if (dup.isNotEmpty) {
        throw StateError(
            'الباركود «$sku» مستخدم مسبقاً للصنف «${dup.first['name']}». '
            'كل صنف يجب أن يملك باركوداً فريداً.');
      }
    }
    late final int id;
    if (it.id == null) {
      id = await db.insert('items', it.toMap()..['id'] = newGlobalId());
      await queueOperation(
        entityType: EntityKind.item,
        entityId: '$id',
        opType: OpKind.create,
        payload: it.toMap()..['id'] = id,
      );
      await logActivity('إضافة صنف: ${it.name}', 'item', '$id');
    } else {
      id = it.id!;
      final map = it.toMap();
      await db.update('items', map, where: 'id = ?', whereArgs: [id]);
      await queueOperation(
        entityType: EntityKind.item,
        entityId: '$id',
        opType: OpKind.update,
        payload: map,
      );
      await logActivity('تعديل صنف: ${it.name}', 'item', '$id');
    }
    return id;
  }

  /// حذف ناعم للصنف (تبقى سطور الفواتير التاريخية باسم الصنف).
  Future<void> deleteItem(int id) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final r = await db.query('items', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return;
    await db.transaction((txn) async {
      await txn.update(
        'items',
        {'deleted_at': now, 'deleted_by': _currentUserId, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      final updated = (await txn.query(
        'items',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      ))
          .first;
      await SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      ).record(
        entityType: EntityKind.item,
        entityId: '$id',
        opType: OpKind.delete_,
        payload: Map<String, Object?>.from(updated),
      );
      await txn.insert('trash', {
        'store': 'items',
        'payload': jsonEncode(r.first),
        'label': 'صنف: ${r.first['name']}',
        'created_at': now,
      });
    });
    await logActivity('حذف صنف', 'item', '$id');
  }

  Future<List<StockMove>> stockMoves({int? itemId, int limit = 200}) async {
    final db = await _db;
    final rows = await db.query(
      'stock_moves',
      where: itemId == null ? null : 'item_id = ?',
      whereArgs: itemId == null ? null : [itemId],
      orderBy: 'date DESC, id DESC',
      limit: limit,
    );
    return rows.map(StockMove.fromMap).toList();
  }

  /// يسجّل حركة مخزنية ويحدّث كمية الصنف تلقائيًا.
  Future<int> addStockMove(StockMove m) async {
    await _ensureCan('add_tx');
    final db = await _db;
    late final int id;
    String? lowName;
    var lowQty = 0.0;
    var lowMin = 0.0;
    await db.transaction((txn) async {
      id = await txn.insert('stock_moves', m.toMap()..['id'] = newGlobalId());
      final r = await txn.query(
        'items',
        where: 'id = ?',
        whereArgs: [m.itemId],
        limit: 1,
      );
      if (r.isNotEmpty) {
        final it = Item.fromMap(r.first);
        final delta = m.kind == StockKind.adjust
            ? m.quantity - it.quantity
            : m.kind.qtySign * m.quantity;
        // منع البيع/الخصم بما يتجاوز الرصيد المتاح (لا مخزون سالب).
        if (m.kind == StockKind.sale && m.quantity > it.quantity) {
          throw StateError(
            'الكمية المطلوبة من «${it.name}» غير متوفرة. '
            'المتاح: ${it.quantity.toStringAsFixed(0)} ${it.unit}.',
          );
        }
        final now = DateTime.now().toIso8601String();
        await txn.update(
          'items',
          {'quantity': it.quantity + delta, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [m.itemId],
        );
        final rec = await newRecorder(txn);
        await rec.record(
          entityType: EntityKind.stockMove,
          entityId: '$id',
          opType: OpKind.create,
          payload: m.toMap()..['id'] = id,
        );
        await rec.record(
          entityType: EntityKind.item,
          entityId: '${m.itemId}',
          opType: OpKind.update,
          payload: {
            'id': m.itemId,
            'quantity': it.quantity + delta,
            'updated_at': now,
          },
        );
        await logActivityTx(
          txn,
          '${m.kind.label}: ${it.name} × ${m.quantity}',
          'stock',
          '$id',
        );
        lowName = it.name;
        lowQty = it.quantity + delta;
        lowMin = it.minQuantity;
      }
    });
    // تنبيه داخلي عند انخفاض المخزون عن حد التنبيه (بعد التزام العملية).
    if (lowName != null && lowMin > 0 && lowQty <= lowMin) {
      await notify(
        title: 'مخزون منخفض: $lowName',
        body: 'الكمية المتبقية ${lowQty.toStringAsFixed(0)} '
            'وصلت حد التنبيه ${lowMin.toStringAsFixed(0)}',
        kind: 'warning',
        entityType: 'item',
        entityId: '${m.itemId}',
      );
    }
    return id;
  }

  Future<void> deleteStockMove(int id) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    await db.transaction((txn) async {
      final r = await txn.query(
        'stock_moves',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (r.isEmpty) return;
      final m = StockMove.fromMap(r.first);
      final itRow = await txn.query(
        'items',
        where: 'id = ?',
        whereArgs: [m.itemId],
        limit: 1,
      );
      await txn.delete('stock_moves', where: 'id = ?', whereArgs: [id]);
      final rec = await newRecorder(txn);
      await rec.record(
        entityType: EntityKind.stockMove,
        entityId: '$id',
        opType: OpKind.delete_,
        payload: {'id': id},
      );
      if (itRow.isNotEmpty && m.kind != StockKind.adjust) {
        final it = Item.fromMap(itRow.first);
        final now = DateTime.now().toIso8601String();
        final newQty = it.quantity - m.kind.qtySign * m.quantity;
        await txn.update(
          'items',
          {'quantity': newQty, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [m.itemId],
        );
        await rec.record(
          entityType: EntityKind.item,
          entityId: '${m.itemId}',
          opType: OpKind.update,
          payload: {'id': m.itemId, 'quantity': newQty, 'updated_at': now},
        );
      }
    });
  }

  /// ملخّص المخزون: التكلفة والقيمة والربح المحقق والمتوقع.
  Future<Map<String, double>> inventorySummary() async {
    final all = await items();
    var cost = 0.0, value = 0.0, expected = 0.0, low = 0.0;
    for (final i in all) {
      cost += i.stockCost;
      value += i.stockValue;
      expected += i.expectedProfit;
      if (i.low || i.out) low++;
    }
    // الربح المحقق فعليًا من حركات البيع مقابل سعر الشراء الحالي.
    final db = await _db;
    final rows = await db.rawQuery(
      "SELECT s.quantity AS q, s.unit_price AS p, i.buy_price AS b "
      "FROM stock_moves s JOIN items i ON i.id = s.item_id "
      "WHERE s.kind = 'sale'",
    );
    var realised = 0.0, sales = 0.0;
    for (final r in rows) {
      final q = ((r['q'] ?? 0) as num).toDouble();
      final p = ((r['p'] ?? 0) as num).toDouble();
      final b = ((r['b'] ?? 0) as num).toDouble();
      realised += (p - b) * q;
      sales += p * q;
    }
    return {
      'items': all.length.toDouble(),
      'cost': cost,
      'value': value,
      'expected': expected,
      'realised': realised,
      'sales': sales,
      'low': low,
    };
  }

  // ==================== الإشعارات الداخلية ====================

  /// يضيف إشعارًا داخليًا جديدًا (تنبيه مخزون، اكتمال نسخة، فشل مزامنة…).
  /// [entityType]/[entityId] يربطان الإشعار بسجل محدد (مثل 'tx' ورقمه)
  /// حتى يفتح الضغط على الإشعار العملية المقصودة مباشرة.
  Future<void> notify({
    required String title,
    String body = '',
    String kind = 'info',
    String entityType = '',
    String entityId = '',
  }) async {
    final db = await _db;
    await db.insert('notifications', {
      'workspace_id': requireWorkspaceId, // (دفعة 57) عزل بالمساحة.
      'title': title,
      'body': body,
      'kind': kind,
      'seen': 0,
      'entity_type': entityType,
      'entity_id': entityId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// عدد رسائل الدردشة الواردة غير المقروءة (لشارة أيقونة الدردشة).
  /// «غير مقروءة» = وصلت بعد آخر فتح لشاشة الدردشة (chatLastSeenAt)
  /// وليست من إرسالنا (sender ليس جهازنا ولا 'me').
  Future<int> unreadChatMessages() async {
    final db = await _db;
    final st = await settings();
    final lastSeen = st['chatLastSeenAt'] ?? '';
    final ourId = requireDeviceId;
    return Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM messages WHERE sender <> 'me' AND sender <> ? "
          'AND created_at > ?',
          [ourId, lastSeen],
        )) ??
        0;
  }

  /// يوسم كل رسائل الدردشة كمقروءة (يُستدعى عند فتح شاشة الدردشة).
  Future<void> markChatSeen() async {
    await setSetting('chatLastSeenAt', DateTime.now().toIso8601String());
  }

  /// آخر الإشعارات الداخلية (الأحدث أولًا).
  Future<List<Map<String, Object?>>> notifications({int limit = 50}) async {
    final db = await _db;
    // (دفعة 57) إشعارات المساحة النشطة فقط.
    return db.query('notifications',
        where: 'workspace_id = ?',
        whereArgs: [requireWorkspaceId],
        orderBy: 'id DESC',
        limit: limit);
  }

  /// عدد الإشعارات غير المقروءة.
  Future<int> unreadNotifications() async {
    final db = await _db;
    // (دفعة 57) عزل بالمساحة النشطة — اتساقاً مع notifications().
    return Sqflite.firstIntValue(
          await db.rawQuery(
              'SELECT COUNT(*) FROM notifications '
              'WHERE seen = 0 AND workspace_id = ?',
              [requireWorkspaceId]),
        ) ??
        0;
  }

  /// تعليم كل الإشعارات كمقروءة.
  Future<void> markAllNotificationsSeen() async {
    final db = await _db;
    // (دفعة 57) لا نمسّ إشعارات مساحة أخرى على نفس الجهاز.
    await db.update('notifications', {'seen': 1},
        where: 'workspace_id = ?', whereArgs: [requireWorkspaceId]);
  }

  // ==================== الإحصاءات ====================

  Future<Map<String, int>> counts() async {
    final db = await _db;
    Future<int> c(String t, [String? where]) async =>
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM $t${where == null ? '' : ' WHERE $where'}',
          ),
        ) ??
        0;
    return {
      'accounts': await c('accounts', 'archived = 0'),
      'transactions': await c('transactions'),
      'vouchers': await c('vouchers'),
      'items': await c('items', 'archived = 0'),
      'trash': await c('trash'),
    };
  }
}
