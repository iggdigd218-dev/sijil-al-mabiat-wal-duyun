// منطق تطبيق عملية قادمة من جهاز/سحابة على قاعدة البيانات المحلية.
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/models.dart';
import '../repository.dart';
import 'conflict_resolver.dart';
import 'operation.dart';

extension ApplyRemoteOp on Repo {
  /// يطبّق عملية قادمة من الخارج (Cloud/LAN).
  /// يعيد true إذا طُبقت، false إذا تجاهل/تعارض.
  Future<bool> applyRemoteOperation(
    DatabaseExecutor txn,
    SyncOperation op,
    ConflictResolver resolver,
  ) async {
    final table = _tableFor(op.entityType);
    if (table == null) return false;

    // 1) هل الكيان موجود محليًا؟
    final existing = await txn.query(table,
        where: 'id = ?', whereArgs: [op.entityId], limit: 1);
    final exists = existing.isNotEmpty;

    // 2) أعلى version محلي للكيان + آخر عملية مسجلة.
    final vRow = await txn.rawQuery(
        'SELECT MAX(version) AS v FROM operations WHERE entity_type = ? AND entity_id = ?',
        [op.entityType.name, op.entityId]);
    final localVersion = (vRow.first['v'] as int?) ?? 0;
    final latestRows = await txn.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [op.entityType.name, op.entityId],
        orderBy: 'version DESC, timestamp DESC',
        limit: 1);
    SyncOperation? localLatest;
    if (latestRows.isNotEmpty) {
      try {
        localLatest = SyncOperation.fromMap(latestRows.first);
      } catch (_) {}
    }

    // 3) القرار.
    final decision = resolver.decide(
      incoming: op,
      exists: exists,
      localVersion: localVersion,
      localLatest: localLatest,
    );

    if (decision.conflict) {
      // سجّل التعارض في notifications ولا تطبّق (المستخدم يراجعه لاحقًا).
      await txn.insert('notifications', {
        'title': 'تعـارض في المزامنة',
        'body': '${op.entityType.name}:${op.entityId} (device ${op.deviceId})',
        'kind': 'warning',
        'seen': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
      // نسجل العملية في السجل مع synced=1 حتى لا تتكرر، لكن لا نُطبّقها.
      await txn.insert('operations', op.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return false;
    }

    if (!decision.apply) return false;

    // 4) التطبيق حسب النوع.
    final row = _tableRow(op.payload);
    if (row == null) return false;
    final now = DateTime.now().toIso8601String();
    final norm = Map<String, Object?>.from(row);
    norm.remove('id'); // نستخدم entityId كـ id.
    norm['workspace_id'] = op.workspaceId;
    norm['updated_at'] = now;

    switch (op.opType) {
      case OpKind.create:
      case OpKind.update:
        if (exists) {
          await txn.update(table, norm, where: 'id = ?', whereArgs: [op.entityId]);
        } else {
          await txn.insert(table, {...norm, 'id': op.entityId},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        break;
      case OpKind.delete_:
        // soft-delete إن كان الجدول يدعمها.
        if (await _hasColumn(txn, table, 'deleted_at')) {
          await txn.update(table, {
            'deleted_at': op.deviceTime,
            'updated_at': now,
          }, where: 'id = ?', whereArgs: [op.entityId]);
        } else {
          await txn.delete(table, where: 'id = ?', whereArgs: [op.entityId]);
        }
        break;
      case OpKind.restore:
        if (await _hasColumn(txn, table, 'deleted_at')) {
          await txn.update(table, {
            'deleted_at': '',
            'restore_op_id': op.id,
            'updated_at': now,
          }, where: 'id = ?', whereArgs: [op.entityId]);
        }
        break;
      case OpKind.settings:
        final key = op.payload['key'] as String?;
        final value = op.payload['value'] as String?;
        if (key != null && value != null) {
          await txn.insert('settings', {'key': key, 'value': value},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        break;
    }

    // 5) سجلّ العملية محليًا كـ synced (لا نضيفها مرة أخرى للطابور).
    await txn.insert('operations', op.toMap()..['synced'] = 1,
        conflictAlgorithm: ConflictAlgorithm.ignore);

    return true;
  }

  String? _tableFor(EntityKind k) => switch (k) {
        EntityKind.account => 'accounts',
        EntityKind.tx => 'transactions',
        EntityKind.item => 'items',
        EntityKind.itemCategory => 'item_categories',
        EntityKind.stockMove => 'stock_moves',
        EntityKind.voucher => 'vouchers',
        EntityKind.user => 'users',
        EntityKind.currency => 'currencies',
        EntityKind.setting => 'settings',
      };

  Map<String, Object?>? _tableRow(Map<String, Object?> payload) {
    // payload هو snapshot كامل للكيان.
    return payload;
  }

  Future<bool> _hasColumn(DatabaseExecutor txn, String table, String col) async {
    final cols = await txn.rawQuery('PRAGMA table_info($table)');
    return cols.any((c) => c['name'] == col);
  }
}
