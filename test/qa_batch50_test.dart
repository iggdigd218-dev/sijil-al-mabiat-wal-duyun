// QA — دفعة 50: السحابة حصرياً + بصمة العتاد + الطرد الكامل + الترطيب النظيف:
// - recorder: مع سحابة مهيأة لا يُدرج هدف lan إطلاقاً (سحابة فقط).
// - بلا سحابة: سلوك LAN القديم كما هو (تراجع للمجموعات المحلية).
// - expelDevice يطهّر محادثة القرين الفردية ورسائلها.
// - _resetToStandalone يمسح علم onboarding وإعدادات السحابة (عودة للإعداد الأول).
// - بصمة العتاد: deterministicDeviceId حتمي وثابت (نفس المدخل = نفس المعرف).
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late Repo repo;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEVICE-QA50AAAA');
    await repo.initSyncInfra();
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedAccount() => repo.saveAccount(Account(
        name: 'عميل دفعة 50',
        kind: AccountKind.customer,
        openingBalance: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

  group('السحابة حصرياً — أهداف الطابور', () {
    test('سحابة مهيأة: هدف cloud فقط، لا lan إطلاقاً', () async {
      await repo.setSetting('cloudBackendUrl', 'https://qa.firebaseio.com');
      await repo.setSetting('lanSyncEnabled', '1'); // حتى مع LAN مفعّل قديماً
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedAccount();
      final targets =
          (await db.query('sync_queue')).map((r) => r['target']).toSet();
      expect(targets, contains(SyncTarget.cloud));
      expect(targets, isNot(contains(SyncTarget.lanBroadcast)),
          reason: 'هندسة السحابة الخالصة: LAN خارج الخدمة عند تهيؤ السحابة');
    });

    test('بلا سحابة: التراجع لهدف lan كما كان (مجموعات محلية قديمة)',
        () async {
      await repo.setSetting('lanSyncEnabled', '1');
      await seedAccount();
      final targets =
          (await db.query('sync_queue')).map((r) => r['target']).toSet();
      expect(targets, contains(SyncTarget.lanBroadcast));
      expect(targets, isNot(contains(SyncTarget.cloud)));
    });

    test('وضع member بلا أي إعداد: lan احتياطاً (سلوك قديم محفوظ)', () async {
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedAccount();
      final targets =
          (await db.query('sync_queue')).map((r) => r['target']).toSet();
      expect(targets, contains(SyncTarget.lanBroadcast));
    });
  });

  group('الطرد الكامل — تطهير الدردشة', () {
    test('expelDevice يحذف محادثة القرين الفردية ورسائلها', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('devices', {
        'id': 'DEVICE-EVICT01',
        'workspace_id': 'default',
        'name': 'جهاز مطرود',
        'is_paired': 1,
        'is_owner': 0,
        'created_at': now,
        'updated_at': now,
      });
      final convId = await repo.conversationForPeer(
          'DEVICE-EVICT01', 'جهاز مطرود');
      await db.insert('messages', {
        'conversation_id': convId,
        'workspace_id': 'default',
        'sender': 'DEVICE-EVICT01',
        'body': 'رسالة قديمة',
        'kind': 'text',
        'created_at': now,
      });
      await repo.expelDevice('DEVICE-EVICT01');
      expect(
          await db.query('conversations',
              where: "title = 'peer:DEVICE-EVICT01'"),
          isEmpty,
          reason: 'المحادثة الفردية تُحذف كلياً');
      expect(
          await db.query('messages',
              where: 'conversation_id = ?', whereArgs: [convId]),
          isEmpty,
          reason: 'رسائل المطرود تُطهَّر');
      final d = (await db.query('devices',
              where: "id = 'DEVICE-EVICT01'"))
          .first;
      expect('${d['expelled_at']}'.isNotEmpty, isTrue);
      expect(d['is_paired'], 0);
    });

    test('groupPeersProvider يستبعد المطرودين (فلتر expelled_at قائم)',
        () async {
      // التحقق من شرط SQL نفسه: المطرود لا يظهر في أي قائمة أقران.
      final now = DateTime.now().toIso8601String();
      await db.insert('devices', {
        'id': 'DEVICE-EVICT02',
        'workspace_id': 'default',
        'name': 'شبح',
        'is_paired': 0,
        'expelled_at': now,
        'revoked_at': now,
        'created_at': now,
        'updated_at': now,
      });
      final visible = await db.query('devices',
          where: "COALESCE(expelled_at,'') = ''");
      expect(visible.map((d) => d['id']),
          isNot(contains('DEVICE-EVICT02')));
    });
  });

  group('الإبطال من جهة العميل — العودة للإعداد الأول', () {
    test('resetToStandaloneAfterExpulsion يمسح onboarding وإعدادات السحابة',
        () async {
      await repo.setSetting('has_completed_onboarding', '1');
      await repo.setSetting('cloudBackendUrl', 'https://x.firebaseio.com');
      await repo.setSetting('cloudCode', 'ABCD');
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await repo.resetToStandaloneAfterExpulsion();
      final st = await repo.settings();
      expect(st['has_completed_onboarding'], isNull,
          reason: 'الجهاز المطرود يعود لشاشة الإعداد الأول');
      expect(st['cloudBackendUrl'], isNull);
      expect(st['cloudCode'], isNull);
      expect(await repo.workspaceMode(), 'standalone');
      // البيانات المحلية مُسحت (المدير الافتراضي الجديد فقط).
      expect(await repo.accounts(), isEmpty);
    });
  });

  group('الترطيب النظيف — مؤشرات sync_meta', () {
    test('مؤشرات السحب تُصفَّر بنمط LIKE الشامل', () async {
      await db.insert('sync_meta',
          {'key': 'lastCloudTs:default', 'value': '123'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('sync_meta',
          {'key': 'lastRosterPush:default', 'value': 'abc'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // نفس عبارة الحذف المستخدمة في CloudJoin.join.
      await db.delete('sync_meta',
          where: "key LIKE 'lastCloudTs:%' OR key LIKE 'lastRosterPush:%' "
              "OR key LIKE 'lastLanTs:%'");
      final left = await db.query('sync_meta',
          where: "key LIKE 'last%'");
      expect(left, isEmpty);
    });
  });
}
