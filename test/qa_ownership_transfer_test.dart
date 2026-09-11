// انحدار لنقل الملكية: بعد تسليم المدير إدارته لجهاز آخر يجب أن
// 1) يصبح الجهاز المستهدف مالكًا (is_owner=1) وله مستخدم بدور مدير،
// 2) يفقد جهاز المدير السابق صلاحية المدير (يصبح عضوًا)،
// 3) لا يفقد الجهاز المستهدف صلاحيته (الخلل القديم: العكس).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';

void main() {
  late Database db;
  late Directory tmp;

  setUp(() async {
    sqfliteFfiInit();
    tmp = await Directory.systemTemp.createTemp('nexora_own_');
    db = await databaseFactoryFfi.openDatabase(p.join(tmp.path, 'own.db'),
        options: OpenDatabaseOptions(
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        ));
    await AppDatabase.createSchema(db);
    AppDatabase.overrideForTest(db);
    // وضع مستقل يملكه الجهاز A.
    await db.insert('sync_meta',
        {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('نقل الملكية يجعل الجهاز B مديرًا فعليًا و A عضوًا', () async {
    final repoA = Repo();
    await repoA.initSyncInfra();
    final idA = repoA.requireDeviceId;

    // جهاز B مقترن كعضو بلا مستخدم/صلاحيات.
    final now = DateTime.now().toIso8601String();
    await db.insert('devices', {
      'id': 'DEV-B',
      'workspace_id': 'default',
      'name': 'جهاز ب',
      'platform': 'android',
      'is_owner': 0,
      'is_paired': 1,
      'auth_secret': 'secret-b',
      'created_at': now,
      'updated_at': now,
    });

    // A ينقل الملكية لـ B.
    await repoA.transferOwnership('DEV-B');

    // B صار مالكًا.
    final bdev = (await db.query('devices',
        where: 'id = ?', whereArgs: ['DEV-B'])).first;
    expect(bdev['is_owner'], 1);
    expect(bdev['user_id'], isNotNull);

    // A لم يعد مالكًا.
    final adev = (await db.query('devices',
        where: 'id = ?', whereArgs: [idA])).first;
    expect(adev['is_owner'], 0);

    // المستخدم المرتبط بـ B مدير وله صلاحيات كاملة.
    final buid = bdev['user_id'] as int;
    final buser = AppUser.fromMap(
        (await db.query('users', where: 'id = ?', whereArgs: [buid])).first);
    expect(buser.role, UserRole.admin);
    expect(buser.can('manage_users'), isTrue);
    expect(buser.can('add_tx'), isTrue);
  });
}
