import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/lan_http_transport.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This suite intentionally uses only real loopback HTTP, not the binding mock.
  HttpOverrides.global = null;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  late LanSyncService sender;
  late LanSyncService receiver;
  late int port;
  const aId = 'DEVICE-QATESTAA';
  const bId = 'DEVICE-QATESTBB';
  const aSecret = 'qa-A-only-secret';
  const bSecret = 'qa-B-only-secret';
  final now = DateTime(2026, 9, 6);

  Future<SyncOperation> createAccountOperation() async {
    final id = await repoA.saveAccount(Account(
        name: 'LAN QA',
        kind: AccountKind.customer,
        createdAt: now,
        updatedAt: now));
    final rows = await a.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['account', '$id']);
    return SyncOperation.fromMap(rows.last);
  }

  Future<(int, String)> post(SyncOperation op, {String? secret}) async {
    final client = HttpClient();
    try {
      final request =
          await client.postUrl(Uri.parse('http://127.0.0.1:$port/ops'));
      if (secret != null)
        request.headers.set('Authorization', 'Bearer $secret');
      request.headers.contentType = ContentType.json;
      request.write(op.toJson());
      final response = await request.close();
      return (
        response.statusCode,
        await response.transform(utf8.decoder).join()
      );
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_lan_');
    a = await databaseFactory.openDatabase('${tmp.path}/a.db');
    b = await databaseFactory.openDatabase('${tmp.path}/b.db');
    await AppDatabase.createSchema(a);
    await AppDatabase.createSchema(b);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoA.setSetting('sync.deviceId', aId);
    await repoB.setSetting('sync.deviceId', bId);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await repoA.setSetting('lanSyncEnabled', '1');
    await a.update('devices', {'auth_secret': aSecret},
        where: 'id = ?', whereArgs: [aId]);
    await b.update('devices', {'auth_secret': bSecret},
        where: 'id = ?', whereArgs: [bId]);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = socket.port;
    await socket.close();
    // Matching the current pairing protocol: each DB stores its peer's secret,
    // while /ops authenticates using the sender's device ID and that secret.
    await a.insert('devices', {
      'id': bId,
      'workspace_id': 'default',
      'name': 'B',
      'auth_secret': bSecret,
      'is_paired': 1,
      'ip_address': '127.0.0.1',
      'port': port,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    await b.insert('devices', {
      'id': aId,
      'workspace_id': 'default',
      'name': 'A',
      'auth_secret': aSecret,
      'is_paired': 1,
      'ip_address': '127.0.0.1',
      'port': port,
      'user_id': 1,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    sender = LanSyncService(
        repo: repoA, dbProvider: () async => a, ourDeviceId: aId);
    receiver = LanSyncService(
        repo: repoB, dbProvider: () async => b, ourDeviceId: bId, port: port);
    await receiver.startServer();
    expect(receiver.isRunning, isTrue);
  });
  tearDown(() async {
    await sender.stopServer();
    await receiver.stopServer();
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  test('QA-LAN-01 requests without authentication are rejected without writes',
      () async {
    final op = await createAccountOperation();
    final result = await post(op);
    expect(result.$1, HttpStatus.unauthorized);
    expect(await repoB.accounts(), isEmpty);
  });

  test(
      'QA-LAN-02 correct sender credential applies once; replay does not duplicate',
      () async {
    final op = await createAccountOperation();
    expect((await post(op, secret: aSecret)).$1, HttpStatus.ok);
    expect(await repoB.accounts(), hasLength(1));
    final again = await post(op, secret: aSecret);
    expect(again.$1, HttpStatus.ok);
    expect((jsonDecode(again.$2) as Map)['applied'], 0);
    expect(await repoB.accounts(), hasLength(1));
  });

  test(
      'QA-LAN-03 actual sender uses its own identity credential, not peer credential',
      () async {
    final op = await createAccountOperation();
    await sender.push(op);
    expect((await repoB.accounts()).single.name, 'LAN QA');
  });

  test('QA-LAN-04 save to queue to engine to HTTP to receiving SQLite',
      () async {
    final op = await createAccountOperation();
    final engine = SyncEngine(repo: repoA, dbProvider: () async => a);
    engine.registerTransport(sender);
    try {
      await engine.processQueue();
      expect(await repoB.accounts(), hasLength(1));
      final q = await a.query('sync_queue',
          where: 'operation_id = ? AND target = ?',
          whereArgs: [op.id, SyncTarget.lanBroadcast]);
      expect(q.single['status'], 'synced');
      expect((await repoA.accounts()).single.name,
          (await repoB.accounts()).single.name);
    } finally {
      engine.stop();
    }
  });

  test('QA-LAN-05 unknown credential and revoked sender cannot write',
      () async {
    final op = await createAccountOperation();
    expect((await post(op, secret: 'wrong')).$1, HttpStatus.forbidden);
    await b.update('devices', {'revoked_at': now.toIso8601String()},
        where: 'id = ?', whereArgs: [aId]);
    expect((await post(op, secret: aSecret)).$1, HttpStatus.gone);
    expect(await repoB.accounts(), isEmpty);
  });
  test('QA-LAN-06 paired viewer cannot submit financial writes over HTTP',
      () async {
    final op = await createAccountOperation();
    await b.update('users', {'role': 'viewer', 'permissions': ''},
        where: 'id = 1');
    expect((await post(op, secret: aSecret)).$1, HttpStatus.forbidden);
    expect(await repoB.accounts(), isEmpty);
  });

  test(
      'QA-LAN-07 snapshot excludes other device credentials and password hashes',
      () async {
    await b.update(
        'users', {'password': 'qa-private-hash', 'pin': 'qa-private-pin'});
    final client = HttpClient();
    try {
      final request =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/snapshot'));
      request.headers.set('Authorization', 'Bearer $aSecret');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, HttpStatus.ok);
      expect(body, isNot(contains(bSecret)));
      expect(body, isNot(contains('qa-private-hash')));
      expect(body, isNot(contains('qa-private-pin')));
    } finally {
      client.close(force: true);
    }
  });

  test('QA-LAN-08 no reachable peer is not a successful broadcast', () async {
    final op = await createAccountOperation();
    await a.delete('devices', where: 'id = ?', whereArgs: [bId]);
    await expectLater(sender.push(op), throwsA(isA<StateError>()));
  });

  test('QA-LAN-09 pairing response identifies host and transfers a snapshot',
      () async {
    await b.update(
        'devices',
        {
          'pair_token': 'QAP12345',
          'pair_token_exp':
              DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [bId]);
    final result =
        await sender.pairWith('127.0.0.1', port, 'QAP12345', ourPort: 43054);
    expect(result.ok, isTrue, reason: result.error);
    expect(result.remoteDeviceId, bId);
    expect(result.snapshot, isNotNull);
  });
}
