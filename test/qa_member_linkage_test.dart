// QA — ثابت «ربط العضو بالمجموعة» على مستوى هوية المصادقة (auth.uid).
//
// لماذا حزمة مستقلة عن qa_batch51_approval_test:
//   دفعة 51 تفحص الربط الظاهر (roster، users، devices، تنظيف الطلب) ولا
//   تلمس عقدة `/members/{uid}` إطلاقاً — مع أن تعليقات cloud_join.dart
//   نفسها تعدّها «مرجع قواعد الأمان للسماح لهذا الجهاز بالكتابة في المساحة».
//
// العلّة التي تحرسها هذه الحزمة:
//   ١) `requestJoin` يسجّل في الطلب `uid` الجهاز الجاري.
//   ٢) `approveJoinRequest` يكتب `/members/{ذلك الـuid}` بالدور المعيّن.
//   ٣) `completeApprovedJoin` → `join()` **يدوّر الهوية** قصداً (دفعة 65)
//      كي لا يرث العضو بصمة مساحته الشخصية، فيصدر Firebase uid جديداً.
//   النتيجة قبل الإصلاح: `/members/{uid_قديم}` يتيمة لا يصادق بها أحد،
//   والجهاز يصادق بـ uid جديد **بلا عضوية**، بينما `/roster/{deviceId}`
//   يُرفع بالهوية الجديدة — سجلّان سحابيان متناقضان عن العضو نفسه.
//   والأثر يصير حرماناً كاملاً من المزامنة لحظة تشديد قواعد RTDB من
//   `auth != null` إلى مرجعية `/members/{auth.uid}`.
//
// ثلاث ملاحظات بنيوية جعلت هذه الحزمة تُكتب بهذا الشكل تحديداً:
//   • `FirebaseAuthRest` هوية **ساكنة عامة** (صحيح إنتاجياً: جهاز واحد لكل
//     عملية) لكنها في الاختبار مشتركة بين repoA وrepoB. لذا لا نفحص هنا أي
//     ثابت يعتمد على عضوية المدير — نفحص عضوية العضو فقط.
//   • `MockClient` الافتراضي يعيد `null` لطلب `accounts:signUp`، فيبقى uid
//     ما بعد التدوير **فارغاً** ولا يُفحص شيء. لذلك نُحاكي Identity Toolkit
//     أدناه ويصدر uid حقيقياً جديداً لكل تدوير — كما في الإنتاج.
//   • qa_batch51 تستدعي `completeApprovedJoin` بلا workspaceId فيسقط على
//     'default' ولا ينكشف ذلك لأنها تثبّت debugForceLegacyWorkspaceId.
//     هنا المعرّف عشوائي حقيقي (WS-…) وworkspaceId يُمرر صراحةً كما يفعل
//     join_approval_flow.dart في الإنتاج (`workspaceId: _joinWs`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية + محاكاة Identity Toolkit (إصدار هوية مجهولة عند التدوير).
class FakeCloudStore {
  final Map<String, Object?> store = {};

  /// عدّاد الهويات المجهولة — يضمن uid فريداً لكل تدوير (كما يفعل Firebase).
  int anonSeq = 0;

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        final host = req.url.host;
        final path = req.url.path;

        // ── Identity Toolkit: إنشاء حساب مجهول ──
        // بدونه يبقى uid ما بعد تدوير الهوية فارغاً فلا يُفحص شيء.
        if (host == 'identitytoolkit.googleapis.com' &&
            path.contains('accounts:signUp')) {
          anonSeq++;
          final uid = 'ANON-$anonSeq';
          return _json(
              jsonEncode({
                'localId': uid,
                'idToken': 'tok-$uid',
                'refreshToken': 'ref-$uid',
                'expiresIn': '3600',
              }),
              200);
        }
        // ── securetoken: تجديد التوكن (يبقي نفس الهوية) ──
        if (host == 'securetoken.googleapis.com') {
          final body = req.body;
          final m = RegExp(r'refresh_token=([^&]*)').firstMatch(body);
          final ref = m == null ? '' : Uri.decodeQueryComponent(m.group(1)!);
          final uid = ref.startsWith('ref-') ? ref.substring(4) : 'ANON-0';
          return _json(
              jsonEncode({
                'id_token': 'tok-$uid',
                'refresh_token': ref,
                'user_id': uid,
                'expires_in': '3600',
              }),
              200);
        }

        // ── RTDB ──
        final key = path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          return _json('null', 200);
        }
        final direct = store[key];
        if (direct != null) return _json(jsonEncode(direct), 200);
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child =
                e.key.substring(prefix.length + 1).replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = e.value;
          }
        }
        if (children.isNotEmpty) return _json(jsonEncode(children), 200);
        return _json('null', 200);
      });

  /// كتابة عقدة عضو مباشرة في المخزن — محاكاة أثر إصدار سابق (بلا HTTP).
  void seedMember(String ws, String uid, Map<String, Object?> body) {
    store['/workspaces/$ws/members/${Uri.encodeComponent(uid)}.json'] = body;
  }

  /// مفتاح عقدة عضو لـ uid معيّن، أو null إن لم توجد.
  String? memberKeyOf(String ws, String uid) {
    final k = '/workspaces/$ws/members/${Uri.encodeComponent(uid)}.json';
    return store.containsKey(k) ? k : null;
  }

  /// كل عقد `/members` التي تشير إلى جهاز معيّن (بغضّ النظر عن مفتاحها).
  List<MapEntry<String, Object?>> memberEntriesOfDevice(String devId) =>
      store.entries
          .where((e) =>
              e.key.contains('/members/') &&
              e.value is Map &&
              '${(e.value as Map)['deviceId'] ?? ''}' == devId)
          .toList();
}

void main() {
  // **لا** debugForceLegacyWorkspaceId: نريد معرّف مساحة حقيقياً (WS-…) كي
  // يكون تمرير workspaceId صراحةً جزءاً من الفحص لا صدفة.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA; // المدير
  late Repo repoB; // الجهاز المنضم
  const url = 'https://qa-members.firebaseio.com';
  const memberSeedUid = 'U-MEMBER-SEED';

  /// يثبّت هوية مجهولة محلية بلا شبكة (نفس مفاتيح initSilentAuth).
  ///
  /// يلزم استدعاء `resetAnonymousSession` أولاً لأن `initSilentAuth` يحرس
  /// بـ `_anonStarted` الساكن — وإلا احتفظنا بهوية اختبار سابق (تلوّث).
  /// مفتاح التوكن خاص في FirebaseAuthRest فتُكتب سلسلته حرفياً هنا.
  Future<void> seedIdentity(Repo repo, String uid) async {
    await FirebaseAuthRest.resetAnonymousSession(repo);
    await repo.setSetting(FirebaseAuthRest.anonUidKey, uid);
    await repo.setSetting('cloud.anon.idToken', 'tok-$uid');
    await repo.setSetting('cloud.anon.refresh', 'ref-$uid');
    await repo.setSetting(
        'cloud.anon.expiryMs',
        '${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}');
    await FirebaseAuthRest.initSilentAuth(repo);
    expect(FirebaseAuthRest.currentUid, uid,
        reason: 'تعذّر تثبيت الهوية — الفحص سيفحص فراغاً');
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_members_');
    Future<Database> open(String name) =>
        databaseFactory.openDatabase('${tmp.path}/$name.db',
            options: OpenDatabaseOptions(
                onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    a = await open('a');
    b = await open('b');
    await AppDatabase.createSchema(a);
    await AppDatabase.createSchema(b);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await repoA.setSetting('cloudBackendUrl', url);
    await repoA.setSetting('cloudCode', 'QA123');
    // هوية بدئية محددة لكل اختبار (وإلا ورثنا هوية الاختبار السابق).
    await seedIdentity(repoB, memberSeedUid);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  /// التدفق الكامل: دعوة ← طلب انضمام ← موافقة بدور ← ترطيب نظيف.
  Future<({String ws, String devId, String role, String uidAtRequest})>
      runApprovalFlow(FakeCloudStore cloud,
          {String role = 'accountant', String deviceName = 'كاشير الصالة'}) async {
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    await http.runWithClient(
        () => CloudJoin.requestJoin(repoB,
            backendUrl: url,
            tokenOrPin: inv.token,
            deviceName: deviceName,
            workspaceId: inv.workspaceId),
        cloud.client);
    final uidAtRequest = FirebaseAuthRest.currentUid;
    final reqs = await http.runWithClient(
        () => CloudJoin.fetchJoinRequests(repoA,
            backendUrl: url, workspaceId: inv.workspaceId),
        cloud.client);
    expect(reqs, isNotEmpty, reason: 'يجب أن يرى المدير طلب الانضمام');
    final joinerId = '${reqs.first['deviceId']}';
    expect('${reqs.first['uid']}', uidAtRequest,
        reason: 'الطلب يجب أن يحمل uid الجهاز ليكتب المدير عضويته عليه');
    await http.runWithClient(
        () => CloudJoin.approveJoinRequest(repoA,
            backendUrl: url,
            deviceId: joinerId,
            deviceName: deviceName,
            roleCode: role,
            workspaceId: inv.workspaceId),
        cloud.client);
    // كما في الإنتاج (join_approval_flow.dart): workspaceId صريح.
    await http.runWithClient(
        () => CloudJoin.completeApprovedJoin(repoB,
            backendUrl: url, token: inv.token, workspaceId: inv.workspaceId),
        cloud.client);
    return (
      ws: inv.workspaceId,
      devId: joinerId,
      role: role,
      uidAtRequest: uidAtRequest,
    );
  }

  group('ثابت العضوية بعد تدوير الهوية', () {
    test('QA-MEM-01 العضوية تُرحَّل إلى uid الجاري بعد join()', () async {
      final cloud = FakeCloudStore();
      final flow = await runApprovalFlow(cloud);

      // الربط نجح: الجهاز عضو محلياً ومساحته صارت مساحة المجموعة.
      expect(await repoB.workspaceMode(), 'member');
      expect(repoB.requireWorkspaceId, flow.ws);

      // التدوير حدث فعلاً — وإلا كان الفحص بلا معنى (يمرّ صدفة).
      final uidNow = FirebaseAuthRest.currentUid;
      expect(uidNow, isNotEmpty, reason: 'بلا هوية سحابية لا معنى للفحص');
      expect(uidNow, isNot(flow.uidAtRequest),
          reason: 'join() يجب أن يدوّر الهوية (دفعة 65) — إن لم يفعل '
              'فهذا الفحص لا يغطي شيئاً');

      // ── الثابت الجوهري ──
      final keyNow = cloud.memberKeyOf(flow.ws, uidNow);
      expect(keyNow, isNotNull,
          reason: 'عضوية /members مفقودة تحت uid الجاري ($uidNow) — '
              'التدوير ترك عضوية المدير معلّقة على uid قديم '
              '(${flow.uidAtRequest})، فتحت قواعد مرجعية /members/{auth.uid} '
              'يُحرم العضو من المزامنة كلياً');

      final rec = cloud.store[keyNow] as Map;
      expect('${rec['role']}', flow.role,
          reason: 'الدور المعيّن من المدير يجب أن ينتقل مع الترحيل');
      expect('${rec['uid']}', uidNow,
          reason: 'حقل uid داخل العقدة يجب أن يطابق مفتاحها');
      expect('${rec['deviceId']}', flow.devId,
          reason: 'العضوية يجب أن تبقى مربوطة بالجهاز نفسه');
      expect('${rec['migrated_from']}', flow.uidAtRequest,
          reason: 'يجب توثيق مصدر الترحيل للتدقيق');
      expect(cloud.memberKeyOf(flow.ws, flow.uidAtRequest), isNull,
          reason: 'العضوية القديمة يجب أن تُمحى — لا ركام في /members');
    });

    test('QA-MEM-02 لا تناقض بين roster وmembers ولا عضوية مكرّرة للجهاز',
        () async {
      final cloud = FakeCloudStore();
      final flow = await runApprovalFlow(cloud);
      final uidNow = FirebaseAuthRest.currentUid;

      // roster يحمل الجهاز بهويته الحالية ⇒ members يجب أن تعرفها.
      expect(
          cloud.store.keys
              .where((k) => k.contains('/roster/') && k.contains(flow.devId)),
          isNotEmpty,
          reason: 'الجهاز غير مسجّل في roster المجموعة');
      expect(cloud.memberKeyOf(flow.ws, uidNow), isNotNull,
          reason: 'roster يحمل الجهاز بهويته الحالية بينما /members '
              'لا يعرفها — سجلّان سحابيان متناقضان عن العضو نفسه');

      // عضوية واحدة بالضبط لهذا الجهاز (لا يتيمة + لا مكرّرة).
      final entries = cloud.memberEntriesOfDevice(flow.devId);
      expect(entries.length, 1,
          reason: 'يجب أن تكون للعضو عضوية واحدة معلّقة على uid الجاري، '
              'وُجد: ${entries.map((e) => e.key).toList()}');
      expect(entries.single.key,
          contains(Uri.encodeComponent(uidNow)),
          reason: 'العضوية الوحيدة يجب أن تكون تحت uid الجاري');
    });

    test('QA-MEM-03 الطلب والدعوة يُنظَّفان تحت مساحة المجموعة الحقيقية',
        () async {
      final cloud = FakeCloudStore();
      final flow = await runApprovalFlow(cloud);

      expect(flow.ws, isNot('default'),
          reason: 'الفحص يفقد معناه إن كانت المساحة default');
      // مع معرّف مساحة حقيقي (WS-…)، التنظيف يجب أن يصيب مسار المجموعة
      // نفسه — وإلا بقي الطلب معلّقاً لدى المدير إلى الأبد.
      expect(cloud.store.keys.where((k) => k.contains('/joinRequests/')),
          isEmpty,
          reason: 'طلب الانضمام لم يُحذف بعد الإكمال — سيبقى يظهر لدى '
              'المدير كطلب معلّق (يحدث إن سقط workspaceId على default)');
      expect(cloud.store.keys.where((k) => k.contains('/invites/')), isEmpty,
          reason: 'الدعوة لم تُبطل — قابلة لإعادة الاستخدام');
      // اللقطة تبقى لأعضاء لاحقين.
      expect(cloud.store.keys.any((k) => k.contains('joinSnapshot')), isTrue);
      // سياق الانتظار المحلي نُظّف.
      final st = await repoB.settings();
      expect(st.containsKey('pendingJoin.token'), isFalse);
    });
  });

  group('reconcileMemberMembership — شبكة الأمان', () {
    test('QA-MEM-04 يشفي عضوية يتيمة من إصدار سابق (بالـdeviceId لا بالاسم)',
        () async {
      final cloud = FakeCloudStore();
      await seedIdentity(repoB, 'U-CURRENT-01');
      final devId = await ensureDeviceId(repoB);
      const ws = 'WS-LEGACY01';

      // عضو انضم على إصدار سابق: عضويته معلّقة على uid قديم، وجهازه نفسه.
      cloud.seedMember(ws, 'U-STALE-99', {
        'role': 'agent',
        'uid': 'U-STALE-99',
        'deviceId': devId,
        'joined_at': 1770000000000,
      });

      final healed = await http.runWithClient(
          () => CloudJoin.reconcileMemberMembership(repoB,
              backendUrl: url, workspaceId: ws),
          cloud.client);

      expect(healed, isTrue, reason: 'يجب أن يكتشف العضوية اليتيمة ويرحّلها');
      final key = cloud.memberKeyOf(ws, 'U-CURRENT-01');
      expect(key, isNotNull, reason: 'لم تُكتب العضوية تحت uid الجاري');
      final rec = cloud.store[key] as Map;
      expect('${rec['role']}', 'agent', reason: 'الدور يجب أن يُحفظ كما هو');
      expect('${rec['deviceId']}', devId);
      expect('${rec['migrated_from']}', 'U-STALE-99',
          reason: 'يجب توثيق مصدر الترحيل للتدقيق');
      expect(cloud.memberKeyOf(ws, 'U-STALE-99'), isNull,
          reason: 'اليتيمة يجب أن تُمحى — لا ركام في /members');
    });

    test('QA-MEM-05 عضوية المدير (owner) لا تُرحَّل آلياً أبداً', () async {
      final cloud = FakeCloudStore();
      await seedIdentity(repoB, 'U-CURRENT-02');
      final devId = await ensureDeviceId(repoB);
      const ws = 'WS-OWNER01';

      // عقدة owner على deviceId نفسه — سيناريو شاذّ (نقل ملكية غير مكتمل).
      // الترحيل الآلي هنا سينزع الملكية من المدير: ممنوع.
      cloud.seedMember(ws, 'U-OWNER-OLD', {
        'role': 'owner',
        'uid': 'U-OWNER-OLD',
        'deviceId': devId,
      });

      final healed = await http.runWithClient(
          () => CloudJoin.reconcileMemberMembership(repoB,
              backendUrl: url, workspaceId: ws),
          cloud.client);

      expect(healed, isFalse,
          reason: 'الملكية لا تُرحَّل آلياً — مسارها transferOwnership الصريح');
      expect(cloud.memberKeyOf(ws, 'U-OWNER-OLD'), isNotNull,
          reason: 'عقدة المالك يجب أن تبقى كما هي');
      expect(cloud.memberKeyOf(ws, 'U-CURRENT-02'), isNull,
          reason: 'يجب ألا تُنشأ عضوية جديدة بانتزاع دور owner');
    });

    test('QA-MEM-06 عضوية سليمة ⇒ لا أثر ولا كتابة (idempotent)', () async {
      final cloud = FakeCloudStore();
      await seedIdentity(repoB, 'U-CURRENT-03');
      final devId = await ensureDeviceId(repoB);
      const ws = 'WS-OK01';

      cloud.seedMember(ws, 'U-CURRENT-03', {
        'role': 'dataentry',
        'uid': 'U-CURRENT-03',
        'deviceId': devId,
      });
      final keysBefore = cloud.store.keys.toList()..sort();

      final healed = await http.runWithClient(
          () => CloudJoin.reconcileMemberMembership(repoB,
              backendUrl: url, workspaceId: ws),
          cloud.client);

      expect(healed, isFalse, reason: 'العضوية سليمة — لا شيء ليُشفى');
      final keysAfter = cloud.store.keys.toList()..sort();
      expect(keysAfter, keysBefore,
          reason: 'يجب ألا تُكتب أو تُمحى أي عقدة');
      expect(
          '${(cloud.store[cloud.memberKeyOf(ws, 'U-CURRENT-03')] as Map)['role']}',
          'dataentry',
          reason: 'الدور القائم يجب ألا يُمس');
    });

    test('QA-MEM-07 بلا هوية سحابية ⇒ لا محاولة ولا كتابة ولا استثناء',
        () async {
      final cloud = FakeCloudStore();
      await FirebaseAuthRest.resetAnonymousSession(repoB);
      expect(FirebaseAuthRest.currentUid, isEmpty);

      final res = await http.runWithClient(
          () => CloudJoin.reconcileMemberMembership(repoB,
              backendUrl: url, workspaceId: 'WS-NOAUTH'),
          cloud.client);

      expect(res, isFalse);
      expect(cloud.store, isEmpty, reason: 'لا كتابة بلا هوية');
    });

    test('QA-MEM-08 migrateMemberUid: لا أثر إن لم تتغيّر الهوية', () async {
      final cloud = FakeCloudStore();
      await seedIdentity(repoB, 'U-SAME-01');
      const ws = 'WS-SAME';
      cloud.seedMember(ws, 'U-SAME-01', {
        'role': 'viewer',
        'uid': 'U-SAME-01',
        'deviceId': repoB.requireDeviceId,
      });

      final moved = await http.runWithClient(
          () => CloudJoin.migrateMemberUid(repoB,
              backendUrl: url, workspaceId: ws, previousUid: 'U-SAME-01'),
          cloud.client);

      expect(moved, isFalse,
          reason: 'previousUid == currentUid ⇒ لا شيء ليُرحَّل');
      expect(cloud.memberKeyOf(ws, 'U-SAME-01'), isNotNull,
          reason: 'العضوية القائمة يجب ألا تُمس');
    });
  });
}
