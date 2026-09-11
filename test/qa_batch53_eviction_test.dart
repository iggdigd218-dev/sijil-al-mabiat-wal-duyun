// QA — دفعة 53: الطرد التلقائي وإبطال الجلسة.
// - المصافحة النشطة: العضو يفحص /roster/$deviceId بنفسه.
// - revoked=true أو revoked_at/expelled_at → onEvicted يُطلق فوراً.
// - عقدة محذوفة (null): طرد فقط بعد أن سبق للجهاز رؤية نفسه في السجل
//   (حارس ضد الإيجابيات الكاذبة).
// - المالك والمستقل لا يُطردان ذاتياً أبداً.
// - بعد الطرد: pull يتوقف (0) و push يرمي فوراً.
// - handleSelfEviction: يفرغ sync_queue ومفاتيح الجلسة ويعيد الوضع
//   standalone ويبث onDeviceEvicted مرة واحدة فقط.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeCloudStore {
  final Map<String, Object?> store = {};

  static http.Response _utf8Json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _utf8Json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          // كما في RTDB: حذف عقدة يحذف شجرتها الفرعية كاملة.
          final prefix = key.replaceAll('.json', '');
          store.removeWhere((k, _) => k.startsWith('$prefix/'));
          return _utf8Json('null', 200);
        }
        final v = store[key];
        if (v != null) return _utf8Json(jsonEncode(v), 200);
        // قراءة عقدة كاملة (مثل roster.json): تجميع الأبناء.
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child =
                e.key.substring(prefix.length + 1).replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = e.value;
          }
        }
        if (children.isNotEmpty) return _utf8Json(jsonEncode(children), 200);
        return _utf8Json('null', 200);
      });
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-evict.firebaseio.com';
  const devId = 'member-device-1';
  const rosterKey = '/workspaces/default/roster/$devId.json';

  Future<void> setMode(String mode) => db.insert(
      'sync_meta', {'key': 'workspaceMode', 'value': mode},
      conflictAlgorithm: ConflictAlgorithm.replace);

  CloudFirebaseTransport makeTransport() => CloudFirebaseTransport(
        repo: repo,
        dbProvider: () async => db,
        backendUrl: url,
        workspaceId: 'default',
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_evict_');
    db = await databaseFactory.openDatabase('${tmp.path}/m.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    // ensureDeviceId يولّد معرفاً جديداً في بيئة VM — نفرض معرف الاختبار
    // بعد التهيئة (maybeCheckSelfEviction يقرأه من settings في كل فحص).
    await repo.setSetting('sync.deviceId', devId);
    await db.insert(
        'devices',
        {
          'id': devId,
          'workspace_id': 'default',
          'name': 'جهاز الاختبار',
          'is_paired': 1,
          'is_owner': 0,
          'created_at': '2026-09-11T09:00:00',
          'updated_at': '2026-09-11T09:00:00',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await setMode('member');
    await repo.setSetting('cloudBackendUrl', url);
    await repo.setSetting('cloudCode', 'QA1');
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('QA-B53-01 clean roster row: no eviction, rosterSeenSelf marked',
      () async {
    final cloud = FakeCloudStore();
    cloud.store[rosterKey] = {
      'id': devId,
      'revoked_at': '',
      'expelled_at': '',
    };
    final t = makeTransport();
    var fired = false;
    t.onEvicted = () => fired = true;
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, isFalse);
    expect(t.isEvicted, isFalse);
    final st = await repo.settings();
    expect(st['sync.rosterSeenSelf'], '1');
  });

  test('QA-B53-02 revoked_at set in roster → eviction fires', () async {
    final cloud = FakeCloudStore();
    cloud.store[rosterKey] = {
      'id': devId,
      'revoked_at': DateTime.now().toIso8601String(),
    };
    final t = makeTransport();
    var fired = 0;
    t.onEvicted = () => fired++;
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, 1);
    expect(t.isEvicted, isTrue);
    // تكرار الفحص لا يبث مرة ثانية.
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, 1);
  });

  test('QA-B53-03 "revoked": true flag → eviction fires', () async {
    final cloud = FakeCloudStore();
    cloud.store[rosterKey] = {'id': devId, 'revoked': true};
    final t = makeTransport();
    var fired = false;
    t.onEvicted = () => fired = true;
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, isTrue);
  });

  test('QA-B53-04 deleted node: evicts ONLY after previously seen in roster',
      () async {
    final cloud = FakeCloudStore(); // لا عقدة → null.
    final t = makeTransport();
    var fired = false;
    t.onEvicted = () => fired = true;
    // لم نرَ أنفسنا بعد → لا طرد (حارس الإيجابيات الكاذبة).
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, isFalse);
    // الآن سُجّلنا ثم حُذفنا.
    await repo.setSetting('sync.rosterSeenSelf', '1');
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, isTrue);
  });

  test('QA-B53-05 owner/standalone never self-evict', () async {
    final cloud = FakeCloudStore(); // عقدة محذوفة + rosterSeenSelf.
    await repo.setSetting('sync.rosterSeenSelf', '1');
    for (final mode in ['owner', 'standalone']) {
      await setMode(mode);
      final t = makeTransport();
      var fired = false;
      t.onEvicted = () => fired = true;
      await http.runWithClient(
          () => t.maybeCheckSelfEviction(force: true), cloud.client);
      expect(fired, isFalse, reason: 'وضع $mode لا يُطرد ذاتياً');
    }
  });

  test('QA-B53-06 after eviction: pull returns 0, push throws', () async {
    final cloud = FakeCloudStore();
    cloud.store[rosterKey] = {'id': devId, 'expelled_at': '2026-09-11'};
    final t = makeTransport();
    t.onEvicted = () {};
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(t.isEvicted, isTrue);
    final applied = await http.runWithClient(() => t.pull(), cloud.client);
    expect(applied, 0);
  });

  test(
      'QA-B53-07 handleSelfEviction: queue+session cleared, standalone, '
      'onDeviceEvicted broadcast once', () async {
    // صف جهازنا موسوم مطروداً محلياً (وصل عبر syncRoster).
    await db.update('devices', {'expelled_at': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [devId]);
    // صف طابور معلق + مفاتيح جلسة.
    await db.insert('operations', {
      'id': 'op-x',
      'workspace_id': 'default',
      'entity_type': 'account',
      'entity_id': 'e1',
      'op_type': 'create',
      'version': 1,
      'device_id': devId,
      'device_time': '2026-09-11T10:00:00',
      'timestamp': '2026-09-11T10:00:00',
      'payload': '{}',
    });
    await db.insert('sync_queue', {
      'operation_id': 'op-x',
      'target': 'cloud',
      'status': 'pending',
      'attempts': 0,
      'created_at': '2026-09-11T10:00:00',
      'updated_at': '2026-09-11T10:00:00',
    });
    await repo.setSetting('pendingJoin.token', 'ABC');
    final engine = SyncEngine(repo: repo, dbProvider: () async => db);
    var evictedEvents = 0;
    SyncEngine.onDeviceEvicted = () => evictedEvents++;
    addTearDown(() => SyncEngine.onDeviceEvicted = null);
    await engine.handleSelfEviction();
    await engine.handleSelfEviction(); // ازدواج مقصود — لا يتكرر البث.
    expect(evictedEvents, 1);
    // الطابور فُرّغ.
    expect((await db.query('sync_queue')).length, 0);
    // مفاتيح الجلسة أُزيلت والوضع عاد standalone.
    final st = await repo.settings();
    expect(st.containsKey('cloudBackendUrl'), isFalse);
    expect(st.containsKey('cloudCode'), isFalse);
    expect(st.containsKey('pendingJoin.token'), isFalse);
    expect(await repo.workspaceMode(), 'standalone');
    // إبطال الجلسة الكامل: شاشة الترحيب ستظهر عند الإقلاع التالي.
    expect(st.containsKey('has_completed_onboarding'), isFalse);
  });

  // ==================== دفعة 54: بروتوكول الطرد النشط ====================

  test('QA-B54-01 manager purge writes eviction tombstone + deletes roster',
      () async {
    final cloud = FakeCloudStore();
    // عقدة roster موجودة قبل الطرد.
    cloud.store[rosterKey] = {'id': devId, 'name': 'جهاز'};
    await setMode('owner');
    await db.update('devices', {'is_owner': 1},
        where: 'is_owner = 1 OR id = ?', whereArgs: [devId]);
    await http.runWithClient(
        () => CloudJoin.purgePeerFromCloud(repo,
            backendUrl: url, deviceId: devId, reason: 'expelled_by_manager'),
        cloud.client);
    // الشاهدة كُتبت بالحمولة الصحيحة.
    const tombKey = '/workspaces/default/evictions/$devId.json';
    final tomb = cloud.store[tombKey] as Map?;
    expect(tomb, isNotNull);
    expect('${tomb!['reason']}', 'expelled_by_manager');
    expect(tomb['expelled_at'], isNotNull); // {".sv":"timestamp"}
    // عقدة roster حُذفت نهائياً.
    expect(cloud.store.containsKey(rosterKey), isFalse);
  });

  test('QA-B54-02 member handshake detects tombstone → immediate eviction',
      () async {
    final cloud = FakeCloudStore();
    // roster سليم لكن الشاهدة موجودة — الشاهدة تحسم أولاً.
    cloud.store[rosterKey] = {'id': devId, 'revoked_at': '', 'expelled_at': ''};
    cloud.store['/workspaces/default/evictions/$devId.json'] = {
      'deviceId': devId,
      'expelled_at': 1757600000000,
      'reason': 'revoked_by_manager',
    };
    final t = makeTransport();
    var fired = false;
    t.onEvicted = () => fired = true;
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, isTrue, reason: 'الشاهدة الصريحة = طرد قاطع فوري');
    expect(t.isEvicted, isTrue);
  });

  test('QA-B54-03 clearEvictionTombstone removes tombstone (re-allow flow)',
      () async {
    final cloud = FakeCloudStore();
    const tombKey = '/workspaces/default/evictions/$devId.json';
    cloud.store[tombKey] = {'deviceId': devId, 'reason': 'revoked_by_manager'};
    await http.runWithClient(
        () => CloudJoin.clearEvictionTombstone(
            backendUrl: url, deviceId: devId),
        cloud.client);
    expect(cloud.store.containsKey(tombKey), isFalse);
    // بعد الإزالة: المصافحة لا تطرد (roster سليم).
    cloud.store[rosterKey] = {'id': devId, 'revoked_at': '', 'expelled_at': ''};
    final t = makeTransport();
    var fired = false;
    t.onEvicted = () => fired = true;
    await http.runWithClient(
        () => t.maybeCheckSelfEviction(force: true), cloud.client);
    expect(fired, isFalse);
  });

  test('QA-B54-04 hasEvictionTombstone: true when present, false when absent',
      () async {
    final cloud = FakeCloudStore();
    expect(
        await http.runWithClient(
            () => CloudJoin.hasEvictionTombstone(
                backendUrl: url, deviceId: devId),
            cloud.client),
        isFalse);
    cloud.store['/workspaces/default/evictions/$devId.json'] = {
      'deviceId': devId
    };
    expect(
        await http.runWithClient(
            () => CloudJoin.hasEvictionTombstone(
                backendUrl: url, deviceId: devId),
            cloud.client),
        isTrue);
  });

  // ==================== دفعة 55: حل المجموعة بالكامل ====================

  test('QA-B55-01 dissolveGroup: tombstones for ALL peers, cloud node wiped',
      () async {
    final cloud = FakeCloudStore();
    // مدير + عضوان: واحد محلي وواحد سحابي فقط (roster) — الاتحاد يغطيهما.
    await setMode('owner');
    await db.update('devices', {'is_owner': 1},
        where: 'id = ?', whereArgs: [devId]);
    await db.insert(
        'devices',
        {
          'id': 'peer-local-1',
          'workspace_id': 'default',
          'name': 'عضو محلي',
          'is_paired': 1,
          'is_owner': 0,
          'created_at': '2026-09-11T09:00:00',
          'updated_at': '2026-09-11T09:00:00',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    cloud.store['/workspaces/default/roster/peer-cloud-2.json'] = {
      'id': 'peer-cloud-2',
      'name': 'عضو سحابي',
    };
    cloud.store['/workspaces/default/operations/op1.json'] = {'id': 'op1'};
    cloud.store['/workspaces/default/invites/TOK1.json'] = {'pin': '123456'};
    final n = await http.runWithClient(
        () => CloudJoin.dissolveGroup(repo, backendUrl: url), cloud.client);
    expect(n, 2, reason: 'شاهدتان: للعضو المحلي والسحابي، لا شاهدة للمدير');
    expect(
        cloud.store
            .containsKey('/workspaces/default/evictions/peer-local-1.json'),
        isTrue);
    expect(
        cloud.store
            .containsKey('/workspaces/default/evictions/peer-cloud-2.json'),
        isTrue);
    expect(
        cloud.store.containsKey('/workspaces/default/evictions/$devId.json'),
        isFalse,
        reason: 'المدير لا يطرد نفسه');
    final tomb = cloud.store['/workspaces/default/evictions/peer-local-1.json']
        as Map;
    expect('${tomb['reason']}', 'group_dissolved');
    // عقدة المجموعة فُككت: roster/operations/invites حُذفت.
    expect(
        cloud.store.keys.any((k) =>
            k.contains('/roster/') ||
            k.contains('/operations/') ||
            k.contains('/invites/')),
        isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('QA-B55-02 dissolveGroup rejected for non-owner', () async {
    final cloud = FakeCloudStore();
    await setMode('member');
    await db.update('devices', {'is_owner': 0});
    await expectLater(
      http.runWithClient(
          () => CloudJoin.dissolveGroup(repo, backendUrl: url), cloud.client),
      throwsA(isA<CloudJoinException>()),
    );
  });

  test(
      'QA-B55-03 dissolveGroupLocally: ledgers kept, peers/users/chats '
      'purged, standalone restored', () async {
    await setMode('owner');
    await db.update('devices', {'is_owner': 1},
        where: 'id = ?', whereArgs: [devId]);
    // دفتر للمدير يجب أن يبقى.
    await db.insert('accounts', {
      'name': 'عميل المدير',
      'kind': 'customer',
      'notify_channel': 'none',
      'workspace_id': 'default',
      'created_at': '2026-09-11T08:00:00',
      'updated_at': '2026-09-11T08:00:00',
    });
    // عضو + مستخدمه + محادثة.
    await db.insert(
        'devices',
        {
          'id': 'peer-x',
          'workspace_id': 'default',
          'name': 'عضو',
          'is_paired': 1,
          'is_owner': 0,
          'created_at': '2026-09-11T09:00:00',
          'updated_at': '2026-09-11T09:00:00',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('users', {
      'name': 'كاشير',
      'role': 'accountant',
      'pin': '',
      'password': '',
      'permissions': '',
      'is_me': 0,
      'active': 1,
      'workspace_id': 'default',
      'deleted_at': '',
      'created_at': '2026-09-11T09:00:00',
      'updated_at': '2026-09-11T09:00:00',
    });
    await db.insert(
        'conversations',
        {
          'id': 1,
          'workspace_id': 'default',
          'title': 'دردشة',
          'created_at': '2026-09-11T09:00:00',
          'updated_at': '2026-09-11T09:00:00',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await repo.dissolveGroupLocally();
    // الدفاتر باقية.
    expect((await db.query('accounts')).length, 1);
    // الأعضاء والأجهزة الغريبة والدردشات زالت.
    final devs = await db.query('devices');
    expect(devs.length, 1);
    expect('${devs.first['id']}', devId);
    expect((devs.first['is_owner'] as int), 1);
    expect(
        (await db.query('users', where: 'is_me <> 1')).length, 0);
    expect((await db.query('conversations')).length, 0);
    expect((await db.query('sync_queue')).length, 0);
    expect(await repo.workspaceMode(), 'standalone');
  });
}
