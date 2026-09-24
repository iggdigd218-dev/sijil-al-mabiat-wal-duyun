// خدمة Firebase RTDB عبر REST — نفس قاعدة بيانات تطبيق «مدير الحسابات».
// لا تحتاج SDK: قراءة/كتابة JSON مباشرة + وقت الخادم بختم {".sv":"timestamp"}.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'license_model.dart';

export 'license_model.dart';

/// مدة الخطة المتاحة للاختيار.
enum PlanDuration {
  month('شهر واحد (30 يوماً)', Duration(days: 30)),
  quarter('3 أشهر (90 يوماً)', Duration(days: 90)),
  year('سنة كاملة (365 يوماً)', Duration(days: 365)),
  lifetime('تفعيل دائم (Lifetime)', Duration(days: 365 * 100));

  final String label;
  final Duration span;
  const PlanDuration(this.label, this.span);
}

/// نتيجة تفعيل ناجحة — للعرض في الرسالة الخضراء.
class ActivationResult {
  final String workspaceId;
  final String planType;
  final int maxDevices;
  final int expiresAtMs;
  final bool lifetime;
  final String clientName;
  final String storeName;
  final String phone;
  final String licenseKey;
  final String deviceId;

  const ActivationResult({
    required this.workspaceId,
    required this.planType,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.lifetime,
    this.clientName = '',
    this.storeName = '',
    this.phone = '',
    this.licenseKey = '',
    this.deviceId = '',
  });
}

int _asInt(Object? v, [int dflt = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? dflt;
  return dflt;
}

String _asStr(Object? v) => v == null ? '' : '$v'.trim();

/// سجل مشترك للعرض في القائمة.
class SubscriberEntry {
  final String workspaceId;
  final String planType;
  final String status;
  final int maxDevices;
  final int expiresAtMs;
  final int activatedAtMs;
  final String deviceRef; // المعرف/البصمة التي أُدخلت وقت التفعيل.

  // الحقول الإجبارية الجديدة (Requirement 2 & 3)
  final String clientName;
  final String storeName;
  final String phone;
  final String _deviceId;
  final String _licenseKey;
  final int _expiryDate;

  const SubscriberEntry({
    required this.workspaceId,
    required this.planType,
    required this.status,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.activatedAtMs,
    required this.deviceRef,
    this.clientName = '',
    this.storeName = '',
    this.phone = '',
    String deviceId = '',
    String licenseKey = '',
    int expiryDate = 0,
  })  : _deviceId = deviceId,
        _licenseKey = licenseKey,
        _expiryDate = expiryDate;

  String get deviceId => _deviceId.isNotEmpty ? _deviceId : deviceRef;

  String get licenseKey => _licenseKey.isNotEmpty
      ? _licenseKey
      : (deviceRef.isNotEmpty
          ? 'NX-$deviceRef'
          : (workspaceId.isNotEmpty ? 'NX-$workspaceId' : 'NX-PENDING'));

  int get expiryDate => _expiryDate > 0 ? _expiryDate : expiresAtMs;

  factory SubscriberEntry.fromSubscriptionMap(String wsId, Map map) {
    final devId = _asStr(map['deviceId'] ??
        map['device_id'] ??
        map['deviceRef'] ??
        map['device_ref']);
    final key = _asStr(map['licenseKey'] ?? map['license_key'] ?? map['key']);
    final exp = _asInt(
        map['expiryDate'] ?? map['expiry_date'] ?? map['expires_at']);
    return SubscriberEntry(
      workspaceId: wsId,
      planType: _asStr(map['plan_type'] ?? map['planType'] ?? 'individual'),
      status: _asStr(map['status'] ?? 'trial'),
      maxDevices: _asInt(map['max_devices'] ?? map['maxDevices'], 1),
      expiresAtMs: exp,
      activatedAtMs: _asInt(map['activated_at'] ?? map['activatedAt']),
      deviceRef: devId,
      clientName: _asStr(map['clientName'] ?? map['client_name']),
      storeName: _asStr(map['storeName'] ?? map['store_name']),
      phone: _asStr(map['phone'] ?? map['whatsapp']),
      deviceId: devId,
      licenseKey: key,
      expiryDate: exp,
    );
  }

  LicenseModel toLicenseModel() => LicenseModel(
        clientName: clientName,
        storeName: storeName,
        phone: phone,
        deviceId: deviceId,
        licenseKey: licenseKey,
        expiryDate: expiryDate,
        status: status,
        workspaceId: workspaceId,
        planType: planType,
        maxDevices: maxDevices,
        activatedAtMs: activatedAtMs,
      );
}

/// الرابط الرسمي الإقليمي لقاعدة النظام — نفس المضمّن في تطبيق المستخدم
/// (المعمارية الصامتة): الأدمن يعمل فوراً بلا إعداد يدوي، مع إمكانية
/// التجاوز من حوار «الاتصال بقاعدة البيانات».
const String kOfficialRtdbUrl = String.fromEnvironment(
  'ADMIN_RTDB_URL',
  defaultValue:
      'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app',
);

/// مفتاح Firebase (Web API Key) لنفس المشروع — يُستخدم **للمصادقة
/// المجهولة** فقط: قواعد RTDB تشترط `auth != null` على كل عقدة تلمسها
/// اللوحة (workspaces/trials)، فبدون هوية تُرفض كل قراءة وكتابة بـ
/// 401/403 ويبدو التطبيق «معطّلاً» وهو سليم. قابل للتجاوز بـ dart-define
/// أو بإدخال توكن يدوي من حوار الإعدادات.
const String kFirebaseApiKey = String.fromEnvironment(
  'ADMIN_FIREBASE_API_KEY',
  defaultValue: 'AIzaSyBHmi_0Oj58JKi2kNLR8gqQHhRN3grRg3U',
);

/// أقصى عدد مساحات تُمسح في البحث عن جهاز/سجل — سقف يمنع اختناق اللوحة
/// على قاعدة فيها مئات المساحات (كان المسح المتسلسل بلا سقف يستغرق عشرات
/// الثواني فيبدو التفعيل «لا يعمل»).
const int kMaxWorkspaceScan = 40;

/// أقصى عدد مساحات تُعرض/تُحصى في السجل الأخير.
const int kMaxSubscriberScan = 40;

/// تحويل آمن لأي قيمة سحابية إلى عدد صحيح (القواعد قد تُخزّن رقماً أو نصاً).
int asInt(Object? v, [int dflt = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? dflt;
  return dflt;
}

/// تحويل آمن لختم زمني (مللي ثانية) — يقبل نصاً أو رقماً.
int asMs(Object? v) => asInt(v, 0);

/// تحويل آمن إلى نص.
String asStr(Object? v) => v == null ? '' : '$v';

/// (2026-09-23 — تأمين الترخيص) رمز تحديث هوية **المدير** — يُلصق مرة
/// واحدة في ⚙️ داخل التطبيق (أو يُمرَّر بـ dart-define عند بناء نسخة
/// خاصة). به وحده تُقبل الكتابة على عقدة الاشتراك بعد تشديد القواعد؛
/// بدونه يعمل التطبيق بالهوية المجهولة (كتابة مرفوضة بعد التشديد).
const String kAdminRefreshTokenDefault =
    String.fromEnvironment('ADMIN_REFRESH_TOKEN');

class Rtdb {
  Rtdb._();
  static final Rtdb instance = Rtdb._();

  /// عميل HTTP موحد: يعيد استخدام اتصال TCP/TLS نفسه عبر كل الطلبات
  /// (keep-alive) بدل فتح اتصال جديد لكل طلب — أسرع بمرات على الجوال.
  final http.Client _client = http.Client();

  /// (اختبارات) عميل HTTP قابل للحقن: العميل الموحّد يُبنى مرة واحدة
  /// (keep-alive) فلا تكفي `runWithClient` لحقنه بعد البناء.
  http.Client? clientOverride;

  http.Client get _http => clientOverride ?? _client;

  String baseUrl = '';
  String authToken = ''; // اختياري: legacy secret أو ID token.

  /// رمز تحديث هوية المدير (إن ضُبط) + معرّفها — يُعرض في ⚙️ للتأكد أن
  /// القواعد والحالة يستخدمان نفس الهوية.
  String adminRefreshToken = '';
  String adminUid = '';

  static const _kUrl = 'rtdbUrl';
  static const _kAuth = 'rtdbAuth';
  static const _kIdToken = 'rtdbIdToken';
  static const _kRefresh = 'rtdbRefreshToken';
  static const _kExpiry = 'rtdbTokenExpiryMs';
  static const _kAdminRt = 'rtdbAdminRefreshToken';
  static const _kAdminUid = 'rtdbAdminUid';

  /// جلسة الهوية المجهولة (Firebase Auth) — تُرفق بكل طلب تلقائياً.
  String _idToken = '';
  String _refreshToken = '';
  int _expiryMs = 0;

  /// آخر خطأ مصادقة — للعرض في الواجهة بدل رسالة HTTP مبهمة.
  String lastAuthError = '';

  /// (إصلاح الأداء) كاش ساعة الخادم: قياس واحد يكفي لبرهة قصيرة، والإسناد
  /// بين القراءات بساعة **أحادية** (Stopwatch) لا بساعة الهاتف — فتبقى كل
  /// الحسابات بختم الخادم دون طلبين إضافيين لكل عملية.
  static const Duration _clockTtl = Duration(seconds: 45);
  final Stopwatch _clockAge = Stopwatch();
  int _clockMs = 0;

  /// (للاختبارات) تصفير كاش الساعة بين الحالات.
  void resetClockCache() {
    _clockMs = 0;
    _clockAge
      ..stop()
      ..reset();
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    baseUrl = (sp.getString(_kUrl) ?? '').trim();
    // (المعمارية الصامتة) لا رابط محفوظاً؟ اعتمد الرسمي المضمّن فوراً.
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = sp.getString(_kAuth) ?? '';
    _idToken = sp.getString(_kIdToken) ?? '';
    _refreshToken = sp.getString(_kRefresh) ?? '';
    _expiryMs = sp.getInt(_kExpiry) ?? 0;
    adminRefreshToken = (sp.getString(_kAdminRt) ?? '').trim().isEmpty
        ? kAdminRefreshTokenDefault.trim()
        : (sp.getString(_kAdminRt) ?? '').trim();
    adminUid = (sp.getString(_kAdminUid) ?? '').trim();
    // (قانون 2026-09-22) الهوية تُبنى عند أول استخدام — لا عند الإقلاع،
    // حتى لا يعلق التطبيق على شاشة التحميل عند ضعف الشبكة.
  }

  Future<void> _persistSession() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kIdToken, _idToken);
    await sp.setString(_kRefresh, _refreshToken);
    await sp.setInt(_kExpiry, _expiryMs);
    await sp.setString(_kAdminRt, adminRefreshToken);
    await sp.setString(_kAdminUid, adminUid);
  }

  /// حفظ رمز هوية المدير (يُلصق مرة واحدة من ⚙️) وتبديل الهوية فوراً.
  Future<void> saveAdminRefreshToken(String rt) async {
    adminRefreshToken = rt.trim();
    adminUid = '';
    _idToken = '';
    _refreshToken = '';
    _expiryMs = 0;
    resetClockCache();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kAdminRt, adminRefreshToken);
    await sp.setString(_kAdminUid, '');
    lastAuthError = '';
  }

  bool get _tokenAlive =>
      _idToken.isNotEmpty &&
      _expiryMs > DateTime.now().millisecondsSinceEpoch + 60000;

  /// هوية صالحة لكل طلب: توكن يدوي (إن أدخله المالك) وإلا هوية مجهولة
  /// تُنشأ/تُجدَّد تلقائياً. إخفاقها لا يمنع المحاولة — رسالة الخطأ
  /// توضّح السبب (401 ⇒ القاعدة ترفض بلا هوية).
  Future<String> _ensureAuth({bool force = false, bool retried = false}) async {
    if (authToken.trim().isNotEmpty) return authToken.trim();
    if (!force && _tokenAlive) return _idToken;
    // (2026-09-23) هوية المدير الثابتة — هي الوحيدة المخوّلة بكتابة
    // عقدة الاشتراك بعد تشديد القواعد.
    if (adminRefreshToken.isNotEmpty) return _signInAsAdmin();
    final refresh = force && _refreshToken.isNotEmpty;
    try {
      final body = refresh
          ? {'grant_type': 'refresh_token', 'refresh_token': _refreshToken}
          : {'returnSecureToken': true};
      final uri = refresh
          ? Uri.https('securetoken.googleapis.com', '/v1/token',
              {'key': kFirebaseApiKey})
          : Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signUp',
              {'key': kFirebaseApiKey});
      final res = await _http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        // (إصلاح 2026-09-23) رمز تحديث منتهٍ/ملغى كان يدور في حلقة:
        // المحاولة تفشل ⇒ نُعيد بلا هوية ⇒ 401 ⇒ نُحاول التحديث نفسه.
        // الآن: نسقط الرمز التالف وننشئ هوية مجهولة جديدة فوراً (مرة واحدة).
        if (refresh && !retried) {
          _refreshToken = '';
          _idToken = '';
          _expiryMs = 0;
          return await _ensureAuth(force: true, retried: true);
        }
        lastAuthError =
            'تعذّر إنشاء هوية الدخول (${res.statusCode}) — تحقق من '
            'الاتصال ومن تفعيل Anonymous Auth في Firebase Console.';
        return _idToken;
      }
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return _idToken;
      _idToken = '${m['id_token'] ?? m['idToken'] ?? ''}';
      _refreshToken = '${m['refresh_token'] ?? m['refreshToken'] ?? ''}';
      final exp = '${m['expires_in'] ?? m['expiresIn'] ?? '3600'}';
      _expiryMs = DateTime.now().millisecondsSinceEpoch +
          (int.tryParse(exp) ?? 3600) * 1000;
      lastAuthError = '';
      await _persistSession();
    } catch (e) {
      lastAuthError = 'تعذّر الاتصال بخادم الهوية: $e';
    }
    return _idToken;
  }

  /// توقيع الدخول بهوية **المدير** الثابتة عبر رمز التحديث: نفس الهوية
  /// (user_id) في كل مرة، وهو ما تشترطه قواعد الكتابة على الاشتراك.
  Future<String> _signInAsAdmin() async {
    try {
      final res = await _http
          .post(
              Uri.https('securetoken.googleapis.com', '/v1/token',
                  {'key': kFirebaseApiKey}),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'grant_type': 'refresh_token',
                'refresh_token': adminRefreshToken,
              }))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        lastAuthError =
            'رفض خادم الهوية رمز المدير (${res.statusCode}) — أعد لصق رمز '
            'هوية المدير من ⚙️.';
        return _idToken;
      }
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return _idToken;
      _idToken = asStr(m['id_token']);
      final rt = asStr(m['refresh_token']);
      if (rt.isNotEmpty) adminRefreshToken = rt;
      final uid = asStr(m['user_id']);
      if (uid.isNotEmpty) adminUid = uid;
      _expiryMs = DateTime.now().millisecondsSinceEpoch +
          (int.tryParse(asStr(m['expires_in'])) ?? 3600) * 1000;
      lastAuthError = '';
      await _persistSession();
    } catch (e) {
      lastAuthError = 'تعذّر الاتصال بخادم الهوية: $e';
    }
    return _idToken;
  }

  /// إعادة توقيع الدخول (تُستدعى عند 401) — يبطل الكاش ويطلب رمزاً جديداً.
  Future<String> _reauth() async {
    _idToken = '';
    _expiryMs = 0;
    return _ensureAuth(force: true);
  }

  Future<void> save(String url, String auth) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl; // فارغ = عودة للرسمي.
    authToken = auth.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, baseUrl);
    await sp.setString(_kAuth, authToken);
    // (إصلاح) تغيّر الرابط يعني قاعدة أخرى — كاش الساعة القديم لا يصلح لها.
    resetClockCache();
  }

  bool get configured => baseUrl.isNotEmpty;

  Future<Uri> _u(String path, [Map<String, String>? q, String? token]) async {
    final qp = <String, String>{...?q};
    final t = token ?? await _ensureAuth();
    if (t.isNotEmpty) qp['auth'] = t;
    return Uri.parse('$baseUrl/$path.json')
        .replace(queryParameters: qp.isEmpty ? null : qp);
  }

  /// رسالة خطأ مقروءة: 401/403 ⇒ مشكلة هوية لا مشكلة بيانات.
  Exception _fail(String verb, String path, int code, String body) {
    if (code == 401 || code == 403) {
      return Exception(
          'رفضت القاعدة $verb «$path»: تحتاج هوية مسجّلة (auth != null).\n'
          '${lastAuthError.isNotEmpty ? lastAuthError : 'فعّل Anonymous Auth في Firebase Console أو الصق توكن صالح من ⚙️.'}');
    }
    return Exception('$verb $path فشل ($code): $body');
  }

  /// قراءة عقدة من RTDB (متاحة للواجهات وللاستعلام المباشر).
  Future<dynamic> getJson(String path, [Map<String, String>? q]) => _get(path, q);

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    var r = await _http
        .get(await _u(path, q))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .get(await _u(path, q, fresh))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('قراءة', path, r.statusCode, r.body);
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<void> _patch(String path, Map<String, dynamic> body) async {
    var r = await _http
        .patch(await _u(path), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .patch(await _u(path, null, fresh), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('كتابة', path, r.statusCode, r.body);
    }
  }

  Future<void> _put(String path, Object body) async {
    var r = await _http
        .put(await _u(path), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .put(await _u(path, null, fresh), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('كتابة', path, r.statusCode, r.body);
    }
  }

  /// وقت خادم فيربيس الحقيقي — نكتب {".sv":"timestamp"} ونقرأ الناتج.
  /// كل الحسابات الزمنية بساعة الخادم حصراً، لا ساعة الهاتف.
  ///
  /// (إصلاح أداء) القراءة مُخزّنة مؤقتاً [kClockTtl] وتُسند بينها بساعة
  /// أحادية: التفعيل والتمديد والإحصائيات في جلسة واحدة تستهلك قياساً
  /// واحداً بدل طلبين لكل عملية.
  static const Duration kClockTtl = _clockTtl;

  Future<int> serverNowMs({bool force = false}) async {
    if (!force && _clockMs > 0 && _clockAge.elapsed < _clockTtl) {
      return _clockMs + _clockAge.elapsedMilliseconds;
    }
    await _put('server_clock', {'.sv': 'timestamp'});
    final v = await _get('server_clock');
    final ms = asMs(v);
    if (ms <= 0) throw Exception('تعذّر قراءة ساعة الخادم');
    _clockMs = ms;
    _clockAge
      ..reset()
      ..start();
    return ms;
  }

  /// تنفيذ مهام غير متزامنة بتوازٍ محدود، مع حفظ ترتيب النتائج.
  ///
  /// المسح المتسلسل لعشرات المساحات (طلب HTTP لكل واحدة) كان يستغرق عشرات
  /// الثواني على الجوال فيبدو التفعيل معلّقاً. ست مهام متزامنة تحسم البحث
  /// في أقل من ثانيتين بلا إغراق القاعدة.
  Future<List<T>> _gather<T>(List<Future<T?> Function()> tasks,
      {int limit = 6}) async {
    if (tasks.isEmpty) return const [];
    final out = List<T?>.filled(tasks.length, null);
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= tasks.length) return;
        try {
          out[i] = await tasks[i]();
        } catch (_) {
          // مساحة بلا صلاحية/محذوفة — نتجاوزها ولا نُسقط البحث كله.
        }
      }
    }

    final workers = limit < tasks.length ? limit : tasks.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return out.whereType<T>().toList();
  }

  /// يحسم مرشح الجهاز داخل مساحة واحدة: (1) سجل التفعيلات الإداري،
  /// (2) roster الأجهزة. يعيد null إن لم يظهر المعرف في هذه المساحة.
  Future<_DevHit?> _scanWorkspaceForDevice(String ws, String devId) async {
    final enc = Uri.encodeComponent(ws);
    // (1) سجل إداري سابق بنفس المعرف.
    try {
      final logs = await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        for (final v in logs.values) {
          if (v is Map && asStr(v['device_ref']).trim().toUpperCase() == devId) {
            return _DevHit(ws: ws, planned: 1, viaLog: true);
          }
        }
      }
    } catch (_) {}

    // (2) roster أجهزة المساحة.
    try {
      final roster = await _get('workspaces/$enc/roster');
      if (roster is Map) {
        for (final e in roster.entries) {
          if ('${e.key}'.toUpperCase() != devId) continue;
          final row = e.value is Map ? e.value as Map : const {};
          Map? sub;
          try {
            final s = await _get('workspaces/$enc/subscription');
            if (s is Map) sub = s;
          } catch (_) {}
          return _DevHit(
            ws: ws,
            sync: _msOf(row['last_sync_at']),
            seen: _msOf(row['last_seen_at']),
            upd: _msOf(row['updated_at']),
            owner: asInt(row['is_owner']),
            planned: (sub != null && asStr(sub['plan_type']).isNotEmpty) ? 1 : 0,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  static int _msOf(Object? v) =>
      DateTime.tryParse(asStr(v))?.millisecondsSinceEpoch ?? asMs(v);

  /// تحويل المدخل إلى معرف مساحة عمل — يقبل ثلاثة أشكال تلقائياً:
  ///  1) بصمة التفعيل (32 خانة hex) ⇒ فهرس trials/(fp).
  ///  2) معرف الجهاز (DEVICE-XXXXXXXX) ⇒ بحث في roster كل المساحات.
  ///  3) معرف مساحة العمل مباشرة ⇒ تحقق من وجود العقدة.
  Future<String> resolveWorkspaceId(String input) async {
    final id = input.trim();
    if (id.isEmpty) throw Exception('أدخل معرف الجهاز أو مساحة العمل أولاً');

    // (1) بصمة تفعيل 32-hex.
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      final t = await _get('trials/${Uri.encodeComponent(id)}');
      if (t is Map && asStr(t['workspace_id']).isNotEmpty) {
        return asStr(t['workspace_id']);
      }
      throw Exception('لم يُعثر على مساحة عمل مرتبطة بهذه البصمة.\n'
          'تأكد أن العميل فتح التطبيق مرة واحدة على الأقل بعد التثبيت.');
    }

    // (1-ب) كود ترخيص NX-…
    if (id.toUpperCase().startsWith('NX-')) {
      final trials = await _get('trials');
      if (trials is Map) {
        for (final v in trials.values) {
          if (v is! Map) continue;
          final lk = asStr(v['licenseKey'] ?? v['license_key']).toUpperCase();
          if (lk == id.toUpperCase() && asStr(v['workspace_id']).isNotEmpty) {
            return asStr(v['workspace_id']);
          }
        }
      }
    }

    // (2) معرف جهاز DEVICE-… ⇒ بحث متعدد الطبقات + ربط تلقائي:
    //     (أ) فهرس /trials (device_id)، (ب) مسح متوازٍ محدود لسجلات
    //     التفعيل وroster كل مساحة، (ج) الربط التلقائي عند مرشح وحيد.
    //     عند العثور عبر مسار غير مفهرس نكتب device_id في /trials
    //     ليكون البحث القادم فورياً.
    if (RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(id)) {
      final devId = id.toUpperCase();

      // (أ) فهرس التجارب — أرخص مسح، ويجمع مرشحي الربط التلقائي.
      final trials = await _get('trials');
      final unlabeled = <String>{}; // مساحات بلا device_id في فهرسها.
      if (trials is Map) {
        for (final v in trials.values) {
          if (v is! Map) continue;
          final ws = asStr(v['workspace_id']);
          if (asStr(v['device_id']).toUpperCase() == devId && ws.isNotEmpty) {
            return ws;
          }
          if (ws.isNotEmpty && asStr(v['device_id']).isEmpty) {
            unlabeled.add(ws);
          }
        }
      }

      // (ب) مسح المساحات — **طلب واحد** لمفاتيح المساحات (كان يُطلق مرتين
      // في الشكل القديم) ثم مسح متوازٍ بسقف [kMaxWorkspaceScan].
      final keys = await _get('workspaces', {'shallow': 'true'});
      final wsKeys = keys is Map
          ? keys.keys.map((k) => '$k').take(kMaxWorkspaceScan).toList()
          : <String>[];

      final hits = await _gather<_DevHit>(
        [for (final ws in wsKeys) () => _scanWorkspaceForDevice(ws, devId)],
      );

      if (hits.length == 1) {
        final ws = hits.first.ws;
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }
      if (hits.length > 1) {
        hits.sort(_DevHit.rank);
        final best = hits.first;
        final runnerUp = hits[1];
        final decided = best.sync > runnerUp.sync ||
            best.seen > runnerUp.seen ||
            best.planned > runnerUp.planned;
        final ws = best.ws;
        if (decided) {
          await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
          return ws;
        }
        throw Exception(
            'هذا الجهاز موجود في أكثر من مساحة عمل ولا يمكن الحسم تلقائياً:\n'
            '${hits.map((h) => '• ${h.ws}').join('\n')}\n'
            'ألصق معرف المساحة الصحيح مباشرة، أو بصمة التفعيل (32 خانة) من '
            'رسالة العميل.');
      }

      // (ج) الربط التلقائي — الجهاز الفردي لا يظهر في أي roster وسجله
      // القديم في /trials بلا device_id بعد:
      //   • مساحة وحيدة في القاعدة كلها ⇒ هي مساحة العميل حتماً.
      //   • أو مرشح وحيد غير موسوم في الفهرس ⇒ نربطه به فوراً.
      if (wsKeys.length == 1) {
        await _linkDeviceToWorkspace(
            deviceId: devId, workspaceId: wsKeys.first);
        return wsKeys.first;
      }
      if (unlabeled.length == 1) {
        final ws = unlabeled.first;
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }

      throw Exception(unlabeled.length > 1
          ? 'المعرف غير موسوم بعد ويوجد ${unlabeled.length} عملاء غير '
              'موسومين — لا يمكن الحسم تلقائياً.\n'
              'ألصق «بصمة التفعيل» (32 خانة) من رسالة العميل، أو اطلب منه '
              'فتح التطبيق مرة واحدة بعد التحديث ليُوسم تلقائياً.'
          : 'لم يُعثر على جهاز بهذا المعرف في أي مساحة عمل.\n'
              'جرّب لصق «بصمة التفعيل» من رسالة العميل بدلاً منه.');
    }

    // (3) معرف مساحة مباشر — نتحقق من وجود عقدة الاشتراك أو المساحة.
    final sub = await _get('workspaces/${Uri.encodeComponent(id)}/subscription');
    if (sub != null) return id;
    final ws =
        await _get('workspaces/${Uri.encodeComponent(id)}', {'shallow': 'true'});
    if (ws != null) return id;
    throw Exception('لا توجد مساحة عمل بهذا المعرف في قاعدة البيانات.');
  }

  /// (الربط التلقائي) وسم سجل /trials الخاص بالمساحة بمعرف الجهاز —
  /// البحث القادم بنفس المعرف يصبح فورياً من الفهرس. تحسيني: فشله
  /// لا يمنع إتمام التفعيل الجاري.
  Future<void> _linkDeviceToWorkspace({
    required String deviceId,
    required String workspaceId,
  }) async {
    try {
      final trials = await _get('trials');
      if (trials is! Map) return;
      for (final e in trials.entries) {
        final v = e.value;
        if (v is Map && asStr(v['workspace_id']) == workspaceId) {
          if (asStr(v['device_id']).isEmpty) {
            await _patch('trials/${Uri.encodeComponent('${e.key}')}',
                {'device_id': deviceId});
          }
          return;
        }
      }
    } catch (_) {}
  }

  /// التفعيل/الترقية: تحديث عقدة الاشتراك في المكان (PATCH يحفظ الحقول
  /// الأخرى مثل created_at وdevice_fingerprint) وفتح كل المزايا.
  Future<ActivationResult> activate({
    required String rawInput,
    required String planType, // individual | enterprise
    required PlanDuration duration,
    required int maxDevices,
    bool extend = false, // تمديد: يضيف المدة فوق expires_at الحالي إن كان أبعد.
    String clientName = '',
    String storeName = '',
    String phone = '',
    String? licenseKey,
  }) async {
    final plan = planType == 'enterprise' ? 'enterprise' : 'individual';
    final seats = plan == 'enterprise' ? (maxDevices < 2 ? 2 : maxDevices) : 1;
    final ws = await resolveWorkspaceId(rawInput);
    final now = await serverNowMs();
    final lifetime = duration == PlanDuration.lifetime;
    final enc = Uri.encodeComponent(ws);

    int base = now;
    Map? existingSub;
    if (extend) {
      final cur = await _get('workspaces/$enc/subscription');
      if (cur is Map) {
        existingSub = cur;
        final curExp = asMs(cur['expires_at'] ?? cur['expiryDate']);
        if (curExp > now) base = curExp; // التمديد يبني على المتبقي.
      }
    } else {
      try {
        final cur = await _get('workspaces/$enc/subscription');
        if (cur is Map) existingSub = cur;
      } catch (_) {}
    }
    final expires = base + duration.span.inMilliseconds;

    // استخراج أو إبقاء القيم الحالية إذا لم تُمرّر
    final cName = clientName.trim().isNotEmpty
        ? clientName.trim()
        : asStr(existingSub?['clientName'] ??
            existingSub?['client_name'] ??
            existingSub?['userName'] ??
            existingSub?['user_name'] ??
            existingSub?['owner_name']);
    final sName = storeName.trim().isNotEmpty
        ? storeName.trim()
        : asStr(existingSub?['storeName'] ??
            existingSub?['store_name'] ??
            existingSub?['businessName'] ??
            existingSub?['business_name']);
    final ph = phone.trim().isNotEmpty
        ? phone.trim()
        : asStr(existingSub?['phone'] ?? existingSub?['whatsapp']);
    final devId = rawInput.trim().toUpperCase().startsWith('DEVICE-')
        ? rawInput.trim().toUpperCase()
        : asStr(existingSub?['deviceId'] ??
            existingSub?['device_id'] ??
            existingSub?['device_fingerprint']);
    final key = (licenseKey != null && licenseKey.trim().isNotEmpty)
        ? licenseKey.trim()
        : asStr(existingSub?['licenseKey'] ?? existingSub?['license_key'])
                .isNotEmpty
            ? asStr(existingSub?['licenseKey'] ?? existingSub?['license_key'])
            : generateLicenseKey(devId.isNotEmpty ? devId : ws);

    final licenseObj = {
      // الحقول الإجبارية بنموذج الترخيص (Requirement 2)
      'clientName': cName,
      'storeName': sName,
      'phone': ph,
      'deviceId': devId,
      'licenseKey': key,
      'expiryDate': expires,
      'status': 'active',

      // أسماء التوافق الرجعي
      'client_name': cName,
      'store_name': sName,
      'device_id': devId,
      'license_key': key,
      'is_active': true,
      'plan_type': plan,
      'max_devices': seats,
      'expires_at': expires,
      'activated_at': now,
      'updated_at': now,
      'activated_by': 'license_admin',
      'workspace_id': ws,
      'features': {
        'can_use_categories': true,
        'can_send_notifications': true,
        'can_cloud_backup': true,
        'can_restore_data': true,
        'can_advanced_search': true,
        'multi_device_sync': true,
        'role_permissions': true,
        'audit_log': true,
      },
    };

    await _patch('workspaces/$enc/subscription', licenseObj);
    try {
      await _put('workspaces/$enc/license', licenseObj);
    } catch (_) {}

    // مزامنة فهرس /trials (مصدر العدادات المجمعة): التفعيل يقلب حالة
    // المساحة فيه أيضاً حتى تعكس بطاقة «مشتركون مدفوعون» الحقيقة فوراً.
    try {
      final cur = await _get('workspaces/$enc/subscription');
      final fp = cur is Map ? asStr(cur['device_fingerprint']) : '';
      if (fp.isNotEmpty) {
        await _patch('trials/${Uri.encodeComponent(fp)}', {
          'clientName': cName,
          'storeName': sName,
          'phone': ph,
          'deviceId': devId,
          'licenseKey': key,
          'expiryDate': expires,
          'status': 'active',
          'expires_at': expires,
          'workspace_id': ws,
        });
      }
    } catch (_) {} // الفهرس تحسيني — فشله لا يفسد التفعيل.

    // (إصلاح 2026-09-22) سجل إداري داخل **مساحة العمل نفسها**: العقدة
    // العامة /admin محجوبة في قواعد RTDB (الافتراضي = رفض) فكانت كتابة
    // السجل تُسقط التفعيل كله بعد نجاح تحديث الاشتراك. المسار الجديد
    // مسموح بقاعدة workspaces القائمة — بلا تعديل يدوي للقواعد.
    try {
      await _put('workspaces/$enc/admin_log/$now', {
        ...licenseObj,
        'device_ref': rawInput.trim(),
        'lifetime': lifetime,
        if (extend) 'extended': true,
      });
    } catch (_) {
      // السجل تحسيني: لا يُفسد نجاح التفعيل.
    }

    return ActivationResult(
      workspaceId: ws,
      planType: plan,
      maxDevices: seats,
      expiresAtMs: expires,
      lifetime: lifetime,
      clientName: cName,
      storeName: sName,
      phone: ph,
      licenseKey: key,
      deviceId: devId,
    );
  }

  /// آخر الاشتراكات المفعلة مع الحالة الحية لكل مساحة.
  ///
  /// (إصلاح 2026-09-22) السجل الإداري صار داخل كل مساحة
  /// (`workspaces/<ws>/admin_log`) لأن العقدة العامة `/admin` محجوبة
  /// بالقواعد؛ نقرأ مفاتيح المساحات (طلب واحد) ثم سجل كل مساحة — بحد
  /// أقصى [kMaxSubscriberScan] حتى لا نختنق، ونرتب تنازلياً بالتاريخ.
  ///
  /// (إصلاح 2026-09-23) القراءة أصبحت متوازية محدودة بدل مسح متسلسل،
  /// وتحويل الحقول الرقمية موحّد عبر asInt/asMs — كان تعبير maxDevices
  /// القديم يقرأ أولوية العوامل خطأ فيُظهر «1 جهاز» لمشترك مؤسسة.
  Future<List<SubscriberEntry>> recentSubscribers({int limit = 30}) async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) return const [];
    final wsKeys =
        keys.keys.map((k) => '$k').take(kMaxSubscriberScan).toList();

    // قراءة فهرس /trials لربط بيانات المتاجر والعملاء
    Map? trialIdx;
    try {
      final t = await _get('trials');
      if (t is Map) trialIdx = t;
    } catch (_) {}

    final trialByWs = <String, Map>{};
    if (trialIdx != null) {
      for (final v in trialIdx.values) {
        if (v is Map) {
          final ws = asStr(v['workspace_id']);
          if (ws.isNotEmpty && !trialByWs.containsKey(ws)) {
            trialByWs[ws] = v;
          }
        }
      }
    }

    final rows = await _gather<List<SubscriberEntry>>(
      [
        for (final ws in wsKeys)
          () => _readWorkspaceEntries(ws, trialFallback: trialByWs[ws])
      ],
    );
    final out = rows.expand((r) => r).toList();
    out.sort((a, b) => b.activatedAtMs.compareTo(a.activatedAtMs));
    return out.take(limit).toList();
  }

  /// يقرأ مساحة واحدة: سجلها الإداري (إن وُجد) وإلا حالتها الحية.
  Future<List<SubscriberEntry>> _readWorkspaceEntries(String ws,
      {Map? trialFallback}) async {
    final enc = Uri.encodeComponent(ws);
    Map? live;
    try {
      final sub = await _get('workspaces/$enc/subscription');
      if (sub is Map) live = sub;
    } catch (_) {}
    try {
      final logs = await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        final out = <SubscriberEntry>[];
        for (final e in logs.entries) {
          final v = e.value;
          if (v is! Map) continue;

          final devId = _pick(
              live?['deviceId'],
              v['deviceId'],
              _pick(
                  live?['device_id'],
                  v['device_id'],
                  _pick(
                      trialFallback?['deviceId'],
                      trialFallback?['device_id'],
                      asStr(v['device_ref']))));

          final lKey = _pick(
              live?['licenseKey'],
              v['licenseKey'],
              _pick(
                  live?['license_key'],
                  v['license_key'],
                  _pick(trialFallback?['licenseKey'],
                      trialFallback?['license_key'], '')));

          final cName = _pick(
              live?['clientName'],
              v['clientName'],
              _pick(
                  live?['client_name'],
                  v['client_name'],
                  _pick(
                      live?['userName'],
                      v['userName'],
                      _pick(trialFallback?['clientName'],
                          trialFallback?['client_name'], ''))));

          final sName = _pick(
              live?['storeName'],
              v['storeName'],
              _pick(
                  live?['store_name'],
                  v['store_name'],
                  _pick(
                      live?['businessName'],
                      v['businessName'],
                      _pick(trialFallback?['storeName'],
                          trialFallback?['store_name'], ''))));

          final ph = _pick(
              live?['phone'],
              v['phone'],
              _pick(
                  live?['whatsapp'],
                  v['whatsapp'],
                  _pick(trialFallback?['phone'],
                      trialFallback?['whatsapp'], '')));

          out.add(SubscriberEntry(
            workspaceId: ws,
            planType: _pick(live?['plan_type'], v['plan_type'], 'individual'),
            status: _pick(live?['status'], null, 'active'),
            maxDevices:
                asInt(_firstNum(live?['max_devices'], v['max_devices']), 1),
            expiresAtMs: asMs(_firstNum(
                live?['expires_at'],
                _firstNum(live?['expiryDate'],
                    v['expires_at'] ?? v['expiryDate']))),
            activatedAtMs: asMs(v['activated_at']) > 0
                ? asMs(v['activated_at'])
                : asMs(e.key),
            deviceRef: asStr(v['device_ref']),
            clientName: cName,
            storeName: sName,
            phone: ph,
            deviceId: devId,
            licenseKey: lKey.isNotEmpty
                ? lKey
                : generateLicenseKey(devId.isNotEmpty ? devId : ws),
          ));
        }
        return out; // هذه المساحة موثّقة — لا حاجة للفرع التالي.
      }
    } catch (_) {}
    // مساحة بلا سجل إداري لكن لها اشتراك: تُعرض بحالتها الحية.
    if (live != null) {
      final devId = _pick(
          live['deviceId'],
          live['device_id'],
          _pick(trialFallback?['deviceId'], trialFallback?['device_id'],
              asStr(live['device_fingerprint'])));

      final lKey = _pick(
          live['licenseKey'],
          live['license_key'],
          _pick(trialFallback?['licenseKey'],
              trialFallback?['license_key'], ''));

      final cName = _pick(
          live['clientName'],
          live['client_name'],
          _pick(
              live['userName'],
              live['owner_name'],
              _pick(trialFallback?['clientName'],
                  trialFallback?['client_name'], '')));

      final sName = _pick(
          live['storeName'],
          live['store_name'],
          _pick(
              live['businessName'],
              live['business_name'],
              _pick(trialFallback?['storeName'],
                  trialFallback?['store_name'], '')));

      final ph = _pick(
          live['phone'],
          live['whatsapp'],
          _pick(trialFallback?['phone'], trialFallback?['whatsapp'], ''));

      return [
        SubscriberEntry(
          workspaceId: ws,
          planType: asStr(live['plan_type']).isEmpty
              ? 'individual'
              : asStr(live['plan_type']),
          status: asStr(live['status']),
          maxDevices: asInt(live['max_devices'], 1),
          expiresAtMs: asMs(live['expiryDate'] ?? live['expires_at']),
          activatedAtMs: asMs(live['activated_at']),
          deviceRef: devId,
          clientName: cName,
          storeName: sName,
          phone: ph,
          deviceId: devId,
          licenseKey: lKey.isNotEmpty
              ? lKey
              : generateLicenseKey(devId.isNotEmpty ? devId : ws),
        ),
      ];
    }
    return const [];
  }

  /// أول قيمة رقمية صالحة من مرشحين (الحالة الحية تسبق السجل).
  static Object? _firstNum(Object? a, Object? b) {
    if (a is num) return a;
    if (b is num) return b;
    final pa = int.tryParse(asStr(a));
    if (pa != null) return pa;
    final pb = int.tryParse(asStr(b));
    if (pb != null) return pb;
    return null;
  }

  static String _pick(Object? a, Object? b, String dflt) {
    final va = asStr(a).trim();
    if (va.isNotEmpty) return va;
    final vb = asStr(b).trim();
    return vb.isEmpty ? dflt : vb;
  }
}

/// مرشح مساحة عمل ظهر فيها معرف الجهاز — يُرتَّب بالأحدث نشاطاً.
class _DevHit {
  final String ws;
  final int sync;
  final int seen;
  final int upd;
  final int owner;
  final int planned;
  final bool viaLog;

  const _DevHit({
    required this.ws,
    this.sync = 0,
    this.seen = 0,
    this.upd = 0,
    this.owner = 0,
    this.planned = 0,
    this.viaLog = false,
  });

  /// الأحدث نشاطاً أولاً: مزامنة ⇐ ظهور ⇐ تحديث ⇐ مالك ⇐ خطة مكتملة.
  static int rank(_DevHit a, _DevHit b) {
    var c = b.sync.compareTo(a.sync);
    if (c != 0) return c;
    c = b.seen.compareTo(a.seen);
    if (c != 0) return c;
    c = b.upd.compareTo(a.upd);
    if (c != 0) return c;
    c = b.owner.compareTo(a.owner);
    if (c != 0) return c;
    return b.planned.compareTo(a.planned);
  }
}

/// إحصائيات لوحة المدير — تُقرأ حياً من قاعدة البيانات.
class AdminMetrics {
  final int totalWorkspaces; // إجمالي مساحات العمل المسجلة.
  final int activePaid; // مشتركون مدفوعون فعّالون.
  final int activeTrials; // في الفترة التجريبية (سارية).
  final int expired; // منتهية (تجربة أو اشتراك) = الفئة المجانية.

  /// مساحات بلا عقدة اشتراك أصلاً (لم تُفعّل تجربة بعد).
  final int noPlan;
  const AdminMetrics({
    required this.totalWorkspaces,
    required this.activePaid,
    required this.activeTrials,
    required this.expired,
    this.noPlan = 0,
  });
}

extension RtdbMetrics on Rtdb {
  /// جمع العدادات بلا اختناق: كان الشكل القديم يطلق طلب HTTP منفصلاً
  /// لكل مساحة (N+1). الآن قراءة مجمعة واحدة لفهرس /trials (يحمل
  /// status/expires_at لكل مساحة مفعّلة) + مفاتيح المساحات السطحية —
  /// طلبان اثنان مهما بلغ عدد العملاء، عبر عميل keep-alive موحد.
  ///
  /// (إصلاح 2026-09-23) المساحات غير المفهرسة تُقرأ بتوازٍ محدود بدل
  /// مسح متسلسل، والفئة الرابعة (بلا خطة) تُحصى صراحةً فلا يظهر الفرق
  /// بين «إجمالي المساحات» ومجموع البطاقات كأنه خطأ في الأرقام.
  Future<AdminMetrics> metrics() async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) {
      return const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0);
    }
    final now = await serverNowMs();

    // القراءة المجمعة: فهرس التجارب يحمل حالة كل مساحة مفعّلة.
    final trialIdx = await _get('trials');
    final byWs = <String, Map>{};
    if (trialIdx is Map) {
      for (final v in trialIdx.values) {
        if (v is Map) {
          final ws = asStr(v['workspace_id']);
          if (ws.isNotEmpty) byWs[ws] = v;
        }
      }
    }
    // مساحات غير مفهرسة في /trials (نادرة — قديمة جداً): قراءة مفردة
    // كاحتياط، بحد أقصى 25 حتى لا نعود للاختناق.
    final missing =
        keys.keys.map((k) => '$k').where((w) => !byWs.containsKey(w)).toList();
    if (missing.isNotEmpty) {
      await _gather<Map?>(
        [
          for (final ws in missing.take(25))
            () async {
              final enc = Uri.encodeComponent(ws);
              final sub = await _get('workspaces/$enc/subscription');
              if (sub is Map) {
                byWs[ws] = sub;
                return sub;
              }
              return null;
            }
        ],
      );
    }

    int paid = 0, trials = 0, expired = 0, noPlan = 0;
    for (final ws in keys.keys) {
      final sub = byWs['$ws'];
      if (sub == null) {
        noPlan++; // مساحة بلا عقدة اشتراك بعد.
        continue;
      }
      final status = asStr(sub['status']);
      final exp = asMs(sub['expires_at']);
      final alive = exp > now;
      if (status == 'active' && alive) {
        paid++;
      } else if (status == 'trial' && alive) {
        trials++;
      } else {
        expired++;
      }
    }
    return AdminMetrics(
      totalWorkspaces: keys.length,
      activePaid: paid,
      activeTrials: trials,
      expired: expired,
      noPlan: noPlan,
    );
  }
}
