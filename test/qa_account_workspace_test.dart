// QA — معمارية حساب Google وعزل المساحات بمعرف المستخدم (UID).
//
// العقود:
//  - (3.61) أول دخول: الجلسة تُحفظ والفهرس السحابي يُسجَّل — بلا أي تغيير
//    على معرّف المساحة المحلي (لا WS-{uid} بعد اليوم).
//  - (3.61) حساب معروف بنسخة سحابية: لا استرداد تلقائي — القرار صريح فقط.
//  - جهاز عضو: لا يُمَس (memberUntouched).
//  - (استعادة 3.55) ensureWorkspace: معرّف عشوائي WS-XXXXXXXX دائماً —
//    مساحة العمل لا تُشتق من الحساب، وتسجيل الدخول لا يغيّرها أبداً.
//  - الترخيص يتبع الحساب: فهرس التجربة يُقرأ ببصمة uid لا بصمة العتاد.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/account_workspace.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-account.europe-west1.firebasedatabase.app';
  const account = FirebaseAccount(
      uid: 'Uabc123XYZ', email: 'boss@example.com', displayName: 'المدير');

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    debugDefaultBackendUrlOverride = url;
    tmp = await Directory.systemTemp.createTemp('nexora_account_');
    db = await databaseFactory.openDatabase('${tmp.path}/acct.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  tearDown(() async {
    debugDefaultBackendUrlOverride = null;
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  MockClient fakeCloud(Map<String, Object?> store) => MockClient((req) async {
        final p = req.url.path;
        if (req.method == 'PUT') {
          store[p] = jsonDecode(req.body);
          return http.Response.bytes(utf8.encode(req.body), 200);
        }
        if (req.method == 'DELETE') {
          store.remove(p);
          return http.Response.bytes(utf8.encode('null'), 200);
        }
        return http.Response.bytes(utf8.encode(jsonEncode(store[p])), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });

  test('ACCT-01 (3.61) أول دخول: جلسة + فهرس — والمساحة لا تتغير',
      () async {
    final store = <String, Object?>{};
    final before = repo.requireWorkspaceId;
    final outcome = await http.runWithClient(
        () => AccountWorkspace.linkAccountOnly(repo,
            backendUrl: url, account: account),
        () => fakeCloud(store));
    expect(outcome, AccountLinkOutcome.migrated);
    // (استعادة 3.55) معرّف المساحة لم يتغيّر — لا WS-{uid} بعد اليوم.
    expect(repo.requireWorkspaceId, before);
    expect(repo.requireWorkspaceId, isNot('WS-${account.uid}'));
    // الفهرس سُجِّل بمساحة الجهاز الحالية لا بمساحة مشتقة من الحساب.
    final idx = store[
        '/workspaces/_registry/accounts_index/${account.uid}.json'] as Map?;
    expect(idx, isNotNull);
    expect(idx!['workspaceId'], before);
    // الجلسة حُفظت محلياً (Offline-First).
    expect(await FirebaseAuthRest.savedUid(repo), account.uid);
    expect(await FirebaseAuthRest.savedEmail(repo), account.email);
  });

  test('ACCT-02 (3.61) حساب معروف بنسخة سحابية: لا استرداد تلقائي',
      () async {
    const orgWs = 'WS-${'Uabc123XYZ'}';
    final before = repo.requireWorkspaceId;
    final store = <String, Object?>{
      '/workspaces/_registry/accounts_index/${account.uid}.json': {
        'workspaceId': orgWs,
        'email': account.email,
      },
      '/workspaces/$orgWs/backup.json': {
        'payload': {
          'app': 'nexora',
          'format': 'nexora-backup',
          'db_version': 1,
          'created_at': DateTime.now().toIso8601String(),
          'group_fingerprint': '',
          'workspace_mode': 'standalone',
          'data': {
            'accounts': [
              {
                'id': 9,
                'workspace_id': orgWs,
                'name': 'عميل مؤسسة الحساب',
                'kind': 'customer',
                'phone': '',
                'notify_channel': 'none',
                'archived': 0,
                'deleted_at': '',
                'created_at': DateTime.now().toIso8601String(),
                'updated_at': DateTime.now().toIso8601String(),
              }
            ],
          },
        },
      },
    };
    final outcome = await http.runWithClient(
        () => AccountWorkspace.linkAccountOnly(repo,
            backendUrl: url, account: account),
        () => fakeCloud(store));
    expect(outcome, AccountLinkOutcome.migrated);
    expect(repo.requireWorkspaceId, before,
        reason: 'المساحة المحلية لا تُستبدل تلقائياً (سلوك 3.55 المستعاد)');
    final accounts = await repo.accounts();
    expect(accounts.any((a) => a.name == 'عميل مؤسسة الحساب'), isFalse,
        reason: 'الاسترداد التلقائي أُلغي في 3.61 — لا سحب لنسخة سحابية '
            'ولا مساس بالبيانات المحلية إلا بقرار صريح من المستخدم');
  });

  test('ACCT-03 جهاز عضو مجموعة لا يُمَس', () async {
    await db.insert(
        'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final before = repo.requireWorkspaceId;
    final store = <String, Object?>{};
    final outcome = await http.runWithClient(
        () => AccountWorkspace.linkAccountOnly(repo,
            backendUrl: url, account: account),
        () => fakeCloud(store));
    expect(outcome, AccountLinkOutcome.memberUntouched);
    expect(repo.requireWorkspaceId, before);
    expect(store, isEmpty, reason: 'لا كتابات سحابية لجهاز العضو');
  });

  test('ACCT-04 (استعادة 3.55) ensureWorkspace: معرّف عشوائي دائماً — '
      'لا علاقة له بحساب Google', () async {
    // جلسة محفوظة + قاعدة جديدة بلا صف workspaces.
    final tmp2 = await Directory.systemTemp.createTemp('nexora_account2_');
    final db2 = await databaseFactory.openDatabase('${tmp2.path}/w.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db2);
    await db2.insert('settings', {'key': 'account.uid', 'value': account.uid},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db2.delete('workspaces');
    final ws = await ensureWorkspace(db2);
    // (استعادة سلوك 3.55) هوية المساحة محلية وعشوائية — تسجيل الدخول لا
    // يعيد تسميتها أبداً، فلا ينكسر الربط بتعذّر الشبكة أو الرمز.
    expect(ws, startsWith('WS-'));
    expect(ws.length, 11); // 'WS-' + 8 خانات
    expect(ws, isNot('WS-${account.uid}'),
        reason: 'معرف المساحة مستقل عن الحساب تماماً (سلوك 3.55)');
    await db2.close();
    await tmp2.delete(recursive: true);
  });
}
