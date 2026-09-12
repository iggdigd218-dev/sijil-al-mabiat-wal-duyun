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

/// هامش تسامح لانحراف الشبكة عند إسناد وقت الخادم (ثوانٍ قليلة).
const int kServerSkewToleranceMs = 5000;

/// حالة الاشتراك كما تُقرأ من السحابة.
class SubscriptionState {
  /// trial | active | expired | none (لا سحابة مهيأة).
  final String status;
  final int createdAtMs; // ختم خادم فيربيس (ملي ثانية).
  final int expiresAtMs; // ختم خادم.
  final bool isActive;
  final String deviceFingerprint;

  /// وقت الخادم التقريبي لحظة آخر فحص (server_ts المرجعي).
  final int serverNowMs;

  const SubscriptionState({
    required this.status,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.isActive,
    required this.deviceFingerprint,
    required this.serverNowMs,
  });

  /// هل انتهت التجربة؟ المقارنة بوقت الخادم حصراً.
  bool get expired =>
      status != 'active' && expiresAtMs > 0 && serverNowMs >= expiresAtMs;

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

    // (1) عقدة المساحة موجودة مسبقاً؟ لا إعادة تفعيل — نعيد قراءتها.
    final existing = await _readJson(wsSub);
    if (existing != null && (existing['expires_at'] is num) &&
        (existing['expires_at'] as num) > 0) {
      return _stateFrom(existing, await serverNowMs(backendUrl));
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
      'status': 'trial',
      'created_at': {'.sv': 'timestamp'},
      'expires_at': 0,
      'is_active': true,
      'device_fingerprint': fp,
    });
    final written = await _readJson(wsSub) ?? {};
    final createdMs = _asMs(written['created_at']);
    final expiresMs = createdMs + kTrialDuration.inMilliseconds;
    final finalRec = {
      'status': 'trial',
      'created_at': createdMs,
      'expires_at': expiresMs,
      'is_active': true,
      'device_fingerprint': fp,
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

  /// الفحص المرجعي: يقرأ العقدة ويقارن بوقت الخادم. يحدّث الكاش.
  /// عند غياب الشبكة يعاد آخر كاش (سماحية قصيرة) — الانقطاع الطويل
  /// بلا فحص ناجح يُعامل كحظر احترازي إن كانت آخر حالة معروفة منتهية.
  static Future<SubscriptionState> check(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    bool force = false,
  }) async {
    if (!force &&
        _everChecked &&
        _sinceCheck.elapsed < cacheTtl) {
      return _last;
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
        return st;
      }
      final st = _stateFrom(rec, now);
      _cache(st);
      return st;
    } catch (_) {
      // شبكة غائبة: أعد آخر حالة معروفة دون تحديث ساعة الفحص.
      return _last;
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

  static SubscriptionState _stateFrom(Map<String, dynamic> m, int nowMs) =>
      SubscriptionState(
        status: '${m['status'] ?? 'trial'}',
        createdAtMs: _asMs(m['created_at']),
        expiresAtMs: _asMs(m['expires_at']),
        isActive: m['is_active'] != false,
        deviceFingerprint: '${m['device_fingerprint'] ?? ''}',
        serverNowMs: nowMs,
      );

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
