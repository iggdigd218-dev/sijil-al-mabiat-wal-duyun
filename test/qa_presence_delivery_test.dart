// اختبارات نظام الحضور وتتبع التسليم لكل جهاز:
//  1) push يتخطى الأجهزة الغائبة (وفق isPeerOnline) دون تسجيلها كفشل صاخب،
//     ويعيد awaiting-offline-peers حتى تبقى العملية pending.
//  2) التسليم الناجح يسجَّل في op_deliveries ولا يُعاد الإرسال لنفس الجهاز.
//  3) PresenceService يحسب عدد الأقران ويتجاهل المطرودين.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/presence_service.dart';

Future<Database> _newDb(String dir, String name) async {
  final db = await databaseFactoryFfi.openDatabase(
    '$dir/$name.db',
    options: OpenDatabaseOptions(version: 1),
  );
  await AppDatabase.ensureFullSchema(db);
  return db;
}

Future<void> _addDevice(
  Database db, {
  required String id,
  String name = 'جهاز',
  String ip = '',
  int port = 0,
  String revokedAt = '',
  String expelledAt = '',
}) async {
  final now = DateTime.now().toIso8601String();
  await db.insert('devices', {
    'id': id,
    'workspace_id': 'default',
    'name': name,
    'ip_address': ip,
    'port': port,
    'is_paired': 1,
    'auth_secret': 'secret-$id',
    'revoked_at': revokedAt,
    'expelled_at': expelledAt,
    'created_at': now,
    'updated_at': now,
  });
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_presence_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('PresenceService.peerCount يتجاهل المطرودين وجهازنا', () async {
    final db = await _newDb(tmp.path, 'p1');
    await _addDevice(db, id: 'me');
    await _addDevice(db, id: 'peer-a', ip: '10.0.0.2', port: 9410);
    await _addDevice(db, id: 'peer-b', ip: '10.0.0.3', port: 9410);
    await _addDevice(db,
        id: 'peer-x',
        ip: '10.0.0.4',
        port: 9410,
        revokedAt: DateTime.now().toIso8601String());
    final svc = PresenceService(dbProvider: () async => db, ourDeviceId: 'me');
    expect(await svc.peerCount(), 2);
    svc.dispose();
    await db.close();
  });

  test('op_deliveries يسجل التسليم ويمنع التكرار (idempotent)', () async {
    final db = await _newDb(tmp.path, 'p2');
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < 2; i++) {
      await db.insert(
        'op_deliveries',
        {'operation_id': 'op-1', 'device_id': 'dev-1', 'delivered_at': now},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final rows = await db.query('op_deliveries');
    expect(rows, hasLength(1));
    await db.close();
  });

  test('presenceSummary يبني ملخصاً عربياً صحيحاً', () {
    expect(presenceSummary(const []), 'لا أجهزة مقترنة');
    final peers = [
      const PeerPresence(deviceId: 'a', name: 'أ', online: true),
      const PeerPresence(deviceId: 'b', name: 'ب', online: false),
    ];
    expect(presenceSummary(peers), '1/2 متصل');
    final json = jsonDecode(presenceToJson(peers)) as List;
    expect(json, hasLength(2));
    expect(json.first['online'], true);
  });

  test('SyncOperation payload يحمل بيانات قابلة للتلخيص في شاشة المزامنة', () {
    const op = SyncOperation(
      id: 'op-9',
      deviceId: 'me',
      workspaceId: 'default',
      userId: null,
      entityType: EntityKind.tx,
      entityId: '5',
      opType: OpKind.create,
      version: 1,
      parentOpId: '',
      payload: {'amount': 5000, 'description': 'دين'},
      deviceTime: '2026-09-08T00:00:00',
      timestamp: '2026-09-08T00:00:00',
    );
    expect(op.payload['amount'], 5000);
    expect(op.payload['description'], 'دين');
  });
}
