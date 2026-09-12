// 🔒 محرك الفترة التجريبية الذكية (1-Day Free Trial Engine).
//
// المبادئ الصارمة:
//  1) توقيت الخادم حصراً: التفعيل يُختم بـ {".sv":"timestamp"} على فيربيس،
//     والتحقق يقارن expires_at بوقت الخادم المُستنتج من ختم write-back —
//     لا اعتماد على DateTime.now() للهاتف إطلاقاً في قرار الصلاحية.
//  2) مقاومة التصفير: البصمة العتادية للجهاز تُسجل في فهرس سحابي عالمي
//     (/trials/$fpHash) مستقل عن مساحة العمل — حذف التطبيق أو مسح بياناته
//     أو إنشاء مساحة جديدة يعيد نفس البصمة فيُستأنف العدّاد من سجله الأول.
//  3) بوابة مركزية واحدة (isBlocked) يستشيرها SyncEngine وCloudJoin
//     وCloudSync — انتهاء التجربة يوقف المزامنة والربط والنسخ السحابي،
//     ويبقى العمل المحلي سليماً.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../repository.dart';
import 'device_id.dart';

/// مدة التجربة الحالية: يوم واحد (24 ساعة) — لأغراض الاختبار، وتُرفع
/// لاحقاً بتغيير هذا الثابت وحده.
const Duration kTrialDuration = Duration(hours: 24);

/// المقاعد الافتراضية لباقة المؤسسات (يرفعها المشغّل من عقدة الاشتراك
/// السحابية `max_devices` بحسب الباقة المباعة).
const int kDefaultEnterpriseSeats = 5;

/// هامش تسامح لانحراف الشبكة عند إسناد وقت الخادم (ثوانٍ قليلة).
const int kServerSkewToleranceMs = 5000;

/// مفاتيح المزايا الثمانية في عقدة features السحابية — القيم الافتراضية
/// حسب الخطة: أثناء التجربة والاشتراك الفعّال كل شيء مفتوح؛ فردي منتهٍ
/// تُقفل مزاياه المدفوعة؛ مؤسسة منتهية تُجمَّد سحابتها.
class PlanFeatures {
  final bool canUseCategories;
  final bool canSendNotifications;
  final bool canCloudBackup;
  final bool canRestoreData;
  final bool canAdvancedSearch;
  final bool multiDeviceSync;
  final bool rolePermissions;
  final bool auditLog;

  const PlanFeatures({
    required this.canUseCategories,
    required this.canSendNotifications,
    required this.canCloudBackup,
    required this.canRestoreData,
    required this.canAdvancedSearch,
    required this.multiDeviceSync,
    required this.rolePermissions,
    required this.auditLog,
  });

  static const allOn = PlanFeatures(
    canUseCategories: true,
    canSendNotifications: true,
    canCloudBackup: true,
    canRestoreData: true,
    canAdvancedSearch: true,
    multiDeviceSync: true,
    rolePermissions: true,
    auditLog: true,
  );

  /// فردي منتهي التجربة: يبقى التسجيل والحركات اليومية محلياً فقط.
  static const individualLocked = PlanFeatures(
    canUseCategories: false,
    canSendNotifications: false,
    canCloudBackup: false,
    canRestoreData: false,
    canAdvancedSearch: false,
    multiDeviceSync: false,
    rolePermissions: false,
    auditLog: false,
  );

  factory PlanFeatures.fromMap(Map<String, dynamic>? m) {
    if (m == null) return allOn;
    bool b(String k, bool dflt) {
      final v = m[k];
      return v is bool ? v : dflt;
    }

    return PlanFeatures(
      canUseCategories: b('can_use_categories', true),
      canSendNotifications: b('can_send_notifications', true),
      canCloudBackup: b('can_cloud_backup', true),
      canRestoreData: b('can_restore_data', true),
      canAdvancedSearch: b('can_advanced_search', true),
      multiDeviceSync: b('multi_device_sync', true),
      rolePermissions: b('role_permissions', true),
      auditLog: b('audit_log', true),
    );
  }

  Map<String, Object?> toMap() => {
        'can_use_categories': canUseCategories,
        'can_send_notifications': canSendNotifications,
        'can_cloud_backup': canCloudBackup,
        'can_restore_data': canRestoreData,
        'can_advanced_search': canAdvancedSearch,
        'multi_device_sync': multiDeviceSync,
        'role_permissions': rolePermissions,
        'audit_log': auditLog,
      };
}

/// حالة الاشتراك كما تُقرأ من السحابة.
class SubscriptionState {
  /// trial | active | expired | none (لا سحابة مهيأة).
  final String status;

  /// individual | enterprise — يُستنتج تلقائياً (مستقل=فردي، مجموعة=مؤسسة).
  final String planType;

  /// الحد الأقصى للأجهزة (1 للفردي؛ بحسب الباقة للمؤسسة).
  final int maxDevices;

  final int createdAtMs; // ختم خادم فيربيس (ملي ثانية).
  final int expiresAtMs; // ختم خادم.
  final bool isActive;
  final String deviceFingerprint;

  /// مفاتيح المزايا من عقدة features السحابية.
  final PlanFeatures features;

  /// وقت الخادم التقريبي لحظة آخر فحص (server_ts المرجعي).
  final int serverNowMs;

  const SubscriptionState({
    required this.status,
    this.planType = 'individual',
    this.maxDevices = 1,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.isActive,
    required this.deviceFingerprint,
    this.features = PlanFeatures.allOn,
    required this.serverNowMs,
  });

  /// هل انتهت التجربة؟ المقارنة بوقت الخادم حصراً.
  bool get expired =>
      status != 'active' && expiresAtMs > 0 && serverNowMs >= expiresAtMs;

  /// هل الاشتراك مدفوع وفعّال؟
  bool get isSubscribed => status == 'active';

  /// هل الميزة المدفوعة مفتوحة الآن؟ (تجربة سارية أو اشتراك فعّال +
  /// مفتاح الميزة نفسه غير مطفأ من الخادم).
  bool featureUnlocked(bool Function(PlanFeatures) pick) {
    if (status == 'none') return true; // لا سحابة بعد — لا قيود عرضية.
    if (expired && !isSubscribed) return false;
    return pick(features);
  }

  /// المتبقي بالملي ثانية (0 عند الانتهاء). بوقت الخادم.
  int get remainingMs =>
      expired ? 0 : (expiresAtMs - serverNowMs).clamp(0, 1 << 62);

  Duration get remaining => Duration(milliseconds: remainingMs);

  static const none = SubscriptionState(
    status: 'none',
    createdAtMs: 0,
    expiresAtMs: 0,
    isActive: true,
    deviceFingerprint: '',
    serverNowMs: 0,
  );
}

/// حارس الاشتراك: التفعيل، الفحص الدوري بوقت الخادم، والبوابة المركزية.
class SubscriptionGuard {
  SubscriptionGuard._();

  /// آخر حالة مفحوصة (كاش خفيف) + لحظة فحصها بساعة أحادية محلية —
  /// نستخدم Stopwatch (monotonic) لا DateTime.now() حتى لا يكسر تقديم
  /// ساعة الهاتف حساب «العمر منذ آخر فحص».
  static SubscriptionState _last = SubscriptionState.none;
  static final Stopwatch _sinceCheck = Stopwatch();
  static bool _everChecked = false;

  /// نافذة صلاحية الكاش قبل إعادة الفحص السحابي.
  static Duration cacheTtl = const Duration(minutes: 5);

  /// (للاختبارات) تجاوز جالب وقت الخادم — يعيد ملي ثانية خادم فيربيس.
  static Future<int> Function(String backendUrl)? debugServerNowOverride;

  static SubscriptionState get lastState => _last;

  /// تجزئة البصمة العتادية إلى مفتاح سحابي ثابت وآمن (لا نص خام يصعد).
  static String fingerprintHash(String raw) =>
      sha256.convert(utf8.encode(raw.trim())).toString().substring(0, 32);

  static String _wsRoot(String base, String ws) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';

  static String _trialsRoot(String base) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/trials';

  /// وقت خادم فيربيس الحقيقي: نكتب {".sv":"timestamp"} في عقدة خردة
  /// ونقرأ القيمة المستبدلة — يعمل عبر REST بلا SDK (بديل serverTimeOffset).
  static Future<int> serverNowMs(String backendUrl) async {
    final o = debugServerNowOverride;
    if (o != null) return o(backendUrl);
    final url =
        '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/server_clock.json';
    final res = await http
        .put(Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'ts': {'.sv': 'timestamp'}}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('server-clock-http-${res.statusCode}');
    }
    final m = jsonDecode(res.body);
    final ts = m is Map ? m['ts'] : null;
    if (ts is int && ts > 0) return ts;
    if (ts is num && ts > 0) return ts.toInt();
    throw StateError('server-clock-bad-payload');
  }

  /// تفعيل التجربة عند أول إعداد سحابي لمساحة العمل:
  ///  1) فحص فهرس /trials/$fp — بصمة سبق أن استهلكت تجربة تستأنف سجلها
  ///     الأصلي (منع التصفير بإعادة التثبيت/مساحة جديدة).
  ///  2) وإلا: كتابة سجل جديد بختم خادم، ثم write-back لحساب expires_at
  ///     خادمياً (created_at + 24h) وتثبيته رقماً.
  static Future<SubscriptionState> ensureTrialStarted(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final raw = await hardwareFingerprintRaw() ??
        'fallback:${await ensureDeviceId(repo)}';
    final fp = fingerprintHash(raw);
    final wsSub = '${_wsRoot(backendUrl, workspaceId)}/subscription.json';
    final trialIdx = '${_trialsRoot(backendUrl)}/$fp.json';
    // (الخطط المزدوجة) plan_type يُستنتج تلقائياً: العمل المنفرد = فردي؛
    // مجموعة قائمة (host/member) = مؤسسة بمقاعدها الافتراضية.
    final planType = await _detectPlanType(repo);
    final maxDevices =
        planType == 'enterprise' ? kDefaultEnterpriseSeats : 1;

    // (1) عقدة المساحة موجودة مسبقاً؟ لا إعادة تفعيل أبداً — نعيد قراءتها.
    //     (يشمل المستخدمين القدامى الذين هُيّئت عقدتهم في إقلاع سابق.)
    final existing = await _readJson(wsSub);
    if (existing != null && (existing['expires_at'] is num) &&
        (existing['expires_at'] as num) > 0) {
      return _stateFrom(existing, await serverNowMs(backendUrl));
    }
    // (1-ب) إصلاح عقدة نصف مكتوبة (انقطاع بين خطوتي الكتابة): created_at
    //     الخادمي موجود لكن expires_at لم يُثبَّت — نكمل الحساب من الختم
    //     الأصلي نفسه دون أي تصفير للعداد.
    if (existing != null) {
      final priorCreated = _asMs(existing['created_at']);
      if (priorCreated > 0) {
        final repaired = {
          'status': '${existing['status'] ?? 'trial'}',
          'created_at': priorCreated,
          'expires_at': priorCreated + kTrialDuration.inMilliseconds,
          'is_active': existing['is_active'] != false,
          'device_fingerprint':
              '${existing['device_fingerprint'] ?? ''}'.isNotEmpty
                  ? existing['device_fingerprint']
                  : fp,
        };
        await _putJson(wsSub, repaired);
        await _putJson(trialIdx, {
          ...repaired,
          'workspace_id': workspaceId,
          'first_seen': priorCreated,
        });
        return _stateFrom(
            Map<String, dynamic>.from(repaired), await serverNowMs(backendUrl));
      }
    }

    // (2) فهرس البصمة العالمي: تجربة سابقة لنفس العتاد = استئناف لا تصفير.
    final prior = await _readJson(trialIdx);
    if (prior != null && (prior['expires_at'] is num) &&
        (prior['expires_at'] as num) > 0) {
      final resumed = {
        'status': '${prior['status'] ?? 'trial'}',
        'created_at': prior['created_at'],
        'expires_at': prior['expires_at'],
        'is_active': true,
        'device_fingerprint': fp,
        'resumed': true,
      };
      await _putJson(wsSub, resumed);
      return _stateFrom(resumed, await serverNowMs(backendUrl));
    }

    // (3) تفعيل جديد: ختم خادم ثم تثبيت expires_at رقمياً من قيمة الخادم
    //     المكتوبة فعلاً (write-back) — الحساب خادمي بالكامل.
    await _putJson(wsSub, {
      'plan_type': planType,
      'status': 'trial',
      'max_devices': maxDevices,
      'created_at': {'.sv': 'timestamp'},
      'expires_at': 0,
      'is_active': true,
      'device_fingerprint': fp,
      'features': PlanFeatures.allOn.toMap(),
    });
    final written = await _readJson(wsSub) ?? {};
    final createdMs = _asMs(written['created_at']);
    final expiresMs = createdMs + kTrialDuration.inMilliseconds;
    final finalRec = {
      'plan_type': planType,
      'status': 'trial',
      'max_devices': maxDevices,
      'created_at': createdMs,
      'expires_at': expiresMs,
      'is_active': true,
      'device_fingerprint': fp,
      'features': PlanFeatures.allOn.toMap(),
    };
    await _putJson(wsSub, finalRec);
    // فهرس البصمة العالمي — صمّام منع إعادة الاستغلال.
    await _putJson(trialIdx, {
      ...finalRec,
      'workspace_id': workspaceId,
      'first_seen': createdMs,
    });
    return _stateFrom(finalRec, createdMs);
  }

  /// الفحص المرجعي: يقرأ العقدة ويقارن بوقت الخادم. يحدّث الكاش
  /// ويثبّت آخر حالة ناجحة محلياً (settings) حتى يبقى العدّاد ظاهراً
  /// بعد إغلاق التطبيق وفتحه ولو تعذرت الشبكة لحظة الإقلاع.
  static Future<SubscriptionState> check(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    bool force = false,
  }) async {
    if (!force &&
        _everChecked &&
        _sinceCheck.elapsed < cacheTtl) {
      // إسناد لحظي: نقدّم وقت الخادم المرجعي بعمر الكاش (ساعة أحادية
      // لا تتأثر بتلاعب ساعة الهاتف) — العدّاد يتجدد بين الفحوصات
      // بدل التجمد على قيمة آخر فحص.
      return _advanced();
    }
    try {
      final wsSub = '${_wsRoot(backendUrl, workspaceId)}/subscription.json';
      var rec = await _readJson(wsSub);
      final now = await serverNowMs(backendUrl);
      if (rec == null) {
        // لا عقدة اشتراك بعد — فعّل التجربة الآن (أول استخدام سحابي).
        final st = await ensureTrialStarted(repo,
            backendUrl: backendUrl, workspaceId: workspaceId);
        _cache(st);
        await _persist(repo, st);
        return st;
      }
      final st = _stateFrom(rec, now);
      _cache(st);
      await _persist(repo, st);
      return st;
    } catch (_) {
      // شبكة غائبة: آخر حالة معروفة في الذاكرة، وإلا (إقلاع جديد بلا
      // شبكة) الحالة المثبّتة محلياً من آخر فحص ناجح — الشريط لا يختفي.
      if (_everChecked) return _advanced();
      final persisted = await _loadPersisted(repo);
      if (persisted != null) {
        _cache(persisted);
        return persisted;
      }
      return _last;
    }
  }

  /// آخر حالة مع تقديم وقت الخادم المرجعي بعمر الكاش (monotonic).
  static SubscriptionState _advanced() {
    if (!_everChecked || _last.serverNowMs <= 0) return _last;
    return SubscriptionState(
      status: _last.status,
      createdAtMs: _last.createdAtMs,
      expiresAtMs: _last.expiresAtMs,
      isActive: _last.isActive,
      deviceFingerprint: _last.deviceFingerprint,
      serverNowMs: _last.serverNowMs + _sinceCheck.elapsedMilliseconds,
    );
  }

  /// تثبيت آخر حالة ناجحة محلياً — تُقرأ عند الإقلاع بلا شبكة.
  static Future<void> _persist(Repo repo, SubscriptionState st) async {
    try {
      if (st.status == 'none') return;
      await repo.setSetting(
          'subCachedState',
          jsonEncode({
            'status': st.status,
            'plan_type': st.planType,
            'max_devices': st.maxDevices,
            'created_at': st.createdAtMs,
            'expires_at': st.expiresAtMs,
            'is_active': st.isActive,
            'fp': st.deviceFingerprint,
            'features': st.features.toMap(),
            'server_now': st.serverNowMs,
            'device_ms': DateTime.now().millisecondsSinceEpoch,
          }));
    } catch (_) {}
  }

  /// استرجاع الحالة المثبّتة محلياً مع إسناد تقديري لوقت الخادم
  /// (لأغراض العرض فقط — البوابات تُحسم بفحص سحابي حقيقي عند توفر
  /// الشبكة، ولا يُسمح للإسناد بإرجاع الساعة للخلف).
  static Future<SubscriptionState?> _loadPersisted(Repo repo) async {
    try {
      final raw = (await repo.settings())['subCachedState'] ?? '';
      if (raw.isEmpty) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final serverNow = _asMs(m['server_now']);
      final deviceMs = _asMs(m['device_ms']);
      final nowDevice = DateTime.now().millisecondsSinceEpoch;
      // الإسناد للأمام فقط: إرجاع ساعة الهاتف لا يُرجع وقت الخادم.
      final drift = (nowDevice - deviceMs).clamp(0, 1 << 62);
      final rawFeat = m['features'];
      return SubscriptionState(
        status: '${m['status'] ?? 'trial'}',
        planType:
            '${m['plan_type'] ?? 'individual'}' == 'enterprise'
                ? 'enterprise'
                : 'individual',
        maxDevices: _asMs(m['max_devices']) > 0 ? _asMs(m['max_devices']) : 1,
        createdAtMs: _asMs(m['created_at']),
        expiresAtMs: _asMs(m['expires_at']),
        isActive: m['is_active'] != false,
        deviceFingerprint: '${m['fp'] ?? ''}',
        features: PlanFeatures.fromMap(
            rawFeat is Map ? Map<String, dynamic>.from(rawFeat) : null),
        serverNowMs: serverNow + drift,
      );
    } catch (_) {
      return null;
    }
  }

  /// البوابة المركزية: true = السحابة محظورة (التجربة انتهت وغير مدفوع).
  /// تُستدعى قبل أي دفع/سحب/ربط/نسخ سحابي.
  static Future<bool> isBlocked(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final st = await check(repo,
        backendUrl: backendUrl, workspaceId: workspaceId);
    if (st.status == 'active') return false; // اشتراك مدفوع فعّال.
    if (st.status == 'none') return false; // لا سحابة — لا حظر.
    return st.expired;
  }

  static void _cache(SubscriptionState st) {
    _last = st;
    _everChecked = true;
    _sinceCheck
      ..reset()
      ..start();
  }

  /// (للاختبارات) تصفير الكاش.
  static void debugReset() {
    _last = SubscriptionState.none;
    _everChecked = false;
    _sinceCheck
      ..stop()
      ..reset();
  }

  static SubscriptionState _stateFrom(Map<String, dynamic> m, int nowMs) {
    final rawFeat = m['features'];
    return SubscriptionState(
      status: '${m['status'] ?? 'trial'}',
      planType: '${m['plan_type'] ?? 'individual'}' == 'enterprise'
          ? 'enterprise'
          : 'individual',
      maxDevices: (() {
        final v = m['max_devices'];
        if (v is int && v > 0) return v;
        if (v is num && v > 0) return v.toInt();
        return '${m['plan_type'] ?? ''}' == 'enterprise'
            ? kDefaultEnterpriseSeats
            : 1;
      })(),
      createdAtMs: _asMs(m['created_at']),
      expiresAtMs: _asMs(m['expires_at']),
      isActive: m['is_active'] != false,
      deviceFingerprint: '${m['device_fingerprint'] ?? ''}',
      features: PlanFeatures.fromMap(
          rawFeat is Map ? Map<String, dynamic>.from(rawFeat) : null),
      serverNowMs: nowMs,
    );
  }

  /// استنتاج المسار تلقائياً: مجموعة قائمة (مضيف أو عضو) = مؤسسة؛
  /// العمل المنفرد = فردي.
  static Future<String> _detectPlanType(Repo repo) async {
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'host' || mode == 'member') return 'enterprise';
      // مضيف فعلي بأجهزة مقترنة أخرى (حتى لو تلكأ الوضع) = مؤسسة.
      final db = await repo.database;
      final peers = await db.rawQuery(
          "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
          "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''");
      final c = (peers.first['c'] as int?) ?? 0;
      if (c > 1) return 'enterprise';
    } catch (_) {}
    return 'individual';
  }

  /// الترقية التلقائية للمسار: بمجرد إنشاء مجموعة/فتح كود ربط لجهاز ثانٍ
  /// يتحول الاشتراك إلى enterprise بمقاعده — دون المساس بالعداد الزمني
  /// (created_at/expires_at يبقيان كما هما بختم الخادم الأصلي).
  static Future<void> promoteToEnterprise(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    int? maxDevices,
  }) async {
    final wsSub = '${_wsRoot(backendUrl, workspaceId)}/subscription.json';
    final rec = await _readJson(wsSub);
    if (rec == null) return; // لا عقدة بعد — ensureTrialStarted سينشئها.
    if ('${rec['plan_type'] ?? ''}' == 'enterprise') return; // مرقّاة أصلاً.
    final seats = maxDevices ?? kDefaultEnterpriseSeats;
    await _putJson(wsSub, {
      ...rec,
      'plan_type': 'enterprise',
      'max_devices':
          (rec['max_devices'] is num && (rec['max_devices'] as num) > seats)
              ? rec['max_devices']
              : seats,
      'features': (rec['features'] is Map)
          ? rec['features']
          : PlanFeatures.allOn.toMap(),
    });
    debugReset(); // الفحص التالي يقرأ الخطة الجديدة فوراً.
  }

  static int _asMs(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  static Future<Map<String, dynamic>?> _readJson(String url) async {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('subscription-http-${res.statusCode}');
    }
    final t = res.body.trim();
    if (t.isEmpty || t == 'null') return null;
    final d = jsonDecode(t);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  static Future<void> _putJson(String url, Object body) async {
    final res = await http
        .put(Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('subscription-put-http-${res.statusCode}');
    }
  }
}
