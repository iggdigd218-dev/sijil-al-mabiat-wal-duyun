// QA — معمارية حساب Google وعزل المساحات بمعرف المستخدم (UID).
//
// العقود:
//  - أول دخول: المساحة الحالية تُرحَّل إلى WS-{uid} ويُسجَّل الربط سحابياً.
//  - حساب معروف (فهرس + نسخة): تُستعاد مساحته كاملة بالبيانات (recovered).
//  - جهاز عضو: لا يُمَس (memberUntouched).
//  - ensureWorkspace لمستخدم مسجل: مساحة جديدة = WS-{uid} لا عشوائية.
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

  test('ACCT-01 أول دخول: ترحيل المساحة إلى WS-{uid} + تسجيل الربط',
      () async {
    final store = <String, Object?>{};
    final before = repo.requireWorkspaceId;
    final outcome = await http.runWithClient(
        () => AccountWorkspace.adoptOrRecover(repo,
            backendUrl: url, account: account),
        () => fakeCloud(store));
    expect(outcome, AccountLinkOutcome.migrated);
    expect(repo.requireWorkspaceId, 'WS-${account.uid}');
    expect(repo.requireWorkspaceId, isNot(before));
    // الفهرس سُجِّل.
    final idx = store[
        '/workspaces/_registry/accounts_index/${account.uid}.json'] as Map?;
    expect(idx, isNotNull);
    expect(idx!['workspaceId'], 'WS-${account.uid}');
    // الجلسة حُفظت محلياً (Offline-First).
    expect(await FirebaseAuthRest.savedUid(repo), account.uid);
    expect(await FirebaseAuthRest.savedEmail(repo), account.email);
  });

  test('ACCT-02 حساب معروف: استرداد المساحة المسجلة كاملة بالبيانات',
      () async {
    const orgWs = 'WS-${'Uabc123XYZ'}';
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
        () => AccountWorkspace.adoptOrRecover(repo,
            backendUrl: url, account: account),
        () => fakeCloud(store));
    expect(outcome, AccountLinkOutcome.recovered);
    expect(repo.requireWorkspaceId, orgWs);
    final accounts = await repo.accounts();
    expect(accounts.any((a) => a.name == 'عميل مؤسسة الحساب'), isTrue);
  });

  test('ACCT-03 جهاز عضو مجموعة لا يُمَس', () async {
    await db.insert(
        'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final before = repo.requireWorkspaceId;
    final store = <String, Object?>{};
    final outcome = await http.runWithClient(
        () => AccountWorkspace.adoptOrRecover(repo,
            backendUrl: url, account: account),
        () => fakeCloud(store));
    expect(outcome, AccountLinkOutcome.memberUntouched);
    expect(repo.requireWorkspaceId, before);
    expect(store, isEmpty, reason: 'لا كتابات سحابية لجهاز العضو');
  });

  test('ACCT-04 ensureWorkspace: مستخدم مسجل يحصل على WS-{uid}', () async {
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
    expect(ws, 'WS-${account.uid}');
    await db2.close();
    await tmp2.delete(recursive: true);
  });
}
