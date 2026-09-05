// مسجّل العمليات: يُستدعى داخل معاملة الحفظ لإدخال Operation
// وإدراجها في sync_queue atomically مع حفظ الكيان المحلي.
import 'package:sqflite/sqflite.dart';

import 'device_id.dart';
import 'operation.dart';
import 'sync_queue.dart';
import 'workspace_service.dart';

class SyncRecorder {
  final Database db;
  final String deviceId;
  final int? userId;
  String workspaceId;

  SyncRecorder({
    required this.db,
    required this.deviceId,
    required this.workspaceId,
    this.userId,
  });

  static Future<SyncRecorder> forTransaction(Database db,
      {required String deviceId, int? userId, String workspaceId = defaultWorkspaceId}) async {
    return SyncRecorder(
        db: db, deviceId: deviceId, userId: userId, workspaceId: workspaceId);
  }

  /// آخر version معروف للكيان (للبدء من 1 إن لم يوجد).
  Future<int> nextVersion(EntityKind entity, String entityId) async {
    final r = await db.rawQuery(
        'SELECT MAX(version) AS v FROM operations WHERE entity_type = ? AND entity_id = ?',
        [entity.name, entityId]);
    final cur = (r.first['v'] as int?) ?? 0;
    return cur + 1;
  }

  /// يسجّل عملية في جدول operations + صفوف في sync_queue.
  /// يُستدعى داخل Transaction.
  Future<String> record({
    required EntityKind entityType,
    required String entityId,
    required OpKind opType,
    required Map<String, Object?> payload,
    String parentOpId = '',
    int? version,
    List<String> extraTargets = const [], // مثلاً device:<id>
  }) async {
    final id = uuid();
    final now = DateTime.now();
    final v = version ?? await nextVersion(entityType, entityId);
    final op = SyncOperation(
      id: id,
      deviceId: deviceId,
      workspaceId: workspaceId,
      userId: userId,
      entityType: entityType,
      entityId: entityId,
      opType: opType,
      version: v,
      parentOpId: parentOpId,
      payload: payload,
      deviceTime: now.toIso8601String(),
      timestamp: now.toIso8601String(),
    );
    await db.insert('operations', op.toMap());

    final qnow = now.toIso8601String();
    // هدف Cloud دائمًا إن كان مُفعّلًا لاحقًا — نضيفه افتراضيًا حتى لا يضيع أي operation.
    final targets = <String>{SyncTarget.cloud, ...extraTargets};
    for (final t in targets) {
      await db.insert('sync_queue', {
        'operation_id': id,
        'status': SyncStatus.pending.name,
        'target': t,
        'attempts': 0,
        'last_error': '',
        'next_try_at': '',
        'created_at': qnow,
        'updated_at': qnow,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    return id;
  }
}
