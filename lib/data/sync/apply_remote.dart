// Apply an incoming operation using the actual primary key of each table.
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

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
        'title': 'تعارض في المزامنة',
        'body': '${op.entityType.name}:${op.entityId} (device ${op.deviceId})',
        'kind': 'warning',
        'seen': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.insert('operations', op.toMap()..['synced'] = 1,
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
                if (columns.contains('updated_at')) 'updated_at': now,
              },
              where: '$primaryKey = ?',
              whereArgs: [op.entityId]);
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
    await txn.insert('operations', op.toMap()..['synced'] = 1,
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
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
