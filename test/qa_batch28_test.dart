// QA — دفعة 28:
// - دور «وكيل المدير» agent: كل الصلاحيات افتراضياً، ولا يمكن منح admin عبر
//   setDevicePermissions.
// - قفل تهيئة المجموعة شهراً (groupWipeAvailableAt).
// - wipeGroupData يمسح بيانات الأعمال ويبقي المستخدمين والإعدادات والأجهزة.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  var dbSeq = 0;

  Future<Repo> makeRepo() async {
    // مسار مؤقت فريد لكل اختبار: openDatabase يعيد نفس القاعدة لنفس المسار،
    // فمشاركة inMemoryDatabasePath كانت تسرّب حالة اختبار لآخر.
    final dir = await Directory.systemTemp.createTemp('nexora_b28_');
    final db = await databaseFactory
        .openDatabase('${dir.path}/qa_${dbSeq++}.db');
    await AppDatabase.createSchema(db);
    final repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    return repo;
  }

  test('QA-B28-01 agent role has all permissions by default', () {
    final perms = defaultPerms(UserRole.agent);
    for (final p in kPerms) {
      expect(perms[p.key], isTrue, reason: 'agent يجب أن يملك ${p.key}');
    }
    // fromCode يتعرف على agent.
    expect(UserRole.fromCode('agent'), UserRole.agent);
    // can() للوكيل يعتمد على permissions الممنوحة (ليس تجاوزاً كالمدير).
    final u = AppUser(
      name: 'وكيل',
      role: UserRole.agent,
      permissions: defaultPerms(UserRole.agent),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    expect(u.can('manage_users'), isTrue);
  });

  test('QA-B28-02 wipe lock: month-long cooldown', () async {
    final repo = await makeRepo();
    // لم تحدث تهيئة من قبل: متاحة.
    expect(await repo.groupWipeAvailableAt(), isNull);
    // تهيئة الآن (وضع standalone: مسموح للمالك).
    await repo.wipeGroupData();
    // مقفلة الآن حتى بعد 30 يوماً.
    final next = await repo.groupWipeAvailableAt();
    expect(next, isNotNull);
    expect(next!.isAfter(DateTime.now().add(const Duration(days: 29))), isTrue);
    // محاولة ثانية تفشل.
    expect(() => repo.wipeGroupData(), throwsA(isA<StateError>()));
    // (قاعدة اختبار في الذاكرة — لا حاجة للإغلاق)
  });

  test('QA-B28-03 wipe clears business data, keeps users/settings/devices',
      () async {
    final repo = await makeRepo();
    final db = await repo.database;
    final now = DateTime.now().toIso8601String();
    // بيانات أعمال.
    await db.insert('accounts', {
      'workspace_id': 'default',
      'name': 'عميل',
      'kind': 'customer',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('activity', {
      'text': 'نشاط قديم',
      'ref_type': 'account',
      'ref_id': '1',
      'user_name': 'م',
      'created_at': now,
    });
    await repo.setSetting('orgName', 'مؤسستي');
    final usersBefore = (await db.query('users')).length;
    final devicesBefore = (await db.query('devices')).length;

    await repo.wipeGroupData();

    expect((await db.query('accounts')).length, 0);
    // سجل النشاط أُفرغ ثم سُجل فيه حدث التهيئة نفسه فقط.
    final act = await db.query('activity');
    expect(act.length, 1);
    expect(act.first['ref_type'], 'wipe');
    // المستخدمون والأجهزة والإعدادات لم تُمس.
    expect((await db.query('users')).length, usersBefore);
    expect((await db.query('devices')).length, devicesBefore);
    final st = await repo.settings();
    expect(st['orgName'], 'مؤسستي');
    // (قاعدة اختبار في الذاكرة — لا حاجة للإغلاق)
  });
}
