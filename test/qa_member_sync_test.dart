// QA — دفعة 25:
// 1) مزامنة عضو↔عضو تعمل بغياب المدير (توزيع أسرار الأقران عبر roster).
// 2) سلة المهملات متزامنة: الحذف الوارد يُنشئ صف سلة، والاسترجاع يزيله.
// 3) النسخ الاحتياطية موسومة ببصمة المجموعة ولا تُستورد نسخة غريبة.
// 4) جهاز العضو لا يستطيع الاقتران خارج مجموعته.
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
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database o; // owner (المدير)
  late Database a; // member A
  late Database b; // member B
  late Repo repoO;
  late Repo repoA;
  late Repo repoB;
  LanSyncService? serverO;
  LanSyncService? serverB;
  late LanSyncService lanA;
  late int portO;
  late int portB;
  const oId = 'DEVICE-QAOWNER0';
  const aId = 'DEVICE-QAMEMBRA';
  const bId = 'DEVICE-QAMEMBRB';
  const oSecret = 'qa-owner-secret';
  const aSecret = 'qa-memberA-secret';
  const bSecret = 'qa-memberB-secret';
  final now = DateTime(2026, 9, 8);

  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<void> insertDevice(
    Database db,
    String id,
    String secret, {
    bool owner = false,
    String ip = '',
    int port = 0,
    int? userId,
  }) async {
    await db.insert(
        'devices',
        {
          'id': id,
          'workspace_id': 'default',
          'name': id.substring(id.length - 1),
          'auth_secret': secret,
          'is_paired': 1,
          'is_owner': owner ? 1 : 0,
          'ip_address': ip,
          'port': port,
          'user_id': userId,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_member_');
    o = await databaseFactory.openDatabase('${tmp.path}/o.db');
    a = await databaseFactory.openDatabase('${tmp.path}/a.db');
    b = await databaseFactory.openDatabase('${tmp.path}/b.db');
    for (final db in [o, a, b]) {
      await AppDatabase.createSchema(db);
    }
    repoO = Repo(databaseProvider: () async => o);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoO.setSetting('sync.deviceId', oId);
    await repoA.setSetting('sync.deviceId', aId);
    await repoB.setSetting('sync.deviceId', bId);
    await repoO.initSyncInfra();
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    portO = await freePort();
    portB = await freePort();
    // هوية كل جهاز وسرّه.
    await o.update('devices', {'auth_secret': oSecret, 'is_owner': 1},
        where: 'id = ?', whereArgs: [oId]);
    await a.update('devices', {'auth_secret': aSecret, 'is_owner': 0},
        where: 'id = ?', whereArgs: [aId]);
    await b.update('devices', {'auth_secret': bSecret, 'is_owner': 0},
        where: 'id = ?', whereArgs: [bId]);
    // مستخدم فعّال بصلاحيات كاملة على كل قاعدة (id=1 من initSyncInfra seed
    // غير مضمون هنا، لذلك ندرجه صراحة).
    for (final db in [o, a, b]) {
      await db.insert(
          'users',
          {
            'id': 1,
            'name': 'QA',
            'role': 'admin',
            'permissions': '',
            'is_me': 1,
            'active': 1,
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ربط جهاز كل قاعدة بالمستخدم 1 (وضع العضو يعتمد devices.user_id).
    await o.update('devices', {'user_id': 1}, where: 'id = ?', whereArgs: [oId]);
    await a.update('devices', {'user_id': 1}, where: 'id = ?', whereArgs: [aId]);
    await b.update('devices', {'user_id': 1}, where: 'id = ?', whereArgs: [bId]);
    // المدير يعرف الجميع؛ العضو A يعرف الجميع (اكتسب الأسرار من roster)؛
    // العضو B يعرف المدير وسر A — سيُختبر مساره الطبيعي في QA-MM-02.
    await insertDevice(o, aId, aSecret, userId: 1);
    await insertDevice(o, bId, bSecret, ip: '127.0.0.1', port: portB, userId: 1);
    await insertDevice(a, oId, oSecret, owner: true, userId: 1);
    await insertDevice(a, bId, bSecret, ip: '127.0.0.1', port: portB, userId: 1);
    await insertDevice(b, oId, oSecret, owner: true, userId: 1);
    await insertDevice(b, aId, aSecret, userId: 1);

    lanA = LanSyncService(repo: repoA, dbProvider: () async => a, ourDeviceId: aId);
    serverB = LanSyncService(
        repo: repoB, dbProvider: () async => b, ourDeviceId: bId, port: portB);
    await serverB!.startServer();
  });

  tearDown(() async {
    await serverO?.stopServer();
    await serverB?.stopServer();
    serverO = null;
    serverB = null;
    await o.close();
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  Future<SyncOperation> lastOp(Database db, String type, String id) async {
    final rows = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?', whereArgs: [type, id]);
    return SyncOperation.fromMap(rows.last);
  }

  test('QA-MM-01 member A syncs to member B while the owner is offline',
      () async {
    // المدير غير متصل إطلاقاً (لا خادم له). العضو A ينشئ حساباً ويدفعه.
    final accId = await repoA.saveAccount(Account(
        name: 'عضو↔عضو',
        kind: AccountKind.customer,
        createdAt: now,
        updatedAt: now));
    final op = await lastOp(a, 'account', '$accId');
    await lanA.push(op);
    expect((await repoB.accounts()).single.name, 'عضو↔عضو');
  });

  test('QA-MM-02 roster from owner distributes peer secrets to members',
      () async {
    // العضو B لا يعرف سر A بعد.
    await b.update('devices', {'auth_secret': ''},
        where: 'id = ?', whereArgs: [aId]);
    // شغّل خادم المدير وحدّث سجل المدير لدى B بعنوانه.
    serverO = LanSyncService(
        repo: repoO, dbProvider: () async => o, ourDeviceId: oId, port: portO);
    await serverO!.startServer();
    await b.update('devices', {'ip_address': '127.0.0.1', 'port': portO},
        where: 'id = ?', whereArgs: [oId]);
    final lanB = LanSyncService(
        repo: repoB, dbProvider: () async => b, ourDeviceId: bId, port: portB);
    await lanB.reconcileRoster();
    final row = await b.query('devices',
        columns: ['auth_secret'], where: 'id = ?', whereArgs: [aId], limit: 1);
    expect(row.single['auth_secret'], aSecret,
        reason: 'roster المدير يجب أن يوزّع سر A حتى يقبل B عملياته لاحقاً');
    // والآن يستطيع A الدفع إلى B مباشرة بغياب المدير.
    await serverO!.stopServer();
    serverO = null;
    final accId = await repoA.saveAccount(Account(
        name: 'بعد التوزيع',
        kind: AccountKind.customer,
        createdAt: now,
        updatedAt: now));
    await lanA.push(await lastOp(a, 'account', '$accId'));
    expect((await repoB.accounts()).single.name, 'بعد التوزيع');
  });

  test('QA-MM-03 roster never overwrites our own secret or distributes '
      'revoked-device secrets', () async {
    serverO = LanSyncService(
        repo: repoO, dbProvider: () async => o, ourDeviceId: oId, port: portO);
    await serverO!.startServer();
    await b.update('devices', {'ip_address': '127.0.0.1', 'port': portO},
        where: 'id = ?', whereArgs: [oId]);
    // على المدير: سجلّ B بسر مختلف (يجب ألا يُكتب فوق سر B المحلي)،
    // وجهاز موقوف سرّه يجب أن يصل فارغاً.
    await o.update('devices', {'auth_secret': 'stale-b-secret'},
        where: 'id = ?', whereArgs: [bId]);
    await insertDevice(o, 'DEVICE-QAREVOKD', 'revoked-secret');
    await o.update('devices', {'revoked_at': now.toIso8601String()},
        where: 'id = ?', whereArgs: ['DEVICE-QAREVOKD']);
    final lanB = LanSyncService(
        repo: repoB, dbProvider: () async => b, ourDeviceId: bId, port: portB);
    await lanB.reconcileRoster();
    final self = await b.query('devices',
        columns: ['auth_secret'], where: 'id = ?', whereArgs: [bId], limit: 1);
    expect(self.single['auth_secret'], bSecret);
    final revoked = await b.query('devices',
        columns: ['auth_secret'],
        where: 'id = ?',
        whereArgs: ['DEVICE-QAREVOKD'],
        limit: 1);
    if (revoked.isNotEmpty) {
      expect(revoked.single['auth_secret'], isNot('revoked-secret'));
    }
  });

  test('QA-MM-04 remote delete mirrors into trash and restore clears it',
      () async {
    // A ينشئ حساباً ويزامنه إلى B.
    final accId = await repoA.saveAccount(Account(
        name: 'سيُحذف',
        kind: AccountKind.customer,
        createdAt: now,
        updatedAt: now));
    await lanA.push(await lastOp(a, 'account', '$accId'));
    expect(await repoB.accounts(), hasLength(1));
    // A يحذفه — لدى B يجب أن يظهر صف في سلة المهملات.
    await repoA.deleteAccount(accId);
    final delOps = await a.query('operations',
        where: "entity_type = 'account' AND entity_id = ? AND op_type = ?",
        whereArgs: ['$accId', 'delete_']);
    await lanA.push(SyncOperation.fromMap(delOps.last));
    expect(await repoB.accounts(), isEmpty);
    final trashB = await b.query('trash');
    expect(trashB, hasLength(1),
        reason: 'الحذف الوارد يجب أن ينعكس في سلة مهملات B');
    expect('${trashB.single['label']}', contains('سيُحذف'));
    // A يسترجعه من سلته — سلة B يجب أن تُفرَّغ والحساب يعود.
    final trashA = await a.query('trash');
    await repoA.restoreFromTrash(trashA.single['id'] as int);
    final restoreOps = await a.query('operations',
        where: "entity_type = 'account' AND entity_id = ? AND op_type = ?",
        whereArgs: ['$accId', 'restore']);
    await lanA.push(SyncOperation.fromMap(restoreOps.last));
    expect(await repoB.accounts(), hasLength(1));
    expect(await b.query('trash'), isEmpty,
        reason: 'الاسترجاع الوارد يجب أن يزيل صف السلة المقابل لدى B');
  });

  test('QA-MM-05 backups carry the group fingerprint and foreign imports fail',
      () async {
    // مجموعة A: بصمتها = جهاز المدير oId.
    await a.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final backup = await repoA.exportAll();
    expect(backup['group_fingerprint'], oId);
    // مجموعة B "أخرى": نجعل مالكها جهازاً مختلفاً ثم نحاول الاستيراد.
    await b.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await b.update('devices', {'is_owner': 0}, where: 'id = ?', whereArgs: [oId]);
    await b.update('devices', {'is_owner': 1}, where: 'id = ?', whereArgs: [bId]);
    await expectLater(
      repoB.importAll(backup),
      throwsA(isA<BackupImportException>()),
      reason: 'نسخة من مجموعة أخرى يجب أن تُرفض',
    );
    // النسخة الصادرة من المجموعة نفسها تُقبل.
    final ownBackup = await repoB.exportAll();
    expect(await repoB.importAll(ownBackup), greaterThan(0));
  });

  test('QA-MM-06 a member device cannot pair outside its group', () async {
    await a.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final result =
        await lanA.pairWith('127.0.0.1', portB, 'ANYTOKEN', ourPort: 43055);
    expect(result.ok, isFalse);
    expect('${result.error}', contains('عضو'));
  });

  test('QA-MM-07 local backup export works without export permission',
      () async {
    // مستخدم بلا أي صلاحيات.
    await a.update('users', {'role': 'viewer', 'permissions': ''},
        where: 'id = 1');
    await a.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final payload = await repoA.exportForLocalBackup();
    expect(payload['app'], 'nexora');
    // بينما التصدير العادي (الذي يغادر الجهاز) يُرفض.
    await expectLater(repoA.exportAll(), throwsA(isA<StateError>()));
  });
}
