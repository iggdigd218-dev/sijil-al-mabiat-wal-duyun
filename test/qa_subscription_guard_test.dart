// 🔒 QA — محرك الفترة التجريبية (SubscriptionGuard):
// - التفعيل يحسب expires_at خادمياً = created_at + 24h بالضبط.
// - القرار بوقت الخادم حصراً: تقديم ساعة الهاتف لا يؤثر إطلاقاً.
// - منع التصفير: نفس البصمة العتادية تستأنف سجلها الأول حتى مع مساحة جديدة.
// - البوابة isBlocked: مفتوحة أثناء التجربة، مقفلة بعد الانتهاء،
//   ومفتوحة دائماً مع اشتراك مدفوع (active).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/subscription_guard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية تحاكي RTDB: تستبدل {".sv":"timestamp"} بساعة خادم قابلة
/// للتحكم — نقدّمها ونؤخرها في الاختبارات بمعزل تام عن ساعة الجهاز.
class _FakeRtdb {
  final Map<String, Object?> store = {};

  /// «ساعة الخادم» — نتحكم بها يدوياً في كل اختبار.
  int serverClock = 1770000000000; // نقطة صفر ثابتة.

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  Object? _replaceSv(Object? v) {
    if (v is Map) {
      if (v.length == 1 && v['.sv'] == 'timestamp') return serverClock;
      return {for (final e in v.entries) e.key: _replaceSv(e.value)};
    }
    if (v is List) return v.map(_replaceSv).toList();
    return v;
  }

  http.Client client() => MockClient((req) async {
        final key = req.url.path;
        if (req.method == 'PUT') {
          final decoded = _replaceSv(jsonDecode(req.body));
          store[key] = decoded;
          return _json(jsonEncode(decoded), 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          return _json('null', 200);
        }
        final v = store[key];
        return _json(v == null ? 'null' : jsonEncode(v), 200);
      });
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-trial.firebaseio.com';
  const dayMs = 24 * 60 * 60 * 1000;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_trial_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db');
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    SubscriptionGuard.debugReset();
    SubscriptionGuard.debugServerNowOverride = null;
  });
  tearDown(() async {
    SubscriptionGuard.debugReset();
    SubscriptionGuard.debugServerNowOverride = null;
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('TRIAL-01 التفعيل يحسب expires_at خادمياً = created_at + 24 ساعة',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final st = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsA'),
        cloud.client);
    expect(st.status, 'trial');
    expect(st.createdAtMs, cloud.serverClock,
        reason: 'created_at من ختم الخادم لا من ساعة الهاتف');
    expect(st.expiresAtMs, cloud.serverClock + dayMs,
        reason: 'المدة يوم واحد بالضبط (24h) محسوبة خادمياً');
    expect(st.expired, isFalse);
    expect(st.remaining.inHours, 24,
        reason: '24 ساعة كاملة متبقية لحظة التفعيل (ساعة الخادم لم تتحرك)');
    // العقدة السحابية بالحقول المطلوبة كاملة.
    final rec = cloud.store.entries
        .firstWhere((e) => e.key.contains('/wsA/subscription'))
        .value as Map;
    expect(rec['status'], 'trial');
    expect(rec['is_active'], true);
    expect('${rec['device_fingerprint']}'.length, 32);
    // فهرس البصمة العالمي كُتب أيضاً (صمّام منع التصفير).
    expect(cloud.store.keys.any((k) => k.contains('/trials/')), isTrue);
  });

  test('TRIAL-02 القرار بوقت الخادم حصراً — تقديم ساعة الهاتف لا يؤثر',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsB'),
        cloud.client);
    // «قدّم المستخدم ساعة هاتفه سنة كاملة» — لا شيء في الحارس يقرأ
    // DateTime.now()، فالحالة تُقرّر بساعة الخادم التي لم تتحرك.
    var st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsB', force: true),
        cloud.client);
    expect(st.expired, isFalse,
        reason: 'ساعة الخادم لم تتقدم — التجربة سارية مهما عبث الهاتف');
    // الآن يتقدم الخادم فعلياً 25 ساعة ⇒ الانتهاء الحقيقي.
    cloud.serverClock += 25 * 60 * 60 * 1000;
    st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsB', force: true),
        cloud.client);
    expect(st.expired, isTrue, reason: 'server_ts >= expires_at');
    expect(st.remainingMs, 0);
  });

  test('TRIAL-03 منع التصفير: مساحة جديدة بنفس البصمة تستأنف السجل الأول',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final first = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-old'),
        cloud.client);
    // «حذف التطبيق وأنشأ مساحة عمل جديدة» بعد 20 ساعة.
    cloud.serverClock += 20 * 60 * 60 * 1000;
    cloud.store.removeWhere((k, _) => k.contains('/ws-old/'));
    final resumed = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-new'),
        cloud.client);
    expect(resumed.createdAtMs, first.createdAtMs,
        reason: 'فهرس /trials/\$fp أعاد السجل الأصلي — لا عدّاد جديد');
    expect(resumed.expiresAtMs, first.expiresAtMs,
        reason: 'expires_at الأصلي محفوظ — متبقٍ 4 ساعات لا 24');
    expect(resumed.remaining.inHours, lessThanOrEqualTo(4));
    // وبعد 5 ساعات أخرى تكون منتهية رغم «المساحة الجديدة».
    cloud.serverClock += 5 * 60 * 60 * 1000;
    final after = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-new', force: true),
        cloud.client);
    expect(after.expired, isTrue);
  });

  test('TRIAL-04 البوابة isBlocked: مفتوحة أثناء التجربة، مقفلة بعدها، '
      'ومفتوحة دائماً مع اشتراك active', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsC'),
        cloud.client);
    // أثناء التجربة: غير محظور.
    expect(
        await http.runWithClient(
            () => SubscriptionGuard.isBlocked(repo,
                backendUrl: url, workspaceId: 'wsC'),
            cloud.client),
        isFalse);
    // بعد الانتهاء: محظور.
    cloud.serverClock += dayMs + 60000;
    SubscriptionGuard.debugReset(); // تجاوز الكاش.
    expect(
        await http.runWithClient(
            () => SubscriptionGuard.isBlocked(repo,
                backendUrl: url, workspaceId: 'wsC'),
            cloud.client),
        isTrue,
        reason: 'انتهاء التجربة يقفل السحابة');
    // ترقية لاشتراك مدفوع (يفعلها المدير/الخادم): status=active يفتح كل شيء.
    final key = cloud.store.keys
        .firstWhere((k) => k.contains('/wsC/subscription'));
    final rec = Map<String, Object?>.from(cloud.store[key] as Map);
    rec['status'] = 'active';
    cloud.store[key] = rec;
    SubscriptionGuard.debugReset();
    expect(
        await http.runWithClient(
            () => SubscriptionGuard.isBlocked(repo,
                backendUrl: url, workspaceId: 'wsC'),
            cloud.client),
        isFalse,
        reason: 'الاشتراك المدفوع يتجاوز فحص الانتهاء');
  });

  test(
      'TRIAL-06 (ترحيل القدامى) مساحة مسجلة مسبقاً بلا عقدة اشتراك: '
      'الفحص عند الإقلاع ينشئها تلقائياً بختم الخادم +24h', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // مستخدم قديم: بياناته السحابية موجودة منذ زمن لكن لا عقدة subscription.
    cloud.store['/workspaces/ws-legacy/roster/DEV-1.json'] = {'name': 'قديم'};
    expect(
        cloud.store.keys.any((k) => k.contains('/ws-legacy/subscription')),
        isFalse);
    // إقلاع التطبيق = check قسري — التهيئة الكسولة تنشئ العقدة.
    final st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-legacy', force: true),
        cloud.client);
    expect(st.status, 'trial');
    expect(st.createdAtMs, cloud.serverClock,
        reason: 'created_at = لحظة الفتح الحالية بتوقيت الخادم');
    expect(st.expiresAtMs, cloud.serverClock + dayMs,
        reason: 'expires_at يمتد 24 ساعة من لحظة الفتح');
    expect(
        cloud.store.keys.any((k) => k.contains('/ws-legacy/subscription')),
        isTrue,
        reason: 'العقدة أُنشئت في السحابة');
    // بيانات المستخدم القديم لم تُمسّ.
    expect(cloud.store['/workspaces/ws-legacy/roster/DEV-1.json'], isNotNull);
  });

  test(
      'TRIAL-07 (منع التكرار) العقدة المهيأة لا يُعاد تصفيرها أبداً — '
      'إقلاعات متكررة وensureTrialStarted صريح لا يحركان العداد', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // التهيئة الأولى لمستخدم قديم.
    final first = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-legacy2', force: true),
        cloud.client);
    // «أعاد فتح التطبيق» بعد 10 ساعات — إقلاع جديد + فحص قسري.
    cloud.serverClock += 10 * 60 * 60 * 1000;
    SubscriptionGuard.debugReset();
    final second = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-legacy2', force: true),
        cloud.client);
    expect(second.createdAtMs, first.createdAtMs,
        reason: 'لا إعادة تهيئة — نفس ختم البداية');
    expect(second.expiresAtMs, first.expiresAtMs,
        reason: 'العد التنازلي مستمر بلا تصفير');
    expect(second.remaining.inHours, lessThanOrEqualTo(14));
    // وحتى استدعاء التفعيل الصريح لا يصفّر.
    final third = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-legacy2'),
        cloud.client);
    expect(third.expiresAtMs, first.expiresAtMs);
  });

  test(
      'TRIAL-08 (متانة الترحيل) عقدة نصف مكتوبة — created_at موجود بلا '
      'expires_at: تُصلَّح من الختم الأصلي دون تصفير', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // انقطاع سابق خلّف عقدة ناقصة عمرها 6 ساعات.
    final origCreated = cloud.serverClock - 6 * 60 * 60 * 1000;
    cloud.store['/workspaces/ws-broken/subscription.json'] = {
      'status': 'trial',
      'created_at': origCreated,
      'expires_at': 0,
      'is_active': true,
    };
    final st = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-broken'),
        cloud.client);
    expect(st.createdAtMs, origCreated,
        reason: 'الإصلاح من الختم الأصلي لا من الآن');
    expect(st.expiresAtMs, origCreated + dayMs);
    expect(st.remaining.inHours, lessThanOrEqualTo(18),
        reason: 'استُهلكت 6 ساعات فعلاً — لا تصفير');
  });

  test('TRIAL-05 دقة الحساب: الحدود الدقيقة قبل/عند/بعد لحظة الانتهاء',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final st0 = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsD'),
        cloud.client);
    final expires = st0.expiresAtMs;
    // قبل الانتهاء بملي ثانية واحدة: سارية.
    cloud.serverClock = expires - 1;
    SubscriptionGuard.debugReset();
    var st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsD', force: true),
        cloud.client);
    expect(st.expired, isFalse);
    expect(st.remainingMs, 1);
    // عند اللحظة تماماً (>=): منتهية.
    cloud.serverClock = expires;
    SubscriptionGuard.debugReset();
    st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsD', force: true),
        cloud.client);
    expect(st.expired, isTrue, reason: 'server_ts >= expires_at بالضبط');
  });
}
