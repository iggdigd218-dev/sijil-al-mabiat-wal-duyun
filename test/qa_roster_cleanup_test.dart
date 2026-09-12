// QA — التطهير الذاتي لسجل الأجهزة السحابي (نظافة السجل).
//
// سجل المدير المحلي هو مصدر الحقيقة: أي مدخل roster سحابي غير معروف
// محلياً هو جهاز دخيل يُحذف تلقائياً (مع شاهدة طرد إن كان نشطاً)،
// مع مهلة سماح 15 دقيقة للمداخل حديثة الإنشاء وعدم المساس بجهازنا.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-roster.europe-west1.firebasedatabase.app';

  setUp(() async {
    debugForceLegacyWorkspaceId = true;
    tmp = await Directory.systemTemp.createTemp('nexora_roster_');
    db = await databaseFactory.openDatabase('${tmp.path}/r.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  tearDown(() async {
    debugForceLegacyWorkspaceId = false;
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('ROSTER-CLEAN-01 الدخلاء يُحذفون والمعروفون وجهازنا يبقون', () async {
    final ourId = repo.requireDeviceId;
    // عضو شرعي معروف محلياً.
    final now = DateTime.now().toIso8601String();
    await db.insert('devices', {
      'id': 'DEVICE-MEMBER1',
      'workspace_id': repo.requireWorkspaceId,
      'name': 'عضو شرعي',
      'platform': 'android',
      'is_paired': 1,
      'is_owner': 0,
      'revoked_at': '',
      'created_at': now,
      'updated_at': now,
    });
    final old =
        DateTime.now().subtract(const Duration(hours: 5)).toIso8601String();
    final store = <String, Object?>{
      '/workspaces/default/roster.json': {
        ourId: {'id': ourId, 'is_owner': 1, 'created_at': old},
        'DEVICE-MEMBER1': {
          'id': 'DEVICE-MEMBER1',
          'is_owner': 0,
          'created_at': old,
        },
        // دخيل نشط (تثبيت قديم سجّل نفسه مالكاً في المساحة المشتركة).
        'DEVICE-INTRUDER': {
          'id': 'DEVICE-INTRUDER',
          'is_owner': 1,
          'revoked_at': '',
          'created_at': old,
        },
        // بقايا مطرود قديم (لديه شاهدته أصلاً).
        'DEVICE-EXPELLED': {
          'id': 'DEVICE-EXPELLED',
          'is_owner': 1,
          'revoked_at': old,
          'created_at': old,
        },
        // مدخل حديث جداً — مهلة سماح (موافقة انضمام في الطريق).
        'DEVICE-FRESH': {
          'id': 'DEVICE-FRESH',
          'is_owner': 0,
          'created_at': DateTime.now().toIso8601String(),
        },
      },
    };
    final deleted = <String>[];
    final puts = <String, Object?>{};
    final client = MockClient((req) async {
      final p = req.url.path;
      if (req.method == 'DELETE') {
        deleted.add(p);
        return http.Response.bytes(utf8.encode('null'), 200);
      }
      if (req.method == 'PUT') {
        puts[p] = jsonDecode(req.body);
        return http.Response.bytes(utf8.encode(req.body), 200);
      }
      final v = store[p];
      return http.Response.bytes(
          utf8.encode(jsonEncode(v)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

    final pruned = await http.runWithClient(
        () => CloudJoin.pruneForeignRosterEntries(repo,
            backendUrl: url, workspaceId: 'default'),
        () => client);

    expect(pruned, 2, reason: 'الدخيل والمطرود القديم فقط');
    expect(deleted.any((p) => p.contains('roster/DEVICE-INTRUDER')), isTrue);
    expect(deleted.any((p) => p.contains('roster/DEVICE-EXPELLED')), isTrue);
    // جهازنا والعضو الشرعي والمدخل الحديث لم يُمسوا.
    expect(deleted.any((p) => p.contains(ourId)), isFalse);
    expect(deleted.any((p) => p.contains('DEVICE-MEMBER1')), isFalse);
    expect(deleted.any((p) => p.contains('DEVICE-FRESH')), isFalse);
    // شاهدة طرد للدخيل النشط فقط (المطرود لديه شاهدته).
    expect(puts.keys.any((p) => p.contains('evictions/DEVICE-INTRUDER')),
        isTrue);
    expect(puts.keys.any((p) => p.contains('evictions/DEVICE-EXPELLED')),
        isFalse);
    final tomb =
        puts.entries.firstWhere((e) => e.key.contains('DEVICE-INTRUDER'));
    expect((tomb.value as Map)['reason'], 'foreign_roster_cleanup');
  });

  test('ROSTER-CLEAN-02 سجل سليم ⇒ لا حذف إطلاقاً', () async {
    final ourId = repo.requireDeviceId;
    final old =
        DateTime.now().subtract(const Duration(days: 2)).toIso8601String();
    final store = <String, Object?>{
      '/workspaces/default/roster.json': {
        ourId: {'id': ourId, 'is_owner': 1, 'created_at': old},
      },
    };
    final deleted = <String>[];
    final client = MockClient((req) async {
      if (req.method == 'DELETE') {
        deleted.add(req.url.path);
        return http.Response.bytes(utf8.encode('null'), 200);
      }
      return http.Response.bytes(
          utf8.encode(jsonEncode(store[req.url.path])), 200);
    });
    final pruned = await http.runWithClient(
        () => CloudJoin.pruneForeignRosterEntries(repo,
            backendUrl: url, workspaceId: 'default'),
        () => client);
    expect(pruned, 0);
    expect(deleted, isEmpty);
  });
}
