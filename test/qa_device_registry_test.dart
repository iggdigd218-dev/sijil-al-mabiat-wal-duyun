// QA — استرداد بصمة العتاد (Hardware-Bound Workspace Recovery).
//
// device_index: بصمة الجهاز ← {workspaceId, role}. العقود:
//  - lookup يقرأ السجل؛ upsertBinding يسجل owner للمستقل.
//  - سجل owner قائم لا يُخفَّض ولا تُبدَّل مساحته إلا بـ force (تنازل صريح).
//  - bindAsMember لا يسجل مدير مؤسسة أخرى عضواً في مجموعة غريبة.
//  - الاسترداد الصامت: تثبيت نظيف + سجل owner ⇒ استعادة المساحة والنسخة.
//  - manualRestore: رمز مساحة صحيح ⇒ استعادة كاملة؛ خاطئ ⇒ false.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/device_registry.dart';
import 'package:nexora_app/data/sync/workspace_recovery.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-registry.europe-west1.firebasedatabase.app';

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    debugDefaultBackendUrlOverride = url;
    tmp = await Directory.systemTemp.createTemp('nexora_registry_');
    db = await databaseFactory.openDatabase('${tmp.path}/reg.db',
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

  MockClient fakeCloud(Map<String, Object?> store,
      {List<String>? putLog}) =>
      MockClient((req) async {
        final p = req.url.path;
        if (req.method == 'PUT') {
          store[p] = jsonDecode(req.body);
          putLog?.add(p);
          return http.Response.bytes(utf8.encode(req.body), 200);
        }
        if (req.method == 'DELETE') {
          store.remove(p);
          return http.Response.bytes(utf8.encode('null'), 200);
        }
        return http.Response.bytes(
            utf8.encode(jsonEncode(store[p])), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });

  test('REG-01 upsertBinding يسجل المستقل مالكاً لمساحته', () async {
    final store = <String, Object?>{};
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo, backendUrl: url),
        () => fakeCloud(store));
    final fp = await DeviceRegistry.fingerprintKey(repo);
    final rec = store['/device_index/$fp.json'] as Map?;
    expect(rec, isNotNull);
    expect(rec!['workspaceId'], repo.requireWorkspaceId);
    expect(rec['role'], 'owner');
  });

  test('REG-02 سجل owner قائم لا يُخفَّض لمساحة أخرى بلا force', () async {
    final fp = await DeviceRegistry.fingerprintKey(repo);
    final store = <String, Object?>{
      '/device_index/$fp.json': {
        'workspaceId': 'WS-OLDFIRM1',
        'role': 'owner',
        'device_id': 'OLD-DEV',
      },
    };
    // بلا force: الربط الحالي (مساحة مختلفة) يُرفض — السجل القديم يبقى.
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo, backendUrl: url),
        () => fakeCloud(store));
    var rec = store['/device_index/$fp.json'] as Map;
    expect(rec['workspaceId'], 'WS-OLDFIRM1');
    // بـ force (تنازل صريح): يُحدَّث.
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo,
            backendUrl: url, force: true),
        () => fakeCloud(store));
    rec = store['/device_index/$fp.json'] as Map;
    expect(rec['workspaceId'], repo.requireWorkspaceId);
  });

  test('REG-03 مدير مؤسسة أخرى لا يُسجَّل عضواً في مجموعة غريبة', () async {
    final fp = await DeviceRegistry.fingerprintKey(repo);
    final store = <String, Object?>{
      '/device_index/$fp.json': {
        'workspaceId': 'WS-OLDFIRM1',
        'role': 'owner',
        'device_id': 'OLD-DEV',
      },
    };
    await http.runWithClient(
        () => DeviceRegistry.bindAsMember(repo,
            backendUrl: url, workspaceId: 'WS-OTHERGRP'),
        () => fakeCloud(store));
    final rec = store['/device_index/$fp.json'] as Map;
    expect(rec['role'], 'owner', reason: 'حق المدير في مؤسسته محفوظ');
    expect(rec['workspaceId'], 'WS-OLDFIRM1');
  });

  test('REG-04 الاسترداد الصامت: تثبيت نظيف يستعيد مساحة المالك ونسخته',
      () async {
    final fp = await DeviceRegistry.fingerprintKey(repo);
    const oldWs = 'WS-MYFIRM99';
    final backupPayload = {
      'app': 'nexora',
      'format': 'nexora-backup',
      'db_version': 1,
      'created_at': DateTime.now().toIso8601String(),
      'group_fingerprint': '',
      'workspace_mode': 'standalone',
      'data': {
        'accounts': [
          {
            'id': 77,
            'workspace_id': oldWs,
            'name': 'عميل المؤسسة المستعادة',
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
    };
    final store = <String, Object?>{
      '/device_index/$fp.json': {
        'workspaceId': oldWs,
        'role': 'owner',
        'device_id': 'OLD-DEV',
      },
      '/workspaces/$oldWs/backup.json': {
        'payload': backupPayload,
      },
    };
    final recovered = await http.runWithClient(
        () => WorkspaceRecovery.attemptSilentRecovery(repo),
        () => fakeCloud(store));
    expect(recovered, isTrue);
    expect(repo.requireWorkspaceId, oldWs);
    final accounts = await repo.accounts();
    expect(accounts.any((a) => a.name == 'عميل المؤسسة المستعادة'), isTrue);
    // الفحص لا يتكرر في الإقلاع التالي.
    final again = await http.runWithClient(
        () => WorkspaceRecovery.attemptSilentRecovery(repo),
        () => fakeCloud(store));
    expect(again, isFalse);
  });

  test('REG-05 manualRestore: رمز صحيح يستعيد، خاطئ يعيد false', () async {
    const oldWs = 'WS-MANUAL77';
    final store = <String, Object?>{
      '/workspaces/$oldWs/backup.json': {
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
                'id': 5,
                'workspace_id': oldWs,
                'name': 'حساب يدوي مستعاد',
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
    final bad = await http.runWithClient(
        () => WorkspaceRecovery.manualRestore(repo,
            backendUrl: url, workspaceId: 'WS-WRONG123'),
        () => fakeCloud(store));
    expect(bad, isFalse);
    final ok = await http.runWithClient(
        () => WorkspaceRecovery.manualRestore(repo,
            backendUrl: url, workspaceId: oldWs),
        () => fakeCloud(store));
    expect(ok, isTrue);
    expect(repo.requireWorkspaceId, oldWs);
    final accounts = await repo.accounts();
    expect(accounts.any((a) => a.name == 'حساب يدوي مستعاد'), isTrue);
  });
}
