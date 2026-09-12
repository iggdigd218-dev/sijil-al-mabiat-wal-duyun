// Apply an incoming operation using the actual primary key of each table.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/media_paths.dart';
import '../../core/models.dart';
import '../repository.dart';
import 'conflict_resolver.dart';
import 'operation.dart';

extension ApplyRemoteOp on Repo {
  /// Returns false for replay/ignored/conflicting operations. The caller owns
  /// the transaction, so entity data and the operation receipt commit together.
  Future<bool> applyRemoteOperation(
    DatabaseExecutor txn,
    SyncOperation op,
    ConflictResolver resolver,
  ) async {
    final table = _tableFor(op.entityType);
    final primaryKey = switch (op.entityType) {
      EntityKind.setting => 'key',
      EntityKind.currency => 'code',
      _ => 'id',
    };
    if (op.opType == OpKind.settings && op.entityType != EntityKind.setting) {
      throw const FormatException('Invalid settings operation');
    }
    final seen = await txn.query('operations',
        columns: ['id'], where: 'id = ?', whereArgs: [op.id], limit: 1);
    if (seen.isNotEmpty) return false;

    final existing = await txn.query(table,
        where: '$primaryKey = ?', whereArgs: [op.entityId], limit: 1);
    final latest = await txn.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [op.entityType.name, op.entityId],
        orderBy: 'version DESC, timestamp DESC',
        limit: 1);
    final localLatest =
        latest.isEmpty ? null : SyncOperation.fromMap(latest.first);
    final decision = resolver.decide(
      incoming: op,
      exists: existing.isNotEmpty,
      localVersion: localLatest?.version ?? 0,
      localLatest: localLatest,
    );
    if (decision.conflict) {
      await txn.insert('notifications', {
        'workspace_id': op.workspaceId, // (دفعة 57) عزل بالمساحة.
        'title': 'تعارض في المزامنة',
        'body': '${op.entityType.name}:${op.entityId} (device ${op.deviceId})',
        'kind': 'warning',
        'seen': 0,
        'entity_type': op.entityType.name,
        'entity_id': op.entityId,
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.insert('operations', _storedOpMap(op),
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return false;
    }
    if (!decision.apply) return false;

    // سطور الفاتورة تُنقل داخل حمولة العملية المالية (ليست كيانًا مستقلًا).
    final rawLines = op.payload['items'];
    final lines = rawLines is List
        ? rawLines.whereType<Map>().map(Map<String, Object?>.from).toList()
        : null;

    final tableInfo = await txn.rawQuery('PRAGMA table_info($table)');
    final columns = tableInfo.map((c) => c['name'] as String).toSet();
    final now = DateTime.now().toIso8601String();
    final row = <String, Object?>{
      for (final entry in op.payload.entries)
        if (entry.key != 'items' &&
            columns.contains(entry.key) &&
            entry.key != primaryKey)
          entry.key: entry.value,
      if (columns.contains('workspace_id')) 'workspace_id': op.workspaceId,
      if (columns.contains('updated_at')) 'updated_at': now,
    };
    // رسالة دردشة تشير لمحادثة غير موجودة محلياً: أنشئ المحادثة أولاً
    // (قيد المفتاح الأجنبي conversation_id) — عنوانها يأتي في الحمولة.
    if (op.entityType == EntityKind.message) {
      final convId = op.payload['conversation_id'];
      if (convId != null) {
        final conv = await txn.query('conversations',
            where: 'id = ?', whereArgs: [convId], limit: 1);
        if (conv.isEmpty) {
          await txn.insert('conversations', {
            'id': convId,
            'workspace_id': op.workspaceId,
            'title': (op.payload['conv_title'] as String?) ?? 'محادثة',
            'created_at': now,
            'updated_at': now,
          });
        }
      }
      // مرفق دردشة وارد (صورة/فيديو/ملف/صوت): الملف مضمّن base64 في
      // الحمولة — نعيد بناءه محلياً ونوجّه payload لمساره الجديد.
      final b64 = op.payload['file_b64'];
      if (b64 is String && b64.isNotEmpty) {
        try {
          final bytes = base64Decode(b64);
          final dir = await getApplicationDocumentsDirectory();
          final folder = Directory('${dir.path}/chat_media');
          await folder.create(recursive: true);
          final rawName = (op.payload['file_name'] as String?) ?? 'file';
          final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final local = File('${folder.path}/${op.entityId}_$safeName');
          await local.writeAsBytes(bytes, flush: true);
          // مسار نسبي (chat_media/...) لا مطلق — المطلق يتغيّر بين
          // الأجهزة وتحديثات النظام؛ التحويل يحدث وقت العرض.
          await MediaPaths.ensureDocsDir();
          row['payload'] = jsonEncode({
            'name': rawName,
            'size': bytes.length,
            'path': MediaPaths.toRelative(local.path),
          });
        } catch (_) {
          // فشل حفظ المرفق لا يمنع وصول الرسالة نفسها.
        }
      }
    }

    switch (op.opType) {
      case OpKind.create:
      case OpKind.update:
      case OpKind.settings:
        if (existing.isNotEmpty) {
          if (row.isNotEmpty) {
            await txn.update(table, row,
                where: '$primaryKey = ?', whereArgs: [op.entityId]);
          }
        } else {
          // إدراج كيان غير موجود محليًا: حمولة "تعديل" جزئية (مثل تعديل كمية
          // صنف فقط) لا تكفي لإنشاء صف صالح — كانت تكسر قيد NOT NULL فيعود
          // للجهاز المرسل خطأ 'internal' وتعلق قائمة المزامنة كلها في إعادة
          // محاولة أبدية. نُكمل الأعمدة الإلزامية الناقصة بقيم افتراضية آمنة
          // (النصوص فارغة، الأرقام صفر، التواريخ الآن) بدل الانفجار.
          final insertRow = {...row, primaryKey: op.entityId};
          for (final col in tableInfo) {
            final name = col['name'] as String;
            if (insertRow.containsKey(name)) continue;
            final notNull = (col['notnull'] as int? ?? 0) == 1;
            final hasDefault = col['dflt_value'] != null;
            final isPk = (col['pk'] as int? ?? 0) > 0;
            if (!notNull || hasDefault || isPk) continue;
            final type = ((col['type'] as String?) ?? '').toUpperCase();
            insertRow[name] = switch (name) {
              'created_at' || 'updated_at' || 'date' => now,
              _ => type.contains('INT') ||
                      type.contains('REAL') ||
                      type.contains('NUM')
                  ? 0
                  : '',
            };
          }
          await txn.insert(table, insertRow);
        }
        if (op.entityType == EntityKind.tx && lines != null) {
          await _replaceInvoiceLines(txn, op, lines);
        }
        break;
      case OpKind.delete_:
        if (columns.contains('deleted_at')) {
          await txn.update(
              table,
              {
                'deleted_at': op.deviceTime,
                // (دفعة 57) حذف متماثل: من حذف؟ + وسم الحالة synced —
                // العملية وصلتنا من السجل فلا يعاد بثها من هنا.
                // deleted_by يُختم بهوية الجهاز الحاذف لجداول الدردشة فقط
                // (النوع TEXT فيها) — في الجداول القديمة العمود INTEGER
                // لمعرّف مستخدم فلا نلوثه بنص.
                if (columns.contains('deleted_by') &&
                    (op.entityType == EntityKind.message ||
                        op.entityType == EntityKind.conversation))
                  'deleted_by': op.payload['deleted_by']?.toString() ??
                      op.deviceId,
                if (columns.contains('sync_state')) 'sync_state': 'synced',
                if (columns.contains('updated_at')) 'updated_at': now,
              },
              where: '$primaryKey = ?',
              whereArgs: [op.entityId]);
          // (دفعة 57) حذف محادثة وارد يسوّم رسائلها أيضاً — تناظر كامل
          // مع سلوك deleteConversation المحلي.
          if (op.entityType == EntityKind.conversation) {
            try {
              await txn.update(
                  'messages',
                  {
                    'deleted_at': op.deviceTime,
                    'deleted_by':
                        op.payload['deleted_by']?.toString() ?? op.deviceId,
                    'sync_state': 'synced',
                  },
                  where:
                      "conversation_id = ? AND COALESCE(deleted_at,'') = ''",
                  whereArgs: [op.entityId]);
            } catch (_) {}
          }
        } else {
          await txn.delete(table,
              where: '$primaryKey = ?', whereArgs: [op.entityId]);
        }
        // مزامنة سلة المهملات: الحذف الوارد من جهاز آخر يظهر في سلتنا
        // أيضاً حتى يمكن استرجاعه من أي جهاز في المجموعة.
        await _mirrorTrash(txn, op, existing);
        break;
      case OpKind.restore:
        if (columns.contains('deleted_at')) {
          await txn.update(
              table,
              {
                'deleted_at': '',
                if (columns.contains('restore_op_id')) 'restore_op_id': op.id,
                if (columns.contains('updated_at')) 'updated_at': now,
              },
              where: '$primaryKey = ?',
              whereArgs: [op.entityId]);
        }
        // الاسترجاع على جهاز آخر يزيل السجل المقابل من سلتنا المحلية.
        await _removeTrashMirror(txn, op);
        break;
    }
    // (إصلاح تسليم الإدارة) العملية السيادية ownershipTransfer: تقلب علم
    // الملكية محلياً فور وصولها — الجهاز المستلم يصبح مالكاً (is_owner=1
    // + workspaceMode=host) دون إعادة تشغيل أو مسح بيانات، والبقية تنزع
    // الملكية عن المدير السابق.
    if (op.entityType == EntityKind.setting &&
        op.entityId == 'ownershipTransfer') {
      await _applyOwnershipTransfer(txn, op);
    }
    await txn.insert('operations', _storedOpMap(op),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  /// تطبيق نقل الملكية الوارد: تحقق سيادي (المرسل هو المالك المعروف
  /// محلياً) ثم قلب الأعلام ذرياً داخل نفس المعاملة.
  Future<void> _applyOwnershipTransfer(
      DatabaseExecutor txn, SyncOperation op) async {
    try {
      final decoded = jsonDecode('${op.payload['value'] ?? '{}'}');
      if (decoded is! Map) return;
      final newOwnerDev = '${decoded['owner_device_id'] ?? ''}';
      final newOwnerUid = decoded['owner_user_id'];
      final isReclaim = decoded['reclaim'] == true;
      if (newOwnerDev.isEmpty) return;
      // تحقق سيادي: مصدر العملية يجب أن يكون المالك المعروف محلياً —
      // جهاز عضو لا يستطيع تزوير نقل ملكية لنفسه.
      final curOwner = await txn.query('devices',
          columns: ['id'], where: 'is_owner = 1', limit: 1);
      if (curOwner.isNotEmpty && '${curOwner.first['id']}' != op.deviceId) {
        // (صمام أمان) استثناء الاسترجاع: المدير السابق المسجل محلياً من
        // آخر تسليم يحق له استعادة الملكية خلال نافذة الاسترجاع — نتحقق
        // أن المصدر هو فعلاً المالك السابق المعروف لدينا، لا أي عضو.
        bool allowReclaim = false;
        if (isReclaim) {
          final prev = await txn.query('sync_meta',
              where: 'key = ?', whereArgs: ['prevOwnerDeviceId'], limit: 1);
          allowReclaim =
              prev.isNotEmpty && '${prev.first['value']}' == op.deviceId;
        }
        if (!allowReclaim) return;
      }
      final now = DateTime.now().toIso8601String();
      // ذاكرة المالك السابق: تُمكّن قبول عملية «استرجاع» شرعية لاحقاً،
      // ويُتحقق منها أعلاه — لا تُقبل إلا من هذا الجهاز تحديداً.
      final prevOwnerId = curOwner.isNotEmpty
          ? '${curOwner.first['id']}'
          : '${decoded['previous_owner_device_id'] ?? ''}';
      if (prevOwnerId.isNotEmpty && !isReclaim) {
        await txn.insert(
            'sync_meta', {'key': 'prevOwnerDeviceId', 'value': prevOwnerId},
            conflictAlgorithm: ConflictAlgorithm.replace);
      } else if (isReclaim) {
        // استرجاع مكتمل: تُمحى الذاكرة — تُستخدم مرة واحدة فقط.
        await txn.delete('sync_meta',
            where: 'key = ?', whereArgs: ['prevOwnerDeviceId']);
      }
      // (إصلاح أندرويد 7) العلم الاحتياطي للملكية على كل الأجهزة —
      // تقرأه isWorkspaceOwner عند غياب صف الجهاز مؤقتاً.
      await txn.insert(
          'sync_meta', {'key': 'ownerDeviceId', 'value': newOwnerDev},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // 1) نزع الملكية عن الجميع ثم تتويج الجهاز الجديد.
      await txn.update('devices', {'is_owner': 0, 'updated_at': now});
      await txn.update(
          'devices',
          {
            'is_owner': 1,
            if (newOwnerUid != null) 'user_id': newOwnerUid,
            'revoked_at': '',
            'expelled_at': '',
            'is_paired': 1,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [newOwnerDev]);
      // 2) ضمان أن مستخدم المالك الجديد مدير كامل الصلاحيات (حزام أمان
      //    إن سبقت هذه العملية عملياتِ users في الوصول).
      if (newOwnerUid != null) {
        final permStr = defaultPerms(UserRole.admin)
            .entries
            .where((e) => e.value)
            .map((e) => e.key)
            .join(',');
        await txn.update(
            'users',
            {
              'role': 'admin',
              'permissions': permStr,
              'active': 1,
              'deleted_at': '',
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [newOwnerUid]);
      }
      // 3) إن كنا نحن المستلم: الوضع يصبح host فوراً — تظهر «إدارة
      //    المجموعة» وشاشات الأجهزة دون خروج أو إعادة تشغيل.
      String ourId = '';
      try {
        ourId = requireDeviceId;
      } catch (_) {}
      if (ourId.isNotEmpty && ourId == newOwnerDev) {
        await txn.insert(
            'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {
      // حمولة تالفة لا تسقط بقية السحبة.
    }
  }

  /// صف العملية كما يُخزَّن محلياً: بعد فك مرفق الدردشة وحفظه على القرص
  /// نحذف حمولة base64 الضخمة من جدول operations (تبقى على السحابة/المرسل
  /// للأجهزة الأخرى) — تمنع تضخم القاعدة وتسريب الذاكرة عند قراءة العمليات.
  Map<String, Object?> _storedOpMap(SyncOperation op) {
    final m = op.toMap()..['synced'] = 1;
    final b64 = op.payload['file_b64'];
    if (b64 is String && b64.isNotEmpty) {
      final slim = Map<String, Object?>.from(op.payload)
        ..remove('file_b64')
        ..['file_pruned'] = 1; // عُولج المرفق وحُفظ في chat_media.
      m['payload'] = jsonEncode(slim);
    }
    return m;
  }

  /// حذف وارد من جهاز آخر → صف مطابق في سلة المهملات المحلية حتى تعرض
  /// كل الأجهزة نفس السلة ويمكن الاسترجاع من أيٍّ منها.
  Future<void> _mirrorTrash(
    DatabaseExecutor txn,
    SyncOperation op,
    List<Map<String, Object?>> existing,
  ) async {
    final store = switch (op.entityType) {
      EntityKind.account => 'accounts',
      EntityKind.tx => 'transactions',
      EntityKind.item => 'items',
      EntityKind.voucher => 'vouchers',
      _ => null, // بقية الكيانات لا تمر عبر السلة.
    };
    if (store == null) return;
    try {
      // منع التكرار: لا ندرج إن كان لدينا صف سلة لنفس الكيان.
      final marker = '"__sync_entity":"${op.entityType.name}:${op.entityId}"';
      final dup = await txn.query('trash',
          where: 'payload LIKE ?', whereArgs: ['%$marker%'], limit: 1);
      if (dup.isNotEmpty) return;
      final snapshot = existing.isNotEmpty
          ? Map<String, Object?>.from(existing.first)
          : Map<String, Object?>.from(op.payload)
        ..remove('items');
      snapshot['__sync_entity'] = '${op.entityType.name}:${op.entityId}';
      final label = switch (op.entityType) {
        EntityKind.account => 'حساب: ${snapshot['name'] ?? op.entityId}',
        EntityKind.tx =>
          'عملية بمبلغ ${snapshot['amount'] ?? '?'} ${snapshot['currency'] ?? ''}',
        EntityKind.item => 'صنف: ${snapshot['name'] ?? op.entityId}',
        EntityKind.voucher => 'سند: ${snapshot['ref'] ?? op.entityId}',
        _ => op.entityId,
      };
      await txn.insert('trash', {
        'store': store,
        'payload': jsonEncode(store == 'transactions'
            ? {'transaction': snapshot, 'items': const []}
            : snapshot),
        'label': '$label (حُذف من جهاز آخر)',
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // السلة انعكاس مساعد — فشلها لا يفشل تطبيق العملية.
    }
  }

  /// استرجاع وارد → إزالة صف السلة المقابل محلياً.
  Future<void> _removeTrashMirror(DatabaseExecutor txn, SyncOperation op) async {
    try {
      final marker = '"__sync_entity":"${op.entityType.name}:${op.entityId}"';
      await txn.delete('trash', where: 'payload LIKE ?', whereArgs: ['%$marker%']);
      // السجلات المحلية القديمة (بلا وسم): طابق بالمعرف داخل الحمولة.
      final idMarker = '"id":${op.entityId}';
      final store = switch (op.entityType) {
        EntityKind.account => 'accounts',
        EntityKind.tx => 'transactions',
        EntityKind.item => 'items',
        EntityKind.voucher => 'vouchers',
        _ => null,
      };
      if (store != null) {
        await txn.delete('trash',
            where: 'store = ? AND payload LIKE ?',
            whereArgs: [store, '%$idMarker%']);
      }
    } catch (_) {}
  }

  Future<void> _replaceInvoiceLines(
    DatabaseExecutor txn,
    SyncOperation op,
    List<Map<String, Object?>> lines,
  ) async {
    final cols = (await txn.rawQuery('PRAGMA table_info(transaction_items)'))
        .map((c) => c['name'] as String)
        .toSet();
    final txId = int.tryParse(op.entityId) ?? op.entityId;
    await txn
        .delete('transaction_items', where: 'tx_id = ?', whereArgs: [txId]);
    for (final line in lines) {
      final row = <String, Object?>{
        for (final e in line.entries)
          if (cols.contains(e.key)) e.key: e.value,
        'tx_id': txId,
        if (cols.contains('workspace_id')) 'workspace_id': op.workspaceId,
      };
      await txn.insert('transaction_items', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  String _tableFor(EntityKind kind) => switch (kind) {
        EntityKind.account => 'accounts',
        EntityKind.tx => 'transactions',
        EntityKind.item => 'items',
        EntityKind.itemCategory => 'item_categories',
        EntityKind.stockMove => 'stock_moves',
        EntityKind.voucher => 'vouchers',
        EntityKind.user => 'users',
        EntityKind.currency => 'currencies',
        EntityKind.setting => 'settings',
        EntityKind.category => 'categories',
        EntityKind.conversation => 'conversations',
        EntityKind.message => 'messages',
      };
}
