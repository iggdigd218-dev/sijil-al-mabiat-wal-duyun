// QA — المزامنة السحابية والنسخ السحابي (Firebase REST):
// - جهازان يتزامنان عبر «سحابة» وهمية في الذاكرة (push من أ ثم pull في ب).
// - انتهاء صلاحية idToken لا يفشل الطلب إذا كانت القاعدة عامة (إعادة بدون auth).
// - CloudSync (نسخة كاملة برمز): الرفع لا يكتب فوق نسخة أحدث، والسحب يرفض
//   الحمولة التالفة، وروابط غير https تُرفض مبكراً.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/cloud_sync.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:nexora_app/core/auth_config.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';

/// سحابة Firebase وهمية في الذاكرة: تخزّن العمليات تحت مسار workspaces
/// وسجل النسخ الكاملة تحت codes، وتدعم orderBy/limitToFirst بشكل مبسّط.
class FakeFirebase {
  final Map<String, Map<String, Object?>> operations = {};
  Map<String, Object?>? codeRecord;
  bool requireAuth = false;
  String? validToken;

  /// يحاكي القواعد الافتراضية لـ RTDB: orderBy="timestamp" بلا فهرس
  /// ".indexOn" يُرفض بخطأ 400 (سلوك فيربيس الحقيقي المكتشف في الإنتاج).
  bool rejectOrderBy = false;

  /// http.Response الافتراضية ترمّز بـ latin1 فترفض العربية — نرد UTF-8 دوماً.
  static http.Response _utf8Json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        final path = req.url.path;
        final auth = req.url.queryParameters['auth'];
        if (requireAuth && auth != validToken) {
          return _utf8Json('{"error":"Permission denied"}', 401);
        }
        // نسخة كاملة برمز: /codes/<CODE>.json
        if (path.contains('/codes/')) {
          if (req.method == 'PUT') {
            codeRecord =
                Map<String, Object?>.from(jsonDecode(req.body) as Map);
            return _utf8Json(req.body, 200);
          }
          return _utf8Json(
              codeRecord == null ? 'null' : jsonEncode(codeRecord), 200);
        }
        // عمليات تزايدية: /workspaces/<ws>/operations[...].json
        if (path.contains('/operations')) {
          if (req.method == 'PUT') {
            final opId = Uri.decodeComponent(
                path.split('/operations/').last.replaceAll('.json', ''));
            operations[opId] =
                Map<String, Object?>.from(jsonDecode(req.body) as Map);
            return _utf8Json(req.body, 200);
          }
          // GET قائمة العمليات — نتجاهل startAt/startAfter (حجم الاختبار صغير).
          if (rejectOrderBy &&
              (req.url.queryParameters['orderBy'] == '"server_ts"' ||
                  req.url.queryParameters['orderBy'] == '"timestamp"')) {
            return _utf8Json(
                '{"error" : "Index not defined, add \\".indexOn\\": '
                '\\"timestamp\\", for path \\"/workspaces/default/operations\\", '
                'to the rules"}',
                400);
          }
          if (operations.isEmpty) return _utf8Json('null', 200);
          return _utf8Json(jsonEncode(operations), 200);
        }
        return _utf8Json('null', 404);
      });
}

void main() {
  // هذه الحزمة تبني فرضياتها على مسار workspaces/default القديم —
  // نثبّت المعرف القديم بدل التوليد العشوائي (المعمارية الصامتة).
  debugForceLegacyWorkspaceId = true;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 9, 9);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_cloud_');
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
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  CloudFirebaseTransport transport(Repo repo, Database db,
          {Future<String?> Function()? idToken}) =>
      CloudFirebaseTransport.validated(
        repo: repo,
        dbProvider: () async => db,
        backendUrl: 'https://qa-cloud.firebaseio.com',
        workspaceId: 'default',
        idTokenProvider: idToken,
      );

  test('QA-CLOUD-02 device A pushes op, device B pulls and applies it',
      () async {
    final cloud = FakeFirebase();
    final accId = await repoA.saveAccount(Account(
      name: 'عميل سحابي',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    // العملية المسجلة محلياً في أ.
    final ops = await a.query('operations',
        where: 'entity_type = ?', whereArgs: ['account']);
    expect(ops, isNotEmpty);
    final op = SyncOperation.fromMap(ops.first);

    final tA = transport(repoA, a);
    await http.runWithClient(() => tA.push(op), cloud.client);
    expect(cloud.operations.containsKey(op.id), isTrue);
    // push يعلّم العملية synced محلياً.
    final afterPush = await a
        .query('operations', where: 'id = ?', whereArgs: [op.id], limit: 1);
    expect(afterPush.first['synced'], 1);

    // الجهاز ب يسحب فيطبق العملية (idempotent عند التكرار).
    final tB = transport(repoB, b);
    final applied =
        await http.runWithClient(() => tB.pull(resolver: ConflictResolver()),
            cloud.client);
    expect(applied, greaterThanOrEqualTo(1));
    final bAcc = await b
        .query('accounts', where: 'id = ?', whereArgs: [accId], limit: 1);
    expect(bAcc, isNotEmpty);
    expect(bAcc.first['name'], 'عميل سحابي');
    // سحب ثانٍ لا يكرر التطبيق.
    final again =
        await http.runWithClient(() => tB.pull(resolver: ConflictResolver()),
            cloud.client);
    expect(again, 0);
  });

  test(
      'QA-CLOUD-07 pull falls back to full fetch when RTDB rejects orderBy '
      '(Index not defined — default rules)', () async {
    final cloud = FakeFirebase()..rejectOrderBy = true;
    final accId = await repoA.saveAccount(Account(
      name: 'عميل بلا فهرس',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final ops = await a.query('operations',
        where: 'entity_type = ?', whereArgs: ['account']);
    final op = SyncOperation.fromMap(ops.first);
    final tA = transport(repoA, a);
    await http.runWithClient(() => tA.push(op), cloud.client);

    // قبل الإصلاح: pull كان يفشل بـ cloud-http-400 للأبد (دفع بلا سحب).
    final tB = transport(repoB, b);
    final applied = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(applied, greaterThanOrEqualTo(1),
        reason: 'يجب أن ينجح السحب بالتراجع لجلبٍ كامل بلا orderBy');
    final bAcc = await b
        .query('accounts', where: 'id = ?', whereArgs: [accId], limit: 1);
    expect(bAcc, isNotEmpty);
    expect(bAcc.first['name'], 'عميل بلا فهرس');
    // سحب ثانٍ لا يكرر (idempotent) رغم الجلب الكامل.
    final again = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(again, 0);
  });

  // (المرحلة 2 — الملاحظة أ-1) التراجع إلى «طلب بلا مصادقة» أُلغي نهائياً:
  // القواعد تشترط `auth != null`، والطلب العاري كان يُخفي غياب الهوية بدل
  // إصلاحه. البديل: تجديد توكن هوية الجهاز ثم إعادة محاولة واحدة بهوية.
  test('QA-CLOUD-03 expired idToken: refresh + retry with auth (no bare retry)',
      () async {
    await repoA.saveAccount(Account(
      name: 'ح',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final ops = await a.query('operations', limit: 1);
    final op = SyncOperation.fromMap(ops.first);

    final rtdbAuth = <String?>[];
    var tokenRefreshes = 0;
    final client = MockClient((req) async {
      final host = req.url.host;
      // نقاط هوية Firebase (خارج RTDB): إنشاء الحساب المجهول/تجديده.
      if (host.contains('identitytoolkit') || host.contains('securetoken')) {
        tokenRefreshes++;
        return host.contains('securetoken')
            ? FakeFirebase._utf8Json(
                '{"id_token":"FRESH","refresh_token":"RT2",'
                '"expires_in":"3600","user_id":"UID1"}',
                200)
            : FakeFirebase._utf8Json(
                '{"idToken":"FRESH","refreshToken":"RT2",'
                '"expiresIn":"3600","localId":"UID1"}',
                200);
      }
      rtdbAuth.add(req.url.queryParameters['auth']);
      final auth = req.url.queryParameters['auth'];
      if (auth == 'EXPIRED') {
        return FakeFirebase._utf8Json('{"error":"Auth token is expired"}', 401);
      }
      if (auth == 'FRESH') {
        return FakeFirebase._utf8Json(
            req.body.isEmpty ? 'null' : req.body, 200);
      }
      // أي طلب RTDB بلا auth = تراجع أمني مرفوض.
      return FakeFirebase._utf8Json('{"error":"Unauthorized"}', 401);
    });

    final t = transport(repoA, a, idToken: () async => 'EXPIRED');
    await http.runWithClient(() => t.push(op), () => client);

    expect(tokenRefreshes, greaterThan(0),
        reason: 'عند 401 يجب طلب تجديد توكن الهوية');
    expect(rtdbAuth, contains('FRESH'),
        reason: 'إعادة المحاولة بالتوكن المجدَّد لا بطلب عارٍ');
    expect(rtdbAuth.any((v) => v == null || v.isEmpty), isFalse,
        reason: 'لا يجوز إرسال أي طلب RTDB بلا ?auth=');
    final after =
        await a.query('operations', where: 'id = ?', whereArgs: [op.id]);
    expect(after.first['synced'], 1, reason: 'الدفع اكتمل بعد التجديد');
  });

  test('QA-CLOUD-03b بدون حساب Google: يُرفق توكن الهوية المجهولة لا طلب عارٍ',
      () async {
    await repoA.saveAccount(Account(
      name: 'ط',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final ops = await a.query('operations', limit: 1);
    final op = SyncOperation.fromMap(ops.first);

    final rtdbAuth = <String?>[];
    final client = MockClient((req) async {
      if (req.url.host.contains('googleapis')) {
        return FakeFirebase._utf8Json(
            '{"idToken":"ANON","refreshToken":"RT","expiresIn":"3600",'
            '"localId":"UID-ANON"}',
            200);
      }
      rtdbAuth.add(req.url.queryParameters['auth']);
      return FakeFirebase._utf8Json(req.body.isEmpty ? 'null' : req.body, 200);
    });

    final t = transport(repoA, a, idToken: () async => null);
    await http.runWithClient(() => t.push(op), () => client);

    expect(rtdbAuth, isNotEmpty);
    expect(rtdbAuth.any((v) => v == null || v.isEmpty), isFalse,
        reason: 'كل طلب RTDB يحمل auth حتى بلا حساب Google');
  });

  test('QA-CLOUD-03c الهوية المجهولة: accounts:signUp ينشئ localId/idToken '
      'وsecuretoken يجدّده', () async {
    debugFirebaseApiKeyOverride = 'TEST_KEY';
    addTearDown(() => debugFirebaseApiKeyOverride = '');

    // الخدمة ثابتة (Singleton) وقد تحمل هوية من اختبار سابق — لذا يُفرض
    // المسار المطلوب بجعل نقطة التجديد تفشل تارةً وتنجح تارةً أخرى.
    final hosts = <String>[];
    http.Client client({required bool refreshWorks}) => MockClient((req) async {
          hosts.add(req.url.host);
          if (req.url.host.contains('securetoken')) {
            return refreshWorks
                ? FakeFirebase._utf8Json(
                    '{"id_token":"TOK2","refresh_token":"REF2",'
                    '"expires_in":"3600","user_id":"UID-ANON-1"}',
                    200)
                : FakeFirebase._utf8Json('{"error":"invalid_grant"}', 400);
          }
          return FakeFirebase._utf8Json(
              '{"idToken":"TOK1","refreshToken":"REF1","expiresIn":"3600",'
              '"localId":"UID-ANON-1"}',
              200);
        });

    // ١) التجديد يتعذّر → يُنشأ الحساب المجهول عبر accounts:signUp.
    await http.runWithClient(() async {
      await FirebaseAuthRest.initSilentAuth(repoA); // يربط المستودع للحفظ
      final tok = await FirebaseAuthRest.forceRefreshToken();
      expect(tok, 'TOK1', reason: 'signUp يُصدر idToken');
      expect(FirebaseAuthRest.currentUid, 'UID-ANON-1',
          reason: 'localId من accounts:signUp يصير auth.uid');
      expect(FirebaseAuthRest.hasValidToken, isTrue);
      expect(hosts, contains('identitytoolkit.googleapis.com'));
    }, () => client(refreshWorks: false));

    // ٢) التجديد ينجح → securetoken بـ refresh token، والهوية لا تتغيّر.
    await http.runWithClient(() async {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      expect(fresh, 'TOK2');
      expect(FirebaseAuthRest.currentUid, 'UID-ANON-1',
          reason: 'ثبات auth.uid بالتجديد يحفظ عضوية /members');
      expect(hosts, contains('securetoken.googleapis.com'));
    }, () => client(refreshWorks: true));

    // ٣) الثبات عبر إعادة التشغيل: نفس auth.uid يُستعاد من الإعدادات.
    final st = await repoA.settings();
    expect(st[FirebaseAuthRest.anonUidKey], 'UID-ANON-1');
    expect(st['cloud.anon.refresh'] ?? '', 'REF2');
  });

  test('QA-CLOUD-04 CloudSync full backup: push/pull with newer-remote guard',
      () async {
    final cloud = FakeFirebase();
    await repoA.setSetting(
        'cloudBackendUrl', 'https://qa-cloud.firebaseio.com');
    await CloudSync.setCode(repoA, 'QAQA1');
    await repoA.saveAccount(Account(
      name: 'عميل النسخة',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final payload = await repoA.exportAll(withImages: false);
    final r = await http.runWithClient(
        () => CloudSync.push(repoA, payload), cloud.client);
    expect(r['ok'], true);
    expect(cloud.codeRecord, isNotNull);

    // نسخة سحابية أحدث → الرفع بلا force يتخطى ولا يكتب فوقها.
    final newer = Map<String, Object?>.from(cloud.codeRecord!);
    final newerPayload =
        Map<String, Object?>.from(newer['payload'] as Map)
          ..['created_at'] = DateTime(2099).toIso8601String();
    newer['payload'] = newerPayload;
    cloud.codeRecord = newer;
    final r2 = await http.runWithClient(
        () => CloudSync.push(repoA, payload), cloud.client);
    expect(r2['skipped'], true);
    expect(r2['remoteIsNewer'], true);

    // السحب يعيد الحمولة الصالحة.
    final pulled =
        await http.runWithClient(() => CloudSync.pull(repoA), cloud.client);
    expect(pulled['ok'], true);
    expect(pulled['exists'], true);
    final data = (pulled['payload'] as Map)['data'] as Map;
    expect(data.containsKey('accounts'), isTrue);

    // حمولة تالفة (بلا data) تُرفض ولا تُمرَّر للاستيراد.
    cloud.codeRecord = {
      'payload': {'x': 1}
    };
    final bad =
        await http.runWithClient(() => CloudSync.pull(repoA), cloud.client);
    expect(bad['ok'], false);
  });

  test('QA-CLOUD-06 SSE listener notifies on new remote op (near-realtime)',
      () async {
    // خادم SSE محلي يحاكي فيربيس: يرسل لقطة أولية ثم حدثاً جديداً.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gotListener = Completer<void>();
    server.listen((req) async {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.bufferOutput = false;
      // اللقطة الأولية (يجب أن تُتجاهل).
      req.response.write('event: put\ndata: {"path":"/","data":null}\n\n');
      await req.response.flush();
      if (!gotListener.isCompleted) gotListener.complete();
      // بعد لحظة: عملية جديدة (يجب أن تطلق onCloudChanged).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      req.response.write(
          'event: put\ndata: {"path":"/op-9","data":{"id":"op-9"}}\n\n');
      await req.response.flush();
      // أبقِ القناة مفتوحة قليلاً.
      await Future<void>.delayed(const Duration(seconds: 2));
      await req.response.close();
    });

    final t = CloudFirebaseTransport(
      repo: repoA,
      dbProvider: () async => a,
      backendUrl: 'http://127.0.0.1:${server.port}',
      workspaceId: 'default',
    );
    final changed = Completer<void>();
    t.onCloudChanged = () {
      if (!changed.isCompleted) changed.complete();
    };
    await t.startListening();
    await gotListener.future.timeout(const Duration(seconds: 5));
    // الحدث الجديد يصل خلال أقل من ثانيتين — شبه فوري.
    await changed.future.timeout(const Duration(seconds: 5),
        onTimeout: () => fail('لم يصل إشعار SSE خلال المهلة'));
    await t.stopListening();
    await server.close(force: true);
    expect(t.isListening, isFalse);
  });

  test(
      'QA-CLOUD-08 clock drift: op from device with slow clock still pulled '
      '(cursor uses server_ts, not device ISO time)', () async {
    final cloud = FakeFirebase();
    // عمليتان: جهاز ساعته مضبوطة (اليوم) وجهاز ساعته متأخرة 3 أيام.
    // ختم الخادم server_ts هو الحقيقي لكليهما (متقاربان).
    final serverNow = DateTime.now().millisecondsSinceEpoch;
    cloud.operations['OP-ONTIME'] = {
      'id': 'OP-ONTIME',
      'device_id': 'DEV-ONTIME',
      'workspace_id': 'default',
      'entity_type': 'account',
      'entity_id': '111222333',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': jsonEncode({
        'id': 111222333,
        'name': 'حساب ساعة مضبوطة',
        'kind': 'customer',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      }),
      'device_time': now.toIso8601String(),
      'timestamp': now.toIso8601String(),
      'server_ts': serverNow,
      'synced': 1,
    };
    cloud.operations['OP-SLOWCLOCK'] = {
      'id': 'OP-SLOWCLOCK',
      'device_id': 'DEV-SLOWCLOCK',
      'workspace_id': 'default',
      'entity_type': 'account',
      'entity_id': '444555666',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': jsonEncode({
        'id': 444555666,
        'name': 'حساب ساعة متأخرة',
        'kind': 'customer',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      }),
      // ساعة الهاتف متأخرة 3 أيام — قبل الإصلاح كان المؤشر النصي يتخطاها.
      'device_time':
          now.subtract(const Duration(days: 3)).toIso8601String(),
      'timestamp': now.subtract(const Duration(days: 3)).toIso8601String(),
      'server_ts': serverNow + 500, // وصلت للخادم بعد الأولى بنصف ثانية.
      'synced': 1,
    };
    final tB = transport(repoB, b);
    final applied = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(applied, 2, reason: 'العمليتان تُطبَّقان معاً');
    // المؤشر تقدم بختم الخادم الأكبر (رقم ملي ثانية)، لا بتوقيت الجهاز.
    final cur = await b.query('sync_meta',
        where: 'key = ?', whereArgs: ['lastCloudTs:default'], limit: 1);
    expect(cur, isNotEmpty);
    expect(int.tryParse('${cur.first['value']}'), serverNow + 500,
        reason: 'المؤشر = أكبر server_ts، وليس ISO من ساعة هاتف');
    // عملية الجهاز المتأخر وصلت رغم انحراف ساعته.
    final acc = await b.query('accounts',
        where: 'id = ?', whereArgs: [444555666], limit: 1);
    expect(acc, isNotEmpty);
  });

  test('QA-CLOUD-05 non-https backend URL rejected early', () async {
    expect(() => CloudSync.setBackendUrl(repoA, 'http://insecure.example'),
        throwsArgumentError);
    expect(
        () => CloudFirebaseTransport.validated(
              repo: repoA,
              dbProvider: () async => a,
              backendUrl: 'http://insecure.example',
              workspaceId: 'default',
            ),
        throwsArgumentError);
    // https صالح يُحفظ.
    await CloudSync.setBackendUrl(
        repoA, 'https://ok-project-default-rtdb.firebaseio.com');
    final st = await repoA.settings();
    expect(st['cloudBackendUrl'],
        'https://ok-project-default-rtdb.firebaseio.com');
  });

  // ══════════════════════════════════════════════════════════════════════
  // (401 بعد تسجيل الدخول بـ Google) كان الاستبدال يستخرج `localId` فقط
  // ويُهمل `idToken`، فتبقى كل طلبات cloud_join عارية أو بهوية مجهولة لا
  // تملك صلاحية المالك → HTTP 401 عند إنشاء الدعوة.
  // ══════════════════════════════════════════════════════════════════════

  test('QA-CLOUD-03d استبدال توكن Google: ?auth= يحمل توكن Firebase لا الخام',
      () async {
    debugFirebaseApiKeyOverride = 'TEST_KEY';
    addTearDown(() async {
      debugFirebaseApiKeyOverride = '';
      await FirebaseAuthRest.clearSession(repoA);
    });

    final idpBodies = <String>[];
    final appAuth = <String>[]; // توكنات ?auth= في طلبات كود الإنتاج فقط

    http.Client client() => MockClient((req) async {
          if (req.url.host.contains('identitytoolkit')) {
            idpBodies.add(req.body);
            return FakeFirebase._utf8Json(
                '{"localId":"UID-GOOGLE-1","email":"owner@nexora.test",'
                '"idToken":"FB-TOKEN","refreshToken":"FB-REF",'
                '"expiresIn":"3600"}',
                200);
          }
          if (req.url.host.contains('securetoken')) {
            return FakeFirebase._utf8Json('{"error":"invalid_grant"}', 400);
          }
          // أي طلب RTDB: القواعد لا تقبل إلا توكن Firebase الصحيح.
          final auth = req.url.queryParameters['auth'] ?? '';
          // مسار __probe__ استقصاء اختباري مباشر (يُرسَل عمداً بالتوكن الخام
          // لبيان أن RTDB ترفضه) — فلا يُحسب ضمن طلبات كود الإنتاج.
          if (!req.url.path.contains('__probe__')) appAuth.add(auth);
          if (auth != 'FB-TOKEN') {
            return FakeFirebase._utf8Json('{"error":"Permission denied"}', 401);
          }
          return FakeFirebase._utf8Json('{"ok":true}', 200);
        });

    await http.runWithClient(() async {
      // ١) الاستبدال يُرسل توكن Google الخام داخل postBody فقط.
      final account =
          await FirebaseAuthRest.signInWithGoogleIdToken('RAW-GOOGLE-TOKEN');
      expect(account, isNotNull);
      expect(account!.uid, 'UID-GOOGLE-1');
      expect(idpBodies.single, contains('id_token=RAW-GOOGLE-TOKEN'));

      // ٢) الحفظ يثبّت توكن Firebase وجلسة الحساب.
      await FirebaseAuthRest.saveSession(repoA, account);
      expect(FirebaseAuthRest.currentUid, 'UID-GOOGLE-1',
          reason: 'auth.uid يصبح UID الحساب لا الهوية المجهولة للجهاز');
      expect(await FirebaseAuthRest.cloudIdToken(), 'FB-TOKEN',
          reason: '?auth= يحمل توكن Firebase الناتج عن الاستبدال');

      // ٣) طلب حقيقي من كود الإنتاج إلى RTDB: يجب أن يُوقَّع بتوكن Firebase.
      await CloudJoin.ensureOwnerMembership(repoA,
          backendUrl: 'https://qa-cloud.firebaseio.com', workspaceId: 'default');

      // ٤) الجوهرة: التوكن الخام مرفوض من RTDB والمُستبدل مقبول (مسار استقصاء).
      final raw = await http.get(Uri.parse('https://qa-cloud.firebaseio.com/'
          '__probe__.json?auth=RAW-GOOGLE-TOKEN'));
      expect(raw.statusCode, 401,
          reason: 'توكن Google الخام لا تعترف به قواعد RTDB');
      final good = await http.get(Uri.parse('https://qa-cloud.firebaseio.com/'
          '__probe__.json?auth=FB-TOKEN'));
      expect(good.statusCode, 200);
    }, client);

    expect(appAuth, isNotEmpty, reason: 'كود الإنتاج أجرى طلباً إلى RTDB');
    expect(appAuth, everyElement('FB-TOKEN'),
        reason: 'كل طلب من كود الإنتاج حمل توكن Firebase لا توكن Google الخام');

    // ٤) الثبات عبر إعادة التشغيل.
    final st = await repoA.settings();
    expect(st['account.uid'], 'UID-GOOGLE-1');
    expect(st['account.idToken'], 'FB-TOKEN');
    expect(st['account.refreshToken'], 'FB-REF');
  });

  test('QA-CLOUD-03e عضوية المالك تُكتب تحت members/{googleUid} بدور owner',
      () async {
    addTearDown(() async {
      await FirebaseAuthRest.clearSession(repoA);
    });

    // جلسة حساب جاهزة (بلا شبكة): توكن Firebase بعد الاستبدال.
    await FirebaseAuthRest.saveSession(
      repoA,
      const FirebaseAccount(
        uid: 'UID-GOOGLE-1',
        email: 'owner@nexora.test',
        idToken: 'FB-TOKEN',
        refreshToken: 'FB-REF',
        expiresInSeconds: 3600,
      ),
    );

    final puts = <String, Map<String, Object?>>{};
    final deletes = <String>[];
    final authed = <bool>[];

    http.Client client() => MockClient((req) async {
          final auth = req.url.queryParameters['auth'];
          authed.add(auth == 'FB-TOKEN');
          if (auth != 'FB-TOKEN') {
            return FakeFirebase._utf8Json('{"error":"Permission denied"}', 401);
          }
          final path = req.url.path;
          if (req.method == 'PUT') {
            puts[path] = Map<String, Object?>.from(jsonDecode(req.body) as Map);
            return FakeFirebase._utf8Json(req.body, 200);
          }
          if (req.method == 'DELETE') {
            deletes.add(path);
            return FakeFirebase._utf8Json('null', 200);
          }
          return FakeFirebase._utf8Json('null', 200); // GET → عقدة غائبة
        });

    await http.runWithClient(() async {
      await CloudJoin.ensureOwnerMembership(repoA,
          backendUrl: 'https://qa-cloud.firebaseio.com', workspaceId: 'default');
    }, client);

    final memberPath =
        puts.keys.singleWhere((k) => k.contains('/members/'), orElse: () => '');
    expect(memberPath, contains('/members/UID-GOOGLE-1.json'),
        reason: 'العقدة مفتاحها UID الحساب (كانت تُكتب بالهوية المجهولة)');
    expect(puts[memberPath]!['role'], 'owner');
    expect(puts[memberPath]!['uid'], 'UID-GOOGLE-1');
    expect(puts[memberPath]!['deviceId'], isNotEmpty);
    expect(authed, everyElement(isTrue),
        reason: 'كل طلب إلى RTDB حمل ?auth= بتوكن Firebase');

    // الترحيل: نقل العضوية من الهوية المجهولة القديمة إلى UID الحساب.
    await http.runWithClient(() async {
      await CloudJoin.migrateOwnerMembership(repoA,
          backendUrl: 'https://qa-cloud.firebaseio.com',
          workspaceId: 'default',
          previousUid: 'UID-ANON-OLD');
    }, client);
    expect(deletes.any((p) => p.contains('/members/UID-ANON-OLD.json')), isTrue,
        reason: 'يُمحى سجل الهوية المجهولة القديم بعد نقلها');
  });
}
