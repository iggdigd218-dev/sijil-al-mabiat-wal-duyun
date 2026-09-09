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
              req.url.queryParameters['orderBy'] == '"timestamp"') {
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

  test('QA-CLOUD-03 expired idToken retries without auth on public rules',
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
    // قاعدة تتطلب توكن صالحاً فقط عندما يُرسل auth — نحاكي: أي auth مرسل
    // غير صالح يعيد 401، وبدون auth تنجح (قواعد عامة).
    var sawExpired = false;
    final client = MockClient((req) async {
      final auth = req.url.queryParameters['auth'];
      if (auth != null) {
        sawExpired = true;
        return FakeFirebase._utf8Json('{"error":"Auth token is expired"}', 401);
      }
      return FakeFirebase._utf8Json(req.body.isEmpty ? 'null' : req.body, 200);
    });
    final t = transport(repoA, a, idToken: () async => 'EXPIRED');
    await http.runWithClient(() => t.push(op), () => client);
    expect(sawExpired, isTrue, reason: 'يجب أن يجرب التوكن أولاً ثم يسقط عنه');
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
}
