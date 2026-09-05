import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/accounting.dart';
import '../core/database.dart';
import '../core/models.dart';
import 'sync/device_id.dart';
import 'sync/google_auth_service.dart';
import 'sync/operation.dart';
import 'sync/lan_http_transport.dart';
import 'sync/qr_pairing.dart';
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
  Future<Database> get _db async => AppDatabase.instance.database;
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
        'auth_secret': generateLanSecret(),
        'revoked_at': '',
        'ip_address': '',
        'port': kDefaultLanPort,
        'last_seen_at': now,
        'last_sync_at': '',
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // 🛟 بذرة مستخدم مدير افتراضي في أول تشغيل (إذا كان جدول المستخدمين فارغًا).
    final existingUsers = await db.query('users', limit: 1);
    if (existingUsers.isEmpty) {
      final adminPerms = defaultPerms(UserRole.admin);
      final permStr = adminPerms.entries.where((e) => e.value).map((e) => e.key).join(',');
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

    // استعادة جلسة Google بصمت (لا فتح نوافذ).
    try {
      final authSvc = GoogleAuthService(db);
      final ar = await authSvc.restoreSession();
      final gu = ar.user;
      if (gu != null && gu.id.isNotEmpty) {
        await linkWorkspaceToGoogle(db,
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
      // لا نرمي خطأ قاتل؛ في أسوأ الحالات نستخدم معرفًا مؤقتًا.
      // هذا يمنع انهيار التطبيق في شاشات لا تمر عبر initSyncInfra مباشرة.
      return 'DEVICE-UNKNOWN';
    }
    return _deviceId!;
  }

  String get requireWorkspaceId => _workspaceId ?? defaultWorkspaceId;

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
    await rec.record(entityType: entityType, entityId: entityId, opType: opType, payload: payload);
  }

  // ==================== الحسابات ====================

  Future<List<Account>> accounts({bool includeArchived = false, bool includeDeleted = false}) async {
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
        newId = await txn.insert('accounts', map);
        op = OpKind.create;
      } else {
        newId = a.id!;
        await txn.update('accounts', map, where: 'id = ?', whereArgs: [newId]);
        op = OpKind.update;
      }
      final rec = await SyncRecorder(
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
          'text': op == OpKind.create ? 'إضافة حساب: ${a.name}' : 'تعديل حساب: ${a.name}',
          'ref_type': 'account',
          'ref_id': '$newId',
          'workspace_id': requireWorkspaceId,
          'created_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return newId;
    });
    return id;
  }

  /// الأرشفة بدل الحذف — كما في نسخة الويب.
  Future<void> archiveAccount(int id, bool archived) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.update('accounts', {
        'archived': archived ? 1 : 0,
        'updated_at': now,
      }, where: 'id = ?', whereArgs: [id]);
      final rec = SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      );
      final row = (await txn.query('accounts', where: 'id = ?', whereArgs: [id], limit: 1)).first;
      await rec.record(
        entityType: EntityKind.account,
        entityId: '$id',
        opType: OpKind.update,
        payload: Map<String, Object?>.from(row),
      );
    });
    await logActivity(
        archived ? 'أرشفة حساب' : 'استعادة حساب', 'account', '$id');
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
      await txn.update('accounts', {
        'deleted_at': now,
        'deleted_by': _currentUserId,
        'updated_at': now,
      }, where: 'id = ?', whereArgs: [id]);
      final updated = (await txn.query('accounts', where: 'id = ?', whereArgs: [id], limit: 1)).first;
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
  Future<int> saveTx(Tx t, {List<InvoiceLine>? items}) async {
    await _ensureCan(t.id == null ? 'add_tx' : 'edit_tx');
    final db = await _db;
    late final int id;
    await db.transaction((txn) async {
      final rec = await SyncRecorder(
        db: txn,
        deviceId: requireDeviceId,
        workspaceId: requireWorkspaceId,
        userId: _currentUserId,
      );
      final now = DateTime.now().toIso8601String();
      if (t.id == null) {
        var ref = t.reference.trim();
        if (ref.isEmpty) {
          ref = await nextSeq('counter_tx', table: 'transactions');
        }
        final toSave = ref == t.reference ? t : t.copyWith(reference: ref);
        final map = toSave.toMap();
        map['workspace_id'] = requireWorkspaceId;
        map.remove('id');
        map['updated_at'] = now;
        id = await txn.insert('transactions', map);
        final saved = Map<String, Object?>.from(map)..['id'] = id;
        if (items != null) {
          await txn.delete('transaction_items', where: 'tx_id = ?', whereArgs: [id]);
          for (final line in items) {
            final lm = line.toMap(transactionId: id);
            lm['workspace_id'] = requireWorkspaceId;
            await txn.insert('transaction_items', lm);
          }
        }
        await rec.record(
          entityType: EntityKind.tx,
          entityId: '$id',
          opType: OpKind.create,
          payload: saved,
        );
      } else {
        id = t.id!;
        final map = t.toMap();
        map['workspace_id'] = requireWorkspaceId;
        map.remove('id');
        map['updated_at'] = now;
        await txn.update('transactions', map, where: 'id = ?', whereArgs: [id]);
        if (items != null) {
          await txn.delete('transaction_items', where: 'tx_id = ?', whereArgs: [id]);
          for (final line in items) {
            final lm = line.toMap(transactionId: id);
            lm['workspace_id'] = requireWorkspaceId;
            await txn.insert('transaction_items', lm);
          }
        }
        final saved = Map<String, Object?>.from(map)..['id'] = id;
        await rec.record(
          entityType: EntityKind.tx,
          entityId: '$id',
          opType: OpKind.update,
          payload: saved,
        );
      }
    });

    await logActivity(
      t.id == null ? '${t.type.label}: ${t.amount}' : 'تعديل عملية',
      'tx',
      '$id',
    );
    return id;
  }

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

  Future<void> deleteTx(int id) async {
    await _ensureCan('delete_tx');
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    await db.transaction((txn) async {
      await txn.update('transactions', {
        'deleted_at': now,
        'deleted_by': _currentUserId,
        'updated_at': now,
      }, where: 'id = ?', whereArgs: [id]);
      final updated = (await txn.query('transactions', where: 'id = ?', whereArgs: [id], limit: 1)).first;
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
        'payload': jsonEncode({'transaction': Map.from(rows.first), 'items': []}),
        'label': 'عملية بمبلغ ${rows.first['amount']} ${rows.first['currency']}',
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
    final rows = await db.query('transactions');
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
    final rows = await db.query('currencies');
    if (rows.isEmpty) return kDefaultCurrencies;
    return rows.map(CurrencyDef.fromMap).toList();
  }

  Future<void> saveCurrency(CurrencyDef c, {double rate = 1}) async {
    final db = await _db;
    final payload = {...c.toMap(), 'rate': rate};
    await db.insert('currencies', payload, conflictAlgorithm: ConflictAlgorithm.replace);
    await queueOperation(
      entityType: EntityKind.currency,
      entityId: c.code,
      opType: OpKind.update,
      payload: payload,
    );
  }

  Future<void> deleteCurrency(String code) async {
    final db = await _db;
    await db.delete('currencies', where: 'code = ?', whereArgs: [code]);
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
    return {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
  }

  Future<void> setSetting(String key, String value) async {
    final db = await _db;
    await db.insert('settings', {'key': key, 'value': value},
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

  Future<void> logActivityTx(Transaction txn, String text, String refType, String refId) async {
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
    final st = await settings();
    var counter = int.tryParse(st[counterKey] ?? '0') ?? 0;
    if (table != null) {
      try {
        final db = await _db;
        final r = await db.rawQuery('SELECT MAX(id) AS m FROM $table');
        final maxId = (r.first['m'] as int?) ?? 0;
        if (maxId > counter) counter = maxId;
      } catch (_) {}
    }
    counter += 1;
    await setSetting(counterKey, '$counter');
    return '$counter';
  }

  /// الرقم التسلسلي التالي لأي عملية مالية (رقمي بحت).
  Future<String> nextTxNumber() => nextSeq('counter_tx', table: 'transactions');

  /// الرقم التسلسلي التالي للسند (رقمي بحت بدون بادئة حرفية).
  Future<String> nextVoucherNumber([Object? _]) =>
      nextSeq('counter_voucher', table: 'vouchers');

  Future<int> saveVoucher(Voucher v) async {
    final db = await _db;
    late final int id;
    if (v.id == null) {
      id = await db.insert('vouchers', v.toMap());
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
    final me = await currentUser();
    if (me == null) return; // قبل وجود مستخدمين (أول تشغيل)
    if (!me.can(perm)) {
      throw StateError('ليس لديك صلاحية لهذا الإجراء.');
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
    await db.update('users', {'deleted_at': now, 'active': 0, 'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
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

  // ==================== الدردشة ====================

  /// محادثة لكل حساب، تُنشأ عند أول رسالة.
  Future<int> conversationFor(Account a) async {
    final db = await _db;
    final r = await db
        .query('conversations', where: 'title = ?', whereArgs: [a.name]);
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
    return db.query('conversations', orderBy: 'updated_at DESC');
  }

  Future<List<ChatMessage>> messages(int conversationId) async {
    final db = await _db;
    final rows = await db.query('messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'id ASC');
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

  Future<void> deleteMessage(int id) async {
    final db = await _db;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  // ==================== التصنيفات ====================

  Future<List<String>> categories() async {
    final db = await _db;
    final rows = await db.query('categories', orderBy: 'name ASC');
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<void> addCategory(String name) async {
    final db = await _db;
    await db.insert('categories', {
      'name': name,
      'scope': 'account',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> deleteCategory(String name) async {
    final db = await _db;
    await db.delete('categories', where: 'name = ?', whereArgs: [name]);
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
      if (store == 'transactions' && decoded is Map && decoded['transaction'] is Map) {
        final tx = Map<String, Object?>.from(decoded['transaction'] as Map);
        tx['deleted_at'] = '';
        tx['updated_at'] = now;
        await txn.insert('transactions', tx, conflictAlgorithm: ConflictAlgorithm.replace);
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
        // إن كان السجل الأصلي ما زال موجودًا (soft delete)، نُلغِ deleted_at.
        final id = payload['id'];
        final exists = await txn.query(store, where: 'id = ?', whereArgs: [id], limit: 1);
        if (exists.isNotEmpty) {
          await txn.update(store, {
            'deleted_at': '',
            'restore_op_id': '',
            'updated_at': now,
          }, where: 'id = ?', whereArgs: [id]);
          final restored = (await txn.query(store, where: 'id = ?', whereArgs: [id], limit: 1)).first;
          await rec.record(
            entityType: _entityKindFor(store),
            entityId: '$id',
            opType: OpKind.restore,
            payload: Map<String, Object?>.from(restored),
          );
        } else {
          payload.remove('deleted_at');
          payload['updated_at'] = now;
          await txn.insert(store, payload, conflictAlgorithm: ConflictAlgorithm.replace);
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
    final db = await _db;
    await db.delete('trash', where: 'id = ?', whereArgs: [trashId]);
  }

  Future<void> emptyTrash() async {
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
  Future<Map<String, Object?>> exportAll({bool withImages = true}) async {
    await _ensureCan('export');
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
            final f = File(path);
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

    return {
      'app': 'nexora',
      'format': 2,
      'db_version': AppDatabase.schemaVersion,
      'created_at': DateTime.now().toIso8601String(),
      'data': data,
      'images': images,
    };
  }

  /// يستبدل كل البيانات بمحتوى نسخة احتياطية ذرّيًا.
  ///
  /// اختلاف ترتيب الجداول لا يؤثر؛ أما الصف غير الصالح أو المرجع المفقود
  /// فيفشل العملية كلها ويعيد SQLite الحالة السابقة بدل استعادة جزئية صامتة.
  Future<int> importAll(Map<String, Object?> backup) async {
    await _ensureCan('manage_backup');
    final db = await _db;
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
        'name': name,
        'created_at': category.createdAt.toIso8601String(),
        'updated_at': now,
      });
      await queueOperation(
        entityType: EntityKind.itemCategory,
        entityId: '$id',
        opType: OpKind.create,
        payload: {'id': id, 'name': name, 'created_at': category.createdAt.toIso8601String(), 'updated_at': now},
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
    final db = await _db;
    final rows = await db.query('item_categories', where: 'id = ?', whereArgs: [id]);
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

  Future<List<Item>> items(
      {bool includeArchived = false, String q = '', bool includeDeleted = false}) async {
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
    final rows = await db.query('items',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'name COLLATE NOCASE');
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
    late final int id;
    if (it.id == null) {
      id = await db.insert('items', it.toMap());
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
      await txn.update('items', {
        'deleted_at': now,
        'deleted_by': _currentUserId,
        'updated_at': now,
      }, where: 'id = ?', whereArgs: [id]);
      final updated = (await txn.query('items', where: 'id = ?', whereArgs: [id], limit: 1)).first;
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
    final rows = await db.query('stock_moves',
        where: itemId == null ? null : 'item_id = ?',
        whereArgs: itemId == null ? null : [itemId],
        orderBy: 'date DESC, id DESC',
        limit: limit);
    return rows.map(StockMove.fromMap).toList();
  }

  /// يسجّل حركة مخزنية ويحدّث كمية الصنف تلقائيًا.
  Future<int> addStockMove(StockMove m) async {
    final db = await _db;
    late final int id;
    await db.transaction((txn) async {
      id = await txn.insert('stock_moves', m.toMap());
      final r = await txn.query('items', where: 'id = ?', whereArgs: [m.itemId], limit: 1);
      if (r.isNotEmpty) {
        final it = Item.fromMap(r.first);
        final delta = m.kind == StockKind.adjust
            ? m.quantity - it.quantity
            : m.kind.qtySign * m.quantity;
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
          payload: {'id': m.itemId, 'quantity': it.quantity + delta, 'updated_at': now},
        );
        await logActivityTx(txn, '${m.kind.label}: ${it.name} × ${m.quantity}', 'stock', '$id');
      }
    });
    return id;
  }

  Future<void> deleteStockMove(int id) async {
    final db = await _db;
    await db.transaction((txn) async {
      final r = await txn.query('stock_moves', where: 'id = ?', whereArgs: [id]);
      if (r.isEmpty) return;
      final m = StockMove.fromMap(r.first);
      final itRow = await txn.query('items', where: 'id = ?', whereArgs: [m.itemId], limit: 1);
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

  // ==================== الإحصاءات ====================

  Future<Map<String, int>> counts() async {
    final db = await _db;
    Future<int> c(String t, [String? where]) async =>
        Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM $t${where == null ? '' : ' WHERE $where'}')) ??
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
