// QA — الانضمام عبر السحابة (CloudJoin):
// - المدير ينشئ دعوة: تُرفع لقطة كاملة + رمز دعوة إلى سحابة وهمية.
// - جهاز مستقل ينضم بالرمز: تُحذف بياناته المحلية بالكامل وتُستبدل بنسخة
//   المجموعة، يصبح عضواً، وتُضبط إعدادات السحابة بنفس رابط المدير.
// - الدعوة تُستخدم مرة واحدة، والعضو لا يستطيع إنشاء دعوة.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية: تخزّن أي PUT حسب المسار وتعيد GET من نفس المخزن.
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
          return _utf8Json('null', 200);
        }
        // GET — دعم جلب عقدة كاملة مثل roster.json (تجميع الأبناء).
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
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 9, 9);
  const url = 'https://qa-join.firebaseio.com';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_join_');
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
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  test('QA-JOIN-01 full cloud join: wipe local data, adopt group snapshot',
      () async {
    final cloud = FakeCloudStore();
    // بيانات المدير التي يجب أن تصل للعضو.
    await repoA.saveAccount(Account(
      name: 'عميل المجموعة',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    // بيانات محلية على الجهاز المستقل يجب أن تُحذف بالكامل عند الانضمام.
    await repoB.saveAccount(Account(
      name: 'بيانات قديمة يجب حذفها',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));

    final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    expect(invite.token, isNotEmpty);
    expect(invite.backendUrl, url);
    expect(invite.cloudCode, 'QA123');
    // اللقطة والدعوة موجودتان في السحابة.
    expect(
        cloud.store.keys.any((k) => k.contains('joinSnapshot')), isTrue);
    expect(
        cloud.store.keys
            .any((k) => k.contains('/invites/${invite.token}')),
        isTrue);
    // محتوى QR قابل للتحليل.
    final parsed = CloudInviteInfo.parseQr(invite.qrContent);
    expect(parsed?['tok'], invite.token);
    expect(parsed?['url'], url);

    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: invite.backendUrl,
            token: invite.token,
            workspaceId: invite.workspaceId,
            cloudCode: invite.cloudCode),
        cloud.client);

    // أصبح عضواً وبياناته القديمة اختفت وبيانات المجموعة حلّت محلها.
    expect(await repoB.workspaceMode(), 'member');
    final accounts = await b.query('accounts');
    expect(accounts.length, 1);
    expect(accounts.first['name'], 'عميل المجموعة');
    // إعدادات السحابة بنفس رابط المدير.
    final st = await repoB.settings();
    expect(st['cloudBackendUrl'], url);
    expect(st['cloudCode'], 'QA123');
    expect(st['cloudAutoSync'], '1');
    // جهاز العضو سُجّل في سجل الأجهزة السحابي.
    final ourId = st['sync.deviceId'];
    expect(
        cloud.store.keys.any((k) => k.contains('/roster/') &&
            k.contains(Uri.encodeComponent(ourId!))),
        isTrue);
    // الدعوة أُتلفت بعد الاستخدام (مرة واحدة فقط).
    expect(
        cloud.store.keys
            .any((k) => k.contains('/invites/${invite.token}')),
        isFalse);
  });

  test('QA-JOIN-02 invalid/used token rejected; member cannot invite',
      () async {
    final cloud = FakeCloudStore();
    final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    // رمز خاطئ.
    await expectLater(
        http.runWithClient(
            () => CloudJoin.join(repoB,
                backendUrl: url,
                token: 'WRONG123',
                workspaceId: invite.workspaceId),
            cloud.client),
        throwsA(isA<CloudJoinException>()));
    // انضمام صحيح ثم إعادة استخدام نفس الرمز من جهاز آخر → مرفوض.
    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: url,
            token: invite.token,
            workspaceId: invite.workspaceId),
        cloud.client);
    // العضو (repoB الآن عضو) لا يستطيع إنشاء دعوة.
    await expectLater(
        http.runWithClient(() => CloudJoin.createInvite(repoB), cloud.client),
        throwsA(isA<CloudJoinException>()));
    // ولا يستطيع الانضمام لمجموعة أخرى.
    await expectLater(
        http.runWithClient(
            () => CloudJoin.join(repoB,
                backendUrl: url,
                token: invite.token,
                workspaceId: invite.workspaceId),
            cloud.client),
        throwsA(isA<CloudJoinException>()));
  });
}
