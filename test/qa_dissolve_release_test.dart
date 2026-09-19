// QA — (2026-09-19 — لا أعضاء عالقون) حل المجموعة وتحرير الأعضاء فعلياً:
// - كاشف موت المجموعة ثلاثي القواعد: (أ) roster زال/فرغ، (ب) العضو وحده
//   بلا مدير، (ج) قيد العضو مُزيل بلا سجل طرد.
// - حل المجموعة من المدير يحذف كل الأقسام عدا الاشتراك + يكنس invite_index.
// - تحرير العضو يمسح بقاياه السحابية (roster/joinRequests/members/
//   device_index/accounts_index).
// - التحويل إلى فردي يحفظ بيانات العضو المحلية كاملة.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/device_registry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';

/// سحابة وهمية: تخزّن أي PUT حسب المسار وتعيد GET من نفس المخزن.
class FakeCloudStore {
  final Map<String, Object?> store = {};

  static http.Response _utf8Json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST') {
          if (req.url.host.contains('securetoken')) {
            return _utf8Json('{"id_token":"TOK-QA","refresh_token":"REF-QA",'
                '"expires_in":"3600","user_id":"UID-QA-ANON"}', 200);
          }
          return _utf8Json('{"idToken":"TOK-QA","refreshToken":"REF-QA",'
              '"expiresIn":"3600","localId":"UID-QA-ANON"}', 200);
        }
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _utf8Json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          return _utf8Json('null', 200);
        }
        final v = store[key];
        if (v != null) return _utf8Json(jsonEncode(v), 200);
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child = e.key
                .substring(prefix.length + 1)
                .replaceAll('.json', '');
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
  late Database a;
  late Repo repoA;
  const url = 'https://qa-dissolve.firebaseio.com';
  const ws = 'WS-QADIS';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_dis_');
    a = await databaseFactory.openDatabase('${tmp.path}/a.db',
        options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(a);
    repoA = Repo(databaseProvider: () async => a);
    await repoA.initSyncInfra();
    await repoA.setSetting('cloudBackendUrl', url);
  });
  tearDown(() async {
    await a.close();
    await tmp.delete(recursive: true);
  });

  group('كاشف موت المجموعة — ثلاث قواعد', () {
    test('QA-DIS-01 (أ) roster محذوفة تماماً → مجموعة ميتة', () async {
      final cloud = FakeCloudStore();
      final gone = await http.runWithClient(
          () => CloudJoin.groupNodeGone(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);
      expect(gone, isTrue);
    });

    test('QA-DIS-02 (أ) roster فارغة → مجموعة ميتة', () async {
      final cloud = FakeCloudStore();
      cloud.store['/workspaces/$ws/roster.json'] = <String, Object?>{};
      final gone = await http.runWithClient(
          () => CloudJoin.groupNodeGone(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);
      expect(gone, isTrue);
    });

    test('QA-DIS-03 (ب) العضو وحده في roster بلا مدير → مجموعة ميتة '
        '(كارثة البقايا الحية NY6PU4HA)', () async {
      final ourId = await ensureDeviceId(repoA);
      final cloud = FakeCloudStore();
      cloud.store['/workspaces/$ws/roster.json'] = {ourId: true};
      // عقد أخرى ما زالت قائمة (backup/subscription) — لا تمنع الحكم.
      cloud.store['/workspaces/$ws/backup.json'] = {'v': 1};
      final gone = await http.runWithClient(
          () => CloudJoin.groupNodeGone(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);
      expect(gone, isTrue);
    });

    test('QA-DIS-04 (ج) قيد العضو مُزيل بلا سجل طرد → ارتباطه أُلغي',
        () async {
      final ourId = await ensureDeviceId(repoA);
      final cloud = FakeCloudStore();
      cloud.store['/workspaces/$ws/roster.json'] = {'DEVICE-MGR-1': true};
      final gone = await http.runWithClient(
          () => CloudJoin.groupNodeGone(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);
      expect(gone, isTrue, reason: 'قيدنا غائب ولا يوجد سجل طرد');
      // مع سجل طرد: مسار الطرد هو المعني — الكاشف يسكت.
      cloud.store['/workspaces/$ws/evictions/$ourId.json'] = {'at': 'x'};
      final gone2 = await http.runWithClient(
          () => CloudJoin.groupNodeGone(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);
      expect(gone2, isFalse);
      expect(ourId, isNotEmpty);
    });

    test('QA-DIS-05 مجموعة سليمة (مدير + عضو) → لا حكم بالموت', () async {
      final ourId = await ensureDeviceId(repoA);
      final cloud = FakeCloudStore();
      cloud.store['/workspaces/$ws/roster.json'] = {
        'DEVICE-MGR-1': true,
        ourId: true,
      };
      final gone = await http.runWithClient(
          () => CloudJoin.groupNodeGone(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);
      expect(gone, isFalse);
    });
  });

  group('حل المجموعة من المدير — إلغاء كل الارتباطات', () {
    test('QA-DIS-06 الحل يحذف كل الأقسام عدا الاشتراك ويكنس invite_index',
        () async {
      await ensureDeviceId(repoA);
      final cloud = FakeCloudStore();
      const root = '/workspaces/$ws';
      cloud.store['$root/roster.json'] = {'DEVICE-MGR': true, 'MEM-1': true};
      cloud.store['$root/operations.json'] = {'op1': 1};
      cloud.store['$root/invites.json'] = {
        'TOK-AAA': {'pin': '123456', 'exp': 'x'},
      };
      cloud.store['$root/joinRequests.json'] = {'MEM-1': {'t': 1}};
      cloud.store['$root/joinSnapshot.json'] = {'s': 1};
      cloud.store['$root/members.json'] = {'uid1': {'role': 'member'}};
      cloud.store['$root/evictions.json'] = {'old': 1};
      cloud.store['$root/chat.json'] = {'m': 1};
      cloud.store['$root/notifications.json'] = {'n': 1};
      cloud.store['$root/devices.json'] = {'d': 1};
      cloud.store['$root/backup.json'] = {'b': 1};
      cloud.store['$root/creator.json'] = {'c': 1};
      cloud.store['$root/subscription.json'] = {'plan': 'pro'};
      cloud.store['/invite_index/pin_123456.json'] = ws;
      cloud.store['/invite_index/tok_TOK-AAA.json'] = ws;

      await http.runWithClient(
          () => CloudJoin.dissolveGroup(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);

      for (final node in [
        'roster', 'operations', 'invites', 'joinRequests', 'joinSnapshot',
        'members', 'evictions', 'chat', 'notifications', 'devices', 'backup',
        'creator',
      ]) {
        expect(cloud.store.containsKey('$root/$node.json'), isFalse,
            reason: '$node يجب أن يُحذف عند الحل');
      }
      expect(cloud.store['$root/subscription.json'], isNotNull,
          reason: 'الاشتراك المدفوع لا يُمس');
      expect(cloud.store.containsKey('/invite_index/pin_123456.json'), isFalse,
          reason: 'بصمة PIN القديمة تُكنس من الفهرس العام');
      expect(cloud.store.containsKey('/invite_index/tok_TOK-AAA.json'), isFalse,
          reason: 'بصمة التوكن تُكنس من الفهرس العام');
    });
  });

  group('تحرير العضو — مسح البقايا', () {
    test('QA-DIS-07 releaseMemberBindings يمسح قيد العضو وطلبه وعضويته '
        'وفهرسيه ولا يمس بيانات المجموعة', () async {
      final ourId = await ensureDeviceId(repoA);
      // هوية مجهولة من المحاكي → UID-QA-ANON (نفس معرّف الاختبارات الأخرى).
      final cloud = FakeCloudStore();
      const root = '/workspaces/$ws';
      cloud.store['$root/roster/$ourId.json'] = true;
      cloud.store['$root/roster/DEVICE-MGR.json'] = true;
      cloud.store['$root/joinRequests/$ourId.json'] = {'kind': 'leave'};
      cloud.store['$root/members/UID-QA-ANON.json'] = {'role': 'member'};
      cloud.store['$root/operations.json'] = {'op1': 1};
      cloud.store['/accounts_index/UID-QA-ANON.json'] = ws;
      cloud.store['/workspaces/_registry/accounts_index/UID-QA-ANON.json'] = {
        'workspaceId': ws,
      };
      final fp = await DeviceRegistry.fingerprintKey(repoA);
      if (fp.isNotEmpty) {
        cloud.store['/device_index/$fp.json'] = ws;
      }

      await http.runWithClient(
          () => CloudJoin.releaseMemberBindings(repoA,
              backendUrl: url, workspaceId: ws),
          cloud.client);

      expect(cloud.store.containsKey('$root/roster/$ourId.json'), isFalse);
      expect(cloud.store.containsKey('$root/joinRequests/$ourId.json'), isFalse);
      expect(cloud.store.containsKey('$root/members/UID-QA-ANON.json'), isFalse);
      expect(cloud.store.containsKey('/accounts_index/UID-QA-ANON.json'),
          isFalse, reason: 'فهرس Google يُنسى فلا سحب رجوعاً');
      expect(
          cloud.store.containsKey(
              '/workspaces/_registry/accounts_index/UID-QA-ANON.json'),
          isFalse,
          reason: 'الفهرس الرسمي تحت _registry يُحذف أيضاً (إصلاح الاختطاف)');
      if (fp.isNotEmpty) {
        expect(cloud.store.containsKey('/device_index/$fp.json'), isFalse);
      }
      // بيانات المجموعة نفسها لا تُمس في مسار التحرير.
      expect(cloud.store['$root/roster/DEVICE-MGR.json'], isNotNull);
      expect(cloud.store['$root/operations.json'], isNotNull);
    });
  });

  group('الحذف الكامل من السحابة — تصفير العضو', () {
    test('QA-DIS-09 purgeDeviceEverywhere للعضو: عملياته تُصفَّر من '
        'المجموعة ومساحته الشخصية القديمة تُدمَّر وقيوده تُحذف — وبيانات '
        'المجموعة نفسها لا تُمس', () async {
      final ourId = await ensureDeviceId(repoA);
      final db = await repoA.database;
      await db.insert(
          'sync_meta', {'key': 'workspaceMode', 'value': 'member'});
      final grp = repoA.requireWorkspaceId;
      final cloud = FakeCloudStore();
      final root = '/workspaces/$grp';
      // المجموعة: مدير + عضو، وعمليات لكل منهما.
      cloud.store['$root/roster/$ourId.json'] = true;
      cloud.store['$root/roster/DEVICE-MGR.json'] = true;
      cloud.store['$root/joinRequests/$ourId.json'] = {'kind': 'leave'};
      cloud.store['$root/members/UID-QA-ANON.json'] = {'role': 'member'};
      cloud.store['$root/operations/op-mine.json'] = {
        'device_id': ourId,
        'entity': 'account',
      };
      cloud.store['$root/operations/op-mgr.json'] = {
        'device_id': 'DEVICE-MGR',
        'entity': 'account',
      };
      // الفهرس الرسمي يشير إلى مساحة شخصية قديمة كامنة.
      cloud.store['/workspaces/_registry/accounts_index/UID-QA-ANON.json'] = {
        'workspaceId': 'WS-PERSONAL-OLD',
      };
      cloud.store['/workspaces/WS-PERSONAL-OLD/backup.json'] = {'b': 1};
      cloud.store['/workspaces/WS-PERSONAL-OLD/operations.json'] = {'o': 1};
      cloud.store['/workspaces/WS-PERSONAL-OLD/roster.json'] = {'r': 1};
      cloud.store['/workspaces/WS-PERSONAL-OLD/subscription.json'] = {
        'plan': 'pro',
      };
      final fp = await DeviceRegistry.fingerprintKey(repoA);
      if (fp.isNotEmpty) {
        cloud.store['/device_index/$fp.json'] = {
          'workspaceId': grp,
          'role': 'member',
          'device_id': ourId,
        };
      }

      await http.runWithClient(
          () => CloudJoin.purgeDeviceEverywhere(repoA, backendUrl: url),
          cloud.client);

      // عملياته هو صُفّرت — عمليات الآخرين بقيت.
      expect(cloud.store.containsKey('$root/operations/op-mine.json'), isFalse,
          reason: 'عمليات العضو نفسه تُحذف من المجموعة');
      expect(cloud.store['$root/operations/op-mgr.json'], isNotNull,
          reason: 'بيانات المجموعة نفسها لا تُمس');
      expect(cloud.store['$root/roster/DEVICE-MGR.json'], isNotNull);
      // قيوده كلها حُذفت.
      expect(cloud.store.containsKey('$root/roster/$ourId.json'), isFalse);
      expect(cloud.store.containsKey('$root/joinRequests/$ourId.json'), isFalse);
      expect(cloud.store.containsKey('$root/members/UID-QA-ANON.json'), isFalse);
      // مساحته الشخصية القديمة دُمّرت عدا اشتراكها المدفوع.
      expect(cloud.store.containsKey('/workspaces/WS-PERSONAL-OLD/backup.json'),
          isFalse);
      expect(
          cloud.store
              .containsKey('/workspaces/WS-PERSONAL-OLD/operations.json'),
          isFalse);
      expect(
          cloud.store.containsKey('/workspaces/WS-PERSONAL-OLD/roster.json'),
          isFalse);
      expect(cloud.store['/workspaces/WS-PERSONAL-OLD/subscription.json'],
          isNotNull, reason: 'الاشتراك المدفوع يبقى');
      // الفهرسان العامّان نُسيا.
      expect(
          cloud.store.containsKey(
              '/workspaces/_registry/accounts_index/UID-QA-ANON.json'),
          isFalse);
      if (fp.isNotEmpty) {
        expect(cloud.store.containsKey('/device_index/$fp.json'), isFalse);
      }
      expect(await repoA.workspaceMode(), 'member',
          reason: 'الحذف السحابي لا يغير الوضع المحلي — المسح المحلي '
              'مسار منفصل في الواجهة');
    });
  });

  group('التحويل إلى حساب فردي', () {
    test('QA-DIS-08 becomeIndividualAfterDissolution: فردي + مالك + '
        'البيانات المحلية محفوظة', () async {
      final db = await repoA.database;
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'});
      await repoA.setSetting('probe.data', 'KEEP-ME');
      expect(await repoA.workspaceMode(), 'member');

      await repoA.becomeIndividualAfterDissolution();

      expect(await repoA.workspaceMode(), 'standalone');
      final st = await repoA.settings();
      expect(st['account.type'], 'individual');
      expect(st['probe.data'], 'KEEP-ME',
          reason: 'بيانات العضو المحلية تبقى له بعد التحرر');
      final dev = await db.query('devices', where: 'COALESCE(is_owner,0) = 1');
      expect(dev, isNotEmpty, reason: 'جهازه يصير مالكاً لحسابه الفردي');
    });
  });
}
