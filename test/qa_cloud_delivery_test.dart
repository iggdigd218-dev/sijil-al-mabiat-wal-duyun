// QA: التسليم عبر السحابة للأقران غير القابلين للوصول عبر LAN.
// السيناريو الحقيقي (عطل الإنتاج): مجموعة مرتبطة عبر المزامنة السحابية،
// الأجهزة ليست على نفس الشبكة المحلية — كانت العمليات تعلق للأبد بخطأ
// awaiting-offline-peers رغم صعودها للسحابة ووصولها فعلاً لكل الأجهزة.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/lan_http_transport.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Repo repoA;
  late LanSyncService sender;
  const aId = 'DEVICE-CLOUDQA-A';
  const bId = 'DEVICE-CLOUDQA-B';
  final now = DateTime(2026, 9, 9);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_clouddeliv_');
    a = await databaseFactory.openDatabase('${tmp.path}/a.db');
    await AppDatabase.createSchema(a);
    repoA = Repo(databaseProvider: () async => a);
    await repoA.setSetting('sync.deviceId', aId);
    await repoA.initSyncInfra();
    await repoA.setSetting('lanSyncEnabled', '1');
    await a.update('devices', {'auth_secret': 'qa-secret-a'},
        where: 'id = ?', whereArgs: [aId]);
    // قرين منضم عبر السحابة: مقترن لكن بلا عنوان LAN إطلاقاً.
    await a.insert('devices', {
      'id': bId,
      'workspace_id': 'default',
      'name': 'جهاز سحابي',
      'auth_secret': 'qa-secret-b',
      'is_paired': 1,
      'ip_address': '',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    sender =
        LanSyncService(repo: repoA, dbProvider: () async => a, ourDeviceId: aId);
  });
  tearDown(() async {
    await a.close();
    await tmp.delete(recursive: true);
  });

  Future<SyncOperation> createOp() async {
    final id = await repoA.saveAccount(Account(
        name: 'عميل التسليم السحابي',
        kind: AccountKind.customer,
        createdAt: now,
        updatedAt: now));
    final rows = await a.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['account', '$id']);
    return SyncOperation.fromMap(rows.last);
  }

  test(
      'QA-CD-01 op on cloud + peer unreachable on LAN => delivered via cloud, no awaiting-offline-peers',
      () async {
    await repoA.setSetting(
        'cloudBackendUrl', 'https://qa.firebasedatabase.app');
    final op = await createOp();
    // العملية صعدت للسحابة (synced=1) — كما يفعل CloudFirebaseTransport.push.
    await a.update('operations', {'synced': 1},
        where: 'id = ?', whereArgs: [op.id]);
    // يجب ألا يرمي awaiting-offline-peers.
    await sender.push(op);
    final deliv = await a.query('op_deliveries',
        where: 'operation_id = ? AND device_id = ?', whereArgs: [op.id, bId]);
    expect(deliv, hasLength(1),
        reason: 'القرين السحابي يجب أن يُعلَّم مُسلَّماً عبر السحابة');
  });

  test(
      'QA-CD-02 op NOT on cloud yet + presence-offline peer => awaiting-offline-peers (no false delivery)',
      () async {
    await repoA.setSetting(
        'cloudBackendUrl', 'https://qa.firebasedatabase.app');
    await a.update('devices', {'ip_address': '10.0.0.99', 'port': 4545},
        where: 'id = ?', whereArgs: [bId]);
    sender.isPeerOnline = (_) => false;
    final op = await createOp(); // synced=0
    expect(
      () => sender.push(op),
      throwsA(predicate(
          (e) => e.toString().contains('awaiting-offline-peers'))),
    );
    final deliv = await a
        .query('op_deliveries', where: 'operation_id = ?', whereArgs: [op.id]);
    expect(deliv, isEmpty);
  });

  test(
      'QA-CD-03 no cloud configured => LAN-only behavior unchanged (awaiting-offline-peers)',
      () async {
    await a.update('devices', {'ip_address': '10.0.0.99', 'port': 4545},
        where: 'id = ?', whereArgs: [bId]);
    sender.isPeerOnline = (_) => false;
    final op = await createOp();
    await a.update('operations', {'synced': 1},
        where: 'id = ?', whereArgs: [op.id]);
    expect(
      () => sender.push(op),
      throwsA(predicate(
          (e) => e.toString().contains('awaiting-offline-peers'))),
    );
    final deliv = await a
        .query('op_deliveries', where: 'operation_id = ?', whereArgs: [op.id]);
    expect(deliv, isEmpty);
  });

  test('QA-CD-04 peer online via LAN presence but offline => cloud satisfies it',
      () async {
    await repoA.setSetting(
        'cloudBackendUrl', 'https://qa.firebasedatabase.app');
    // قرين له IP لكن الحضور يقول غائب (شبكة مختلفة).
    await a.update('devices', {'ip_address': '10.0.0.99', 'port': 4545},
        where: 'id = ?', whereArgs: [bId]);
    sender.isPeerOnline = (_) => false;
    final op = await createOp();
    await a.update('operations', {'synced': 1},
        where: 'id = ?', whereArgs: [op.id]);
    await sender.push(op);
    final deliv = await a.query('op_deliveries',
        where: 'operation_id = ? AND device_id = ?', whereArgs: [op.id, bId]);
    expect(deliv, hasLength(1));
  });
}
