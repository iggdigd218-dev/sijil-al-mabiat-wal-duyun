// ═══════════════════════════════════════════════════════════════════════
// LIVE-SYNC E2E — تشغيل المشروع فعلياً في البيئة المحلية ضد السحابة
// الحقيقية (Firebase RTDB nexora-ledger):
//   • مدير وعضو على قاعدتين محليتين منفصلتين بجهازيين مختلفين.
//   • انضمام حقيقي عبر دعوة سحابية حقيقية.
//   • محركا مزامنة حقيقيان يعملان معاً: عمليات المدير→العضو والعضو→المدير.
//   • مستخدم/صلاحيات ورسالة محادثة مجموعة تعبر السحابة فعلياً.
//   • حل المجموعة حقيقياً: محرك العضو يحرر نفسه خلال ~30-45 ثانية
//     (لا أعضاء عالقون) وبياناته تبقى له وبقاياه تُمسح من السحابة.
// يعمل فقط مع: --dart-define=LIVE_SYNC_E2E=1 --dart-define=
// NEXORA_FIREBASE_API_KEY=‹مفتاح› — وفي CI يُتجاوز تلقائياً.
// ═══════════════════════════════════════════════════════════════════════
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/device_registry.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const bool _live = bool.fromEnvironment('LIVE_SYNC_E2E');
const String _rtdb =
    'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app';

/// ينتظر تحقق شرط بالاستطلاع — يرمي StateError عند انتهاء المهلة.
Future<T> _waitFor<T>(
  Future<T> Function() probe,
  bool Function(T) ok, {
  String what = 'شرط',
  int seconds = 90,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  Object? lastErr;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final v = await probe();
      if (ok(v)) return v;
    } catch (e) {
      lastErr = e;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError('انتهت مهلة $seconds ثانية بانتظار: $what'
      '${lastErr == null ? '' : ' — آخر خطأ: $lastErr'}');
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const skip = _live
      ? null
      : 'اختبار حي ضد السحابة الحقيقية — يتطلب '
          '--dart-define=LIVE_SYNC_E2E=1 (يُتجاوز في CI)';
  const t3 = Timeout(Duration(minutes: 3));
  const t5 = Timeout(Duration(minutes: 5));

  late Directory tmp;
  late Database dbA; // قاعدة المدير
  late Database dbB; // قاعدة العضو
  late Repo repoA;
  late Repo repoB;
  late SyncEngine engineA;
  late SyncEngine engineB;
  late String devA;
  late String devB;
  String wsId = '';
  final sfx = Random().nextInt(1 << 30).toRadixString(36).toUpperCase();

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_live_');
    Future<Database> open(String n) => databaseFactory.openDatabase(
        '${tmp.path}/$n.db',
        options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    dbA = await open('mgr');
    dbB = await open('mem');
    await AppDatabase.createSchema(dbA);
    await AppDatabase.createSchema(dbB);
    repoA = Repo(databaseProvider: () async => dbA);
    repoB = Repo(databaseProvider: () async => dbB);
    // جهازان مختلفان صراحةً (بصمة العتاد في بيئة الاختبار واحدة).
    devA = 'DEVICE-LIVEA-$sfx';
    devB = 'DEVICE-LIVEB-$sfx';
    await repoA.setSetting('sync.deviceId', devA);
    await repoB.setSetting('sync.deviceId', devB);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await repoA.setSetting('cloudBackendUrl', _rtdb);
    await repoA.setSetting('cloudCode', 'LIVE1');
    // هوية مجهولة حقيقية من Firebase — كل الطلبات موقعة (?auth=).
    await FirebaseAuthRest.initSilentAuth(repoA);
    final tok = await FirebaseAuthRest.cloudIdToken();
    if (tok == null || tok.isEmpty) {
      throw StateError('تعذر إنشاء هوية سحابية حقيقية — تحقق من مفتاح '
          'NEXORA_FIREBASE_API_KEY والاتصال');
    }
  });

  tearDownAll(() async {
    try {
      engineA.stop();
    } catch (_) {}
    try {
      engineB.stop();
    } catch (_) {}
    // تنظيف السحابة من كل آثار هذه الجولة — المساحة كاملة (بلا استثناءات).
    try {
      final tok = await FirebaseAuthRest.cloudIdToken() ?? '';
      if (wsId.isNotEmpty) {
        await http.delete(Uri.parse(
            '$_rtdb/workspaces/${Uri.encodeComponent(wsId)}.json?auth=$tok'));
      }
      final fp = await DeviceRegistry.fingerprintKey(repoA);
      if (fp.isNotEmpty) {
        await http.delete(Uri.parse(
            '$_rtdb/device_index/${Uri.encodeComponent(fp)}.json?auth=$tok'));
      }
    } catch (_) {}
    if (dbA.isOpen) await dbA.close();
    if (dbB.isOpen) await dbB.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('LIVE-01 انضمام حقيقي: دعوة من المدير وعضو يتبناها عبر السحابة',
      () async {
    final now = DateTime.now();
    // بيانات المدير التي يجب أن تصل للعضو مع اللقطة.
    await repoA.saveAccount(Account(
      name: 'عميل حي من المدير $sfx',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await repoA.setSetting('businessName', 'مؤسسة المزامنة الحية $sfx');

    final invite = await CloudJoin.createInvite(repoA);
    wsId = invite.workspaceId;
    expect(invite.token, isNotEmpty);
    expect(invite.backendUrl, _rtdb);

    await CloudJoin.join(repoB,
        backendUrl: invite.backendUrl,
        token: invite.token,
        workspaceId: invite.workspaceId,
        cloudCode: invite.cloudCode);

    expect(await repoB.workspaceMode(), 'member',
        reason: 'العضو ارتبط بالمجموعة فعلياً');
    // (قفل جذر كارثة المزامنة 2026-09-19) جدول مساحات العضو يحمل مساحة
    // المجموعة وحدها — أي صف مساحة شخصية قديمة يخطف النقل فيميت المزامنة.
    final wsRowsB = await dbB.query('workspaces');
    expect(wsRowsB.length, 1,
        reason: 'صف المساحة الشخصية القديمة يجب أن يُحذف عند الانضمام');
    expect(wsRowsB.first['id'], invite.workspaceId);
    expect((await repoB.settings())['sync.workspaceId'], invite.workspaceId,
        reason: 'الربط الصريح مثبَّت على مساحة المجموعة');
    final accts = await dbB.query('accounts',
        where: 'name = ?', whereArgs: ['عميل حي من المدير $sfx']);
    expect(accts, isNotEmpty,
        reason: 'لقطة المجموعة وصلت العضو من السحابة الحقيقية');
    final st = await repoB.settings();
    expect(st['businessName'], 'مؤسسة المزامنة الحية $sfx');
    expect(st['cloudBackendUrl'], _rtdb,
        reason: 'العضو مربوط بنفس عقدة سحابة المدير');
    expect(st['sync.deviceId'], devB);
  }, timeout: t3, skip: skip);

  test('LIVE-02 محركان حقيقيان: عملية المدير تصل العضو عبر السحابة', () async {
    engineA = SyncEngine(repo: repoA, dbProvider: () async => dbA);
    engineB = SyncEngine(repo: repoB, dbProvider: () async => dbB);
    await engineA.start();
    await engineB.start();

    final mark = 'مدير إلى عضو $sfx';
    final now = DateTime.now();
    await repoA.saveAccount(Account(
      name: mark,
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await _waitFor(
      () => dbB.query('accounts', where: 'name = ?', whereArgs: [mark]),
      (rows) => rows.isNotEmpty,
      what: 'وصول عملية المدير إلى قاعدة العضو',
    );
  }, timeout: t5, skip: skip);

  test('LIVE-03 الصلاحيات تعبر السحابة: المدير يعيّن دوراً لجهاز العضو '
      'وعملية العضو تصل المدير (اتجاه عكسي)', () async {
    // العضو بلا تعيين = بلا صلاحيات إطلاقاً (fail-closed) — المدير يعيّن
    // له دور المحاسب عبر نفس قنوات السحابة التي يستخدمها التطبيق.
    await _waitFor(
      () => dbA.query('devices', where: 'id = ?', whereArgs: [devB]),
      (rows) => rows.isNotEmpty,
      what: 'ظهور جهاز العضو عند المدير عبر مصالحة roster',
    );
    final perms = defaultPerms(UserRole.accountant)
        .entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toSet();
    await repoA.setDevicePermissions(devB, UserRole.accountant, perms);
    await _waitFor(
      () => repoB.deviceAssignedUser(),
      (u) => u != null && u.active,
      what: 'وصول تعيين الصلاحيات إلى جهاز العضو',
    );

    final mark = 'عضو إلى مدير $sfx';
    final now = DateTime.now();
    await repoB.saveAccount(Account(
      name: mark,
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await _waitFor(
      () => dbA.query('accounts', where: 'name = ?', whereArgs: [mark]),
      (rows) => rows.isNotEmpty,
      what: 'وصول عملية العضو إلى قاعدة المدير',
    );
  }, timeout: t5, skip: skip);

  test('LIVE-04 المستخدم/الصلاحيات تتزامن: دور جديد ثم تعديل يصل العضو',
      () async {
    final name = 'محاسب حي $sfx';
    final u = AppUser(
      name: name,
      role: UserRole.accountant,
      permissions: defaultPerms(UserRole.accountant),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final id = await repoA.saveUser(u);
    await _waitFor(
      () => dbB.query('users', where: 'name = ?', whereArgs: [name]),
      (rows) => rows.isNotEmpty && rows.first['role'] == 'accountant',
      what: 'وصول المستخدم وصلاحياته إلى العضو',
    );
    // تعديل الدور يعبر السحابة هو الآخر.
    await repoA.saveUser(u.copyWith(
      id: id,
      role: UserRole.agent,
      permissions: defaultPerms(UserRole.agent),
      updatedAt: DateTime.now(),
    ));
    await _waitFor(
      () => dbB.query('users', where: 'name = ?', whereArgs: [name]),
      (rows) => rows.isNotEmpty && rows.first['role'] == 'agent',
      what: 'وصول تعديل الدور إلى العضو',
    );
  }, timeout: t5, skip: skip);

  test('LIVE-05 محادثة المجموعة: رسالة المدير تصل العضو فعلياً', () async {
    final body = 'رسالة حية $sfx';
    await repoA.sendGroupMessage(body);
    await _waitFor(
      () async =>
          (await repoB.groupMessages()).where((m) => m.body == body).length,
      (n) => n >= 1,
      what: 'وصول رسالة المحادثة إلى العضو',
    );
  }, timeout: t5, skip: skip);

  test('LIVE-06 الحل الحقيقي: محرك العضو يحرر نفسه وبياناته تبقى له '
      'وبقاياه تُمسح — لا عالقون', () async {
    await CloudJoin.dissolveGroup(repoA,
        backendUrl: _rtdb, workspaceId: wsId);

    // المحرك الحقيقي للعضو (دورة كل ~5 ثوانٍ، حكم بعد 6 تأكيدات ~30 ثانية).
    await _waitFor(
      () => repoB.workspaceMode(),
      (m) => m != 'member',
      what: 'تحرر العضو التلقائي بعد حل المجموعة',
      seconds: 120,
    );
    expect(await repoB.workspaceMode(), 'standalone');

    // بيانات العضو كلها بقيت له.
    final rows = await dbB.query('accounts', where: 'name LIKE ?',
        whereArgs: ['%$sfx%']);
    expect(rows, isNotEmpty, reason: 'بيانات المحرَّر لا تضيع');
    final dev = await dbB.query('devices',
        where: 'id = ? AND COALESCE(is_owner,0) = 1', whereArgs: [devB]);
    expect(dev, isNotEmpty, reason: 'جهازه صار مالكاً لحسابه الفردي');

    // بقاياه السحابية مُسحت: لا قيد roster ولا طلب معلق.
    final tok = await FirebaseAuthRest.cloudIdToken() ?? '';
    Future<String> read(String p) async {
      final r = await http
          .get(Uri.parse('$_rtdb/$p?auth=$tok'))
          .timeout(const Duration(seconds: 20));
      return r.body.trim();
    }

    expect(await read('workspaces/$wsId/roster.json'), 'null',
        reason: 'roster المجموعة زالت بالحل');
    expect(
        await read(
            'workspaces/$wsId/joinRequests/${Uri.encodeComponent(devB)}.json'),
        'null',
        reason: 'طلب العضو المعلق مُسح عند التحرير');
  }, timeout: t5, skip: skip);
}
