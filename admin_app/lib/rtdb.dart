// خدمة Firebase RTDB عبر REST — نفس قاعدة بيانات تطبيق «مدير الحسابات».
// لا تحتاج SDK: قراءة/كتابة JSON مباشرة + وقت الخادم بختم {".sv":"timestamp"}.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
  const ActivationResult({
    required this.workspaceId,
    required this.planType,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.lifetime,
  });
}

/// سجل مشترك للعرض في القائمة.
class SubscriberEntry {
  final String workspaceId;
  final String planType;
  final String status;
  final int maxDevices;
  final int expiresAtMs;
  final int activatedAtMs;
  final String deviceRef; // المعرف/البصمة التي أُدخلت وقت التفعيل.
  const SubscriberEntry({
    required this.workspaceId,
    required this.planType,
    required this.status,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.activatedAtMs,
    required this.deviceRef,
  });
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

  static const _kUrl = 'rtdbUrl';
  static const _kAuth = 'rtdbAuth';
  static const _kIdToken = 'rtdbIdToken';
  static const _kRefresh = 'rtdbRefreshToken';
  static const _kExpiry = 'rtdbTokenExpiryMs';

  /// جلسة الهوية المجهولة (Firebase Auth) — تُرفق بكل طلب تلقائياً.
  String _idToken = '';
  String _refreshToken = '';
  int _expiryMs = 0;

  /// آخر خطأ مصادقة — للعرض في الواجهة بدل رسالة HTTP مبهمة.
  String lastAuthError = '';

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    baseUrl = (sp.getString(_kUrl) ?? '').trim();
    // (المعمارية الصامتة) لا رابط محفوظاً؟ اعتمد الرسمي المضمّن فوراً.
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = sp.getString(_kAuth) ?? '';
    _idToken = sp.getString(_kIdToken) ?? '';
    _refreshToken = sp.getString(_kRefresh) ?? '';
    _expiryMs = sp.getInt(_kExpiry) ?? 0;
    // (قانون 2026-09-22) الهوية تُبنى عند أول استخدام — لا عند الإقلاع،
    // حتى لا يعلق التطبيق على شاشة التحميل عند ضعف الشبكة.
  }

  Future<void> _persistSession() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kIdToken, _idToken);
    await sp.setString(_kRefresh, _refreshToken);
    await sp.setInt(_kExpiry, _expiryMs);
  }

  bool get _tokenAlive =>
      _idToken.isNotEmpty &&
      _expiryMs > DateTime.now().millisecondsSinceEpoch + 60000;

  /// هوية صالحة لكل طلب: توكن يدوي (إن أدخله المالك) وإلا هوية مجهولة
  /// تُنشأ/تُجدَّد تلقائياً. إخفاقها لا يمنع المحاولة — رسالة الخطأ
  /// توضّح السبب (401 ⇒ القاعدة ترفض بلا هوية).
  Future<String> _ensureAuth({bool force = false}) async {
    if (authToken.trim().isNotEmpty) return authToken.trim();
    if (!force && _tokenAlive) return _idToken;
    try {
      final body = force && _refreshToken.isNotEmpty
          ? {
              'grant_type': 'refresh_token',
              'refresh_token': _refreshToken,
            }
          : {'returnSecureToken': true};
      final uri = force && _refreshToken.isNotEmpty
          ? Uri.https('securetoken.googleapis.com', '/v1/token',
              {'key': kFirebaseApiKey})
          : Uri.https('identitytoolkit.googleapis.com',
              '/v1/accounts:signUp', {'key': kFirebaseApiKey});
      final res = await _http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
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
  Future<int> serverNowMs() async {
    await _put('server_clock', {'.sv': 'timestamp'});
    final v = await _get('server_clock');
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw Exception('تعذّر قراءة ساعة الخادم');
  }

  /// تحويل المدخل إلى معرف مساحة عمل — يقبل ثلاثة أشكال تلقائياً:
  ///  1) بصمة التفعيل (32 خانة hex من رسالة واتساب) ⇒ فهرس /trials/<fp>.
  ///  2) معرف الجهاز (DEVICE-XXXXXXXX) ⇒ بحث في roster كل المساحات.
  ///  3) معرف مساحة العمل مباشرة ⇒ تحقق من وجود العقدة.
  Future<String> resolveWorkspaceId(String input) async {
    final id = input.trim();
    if (id.isEmpty) throw Exception('أدخل معرف الجهاز أو مساحة العمل أولاً');

    // (1) بصمة تفعيل 32-hex.
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      final t = await _get('trials/${Uri.encodeComponent(id)}');
      if (t is Map && '${t['workspace_id'] ?? ''}'.isNotEmpty) {
        return '${t['workspace_id']}';
      }
      throw Exception('لم يُعثر على مساحة عمل مرتبطة بهذه البصمة.\n'
          'تأكد أن العميل فتح التطبيق مرة واحدة على الأقل بعد التثبيت.');
    }

    // (2) معرف جهاز DEVICE-… ⇒ بحث متعدد الطبقات + ربط تلقائي:
    //     (أ) فهرس /trials (device_id)، (ب) سجل التفعيلات الإداري،
    //     (ج) roster كل المساحات، (د) الربط التلقائي عند مرشح وحيد.
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
          final ws = '${v['workspace_id'] ?? ''}';
          if ('${v['device_id'] ?? ''}'.toUpperCase() == devId) {
            if (ws.isNotEmpty) return ws;
          }
          if (ws.isNotEmpty && '${v['device_id'] ?? ''}'.isEmpty) {
            unlabeled.add(ws);
          }
        }
      }

      // (ب) السجل الإداري داخل المساحات: تفعيل سابق بنفس المعرف.
      try {
        final wsKeys0 = await _get('workspaces', {'shallow': 'true'});
        if (wsKeys0 is Map) {
          for (final k in wsKeys0.keys.take(40)) {
            final logs = await _get(
                'workspaces/${Uri.encodeComponent('$k')}/admin_log');
            if (logs is! Map) continue;
            for (final v in logs.values) {
              if (v is Map &&
                  '${v['device_ref'] ?? ''}'.trim().toUpperCase() == devId) {
                return '$k';
              }
            }
          }
        }
      } catch (_) {}

      // (ج) مسح roster لكل مساحة عمل (أجهزة المجموعات).
      final keys = await _get('workspaces', {'shallow': 'true'});
      final wsKeys =
          keys is Map ? keys.keys.map((k) => '$k').toList() : <String>[];
      // (إصلاح 2026-09-22) الجهاز قد يظهر في عدة مساحات (مساحات قديمة
      // مكرّرة من تثبيتات سابقة). الحل القديم كان يردّ أول مطابقة —
      // فتُفعَّل مساحة ميتة ويبقى الترخيص «لا يعمل» عند العميل. القاعدة
      // الآن: نجمع كل المرشحين ونرجّح **الأحدث نشاطاً** (last_sync_at ثم
      // last_seen_at/updated_at ثم وجود خطة مكتملة)، فإن تعذّر الحسم
      // نُبلغ المدير بالمرشحين ليختار بدل التخمين الصامت.
      final hits = <Map<String, dynamic>>[];
      for (final ws in wsKeys) {
        Map? roster;
        try {
          final r =
              await _get('workspaces/${Uri.encodeComponent(ws)}/roster');
          if (r is Map) roster = r;
        } catch (_) {}
        if (roster == null) continue;
        for (final e in roster.entries) {
          if ('${e.key}'.toUpperCase() != devId) continue;
          final v = e.value;
          final row = v is Map ? v : const <String, Object?>{};
          Map? sub;
          try {
            final s2 = await _get(
                'workspaces/${Uri.encodeComponent(ws)}/subscription');
            if (s2 is Map) sub = s2;
          } catch (_) {}
          int msOf(Object? v2) =>
              DateTime.tryParse('${v2 ?? ''}')?.millisecondsSinceEpoch ?? 0;
          hits.add({
            'ws': ws,
            'sync': msOf(row['last_sync_at']),
            'seen': msOf(row['last_seen_at']),
            'upd': msOf(row['updated_at']),
            'owner': (row['is_owner'] is num)
                ? (row['is_owner'] as num).toInt()
                : 0,
            'planned': (sub != null && '${sub['plan_type'] ?? ''}'.isNotEmpty)
                ? 1
                : 0,
          });
          break;
        }
      }
      if (hits.length == 1) {
        final ws = '${hits.first['ws']}';
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }
      if (hits.length > 1) {
        hits.sort((a, b) {
          final c = (b['sync'] as int).compareTo(a['sync'] as int);
          if (c != 0) return c;
          final c2 = (b['seen'] as int).compareTo(a['seen'] as int);
          if (c2 != 0) return c2;
          final c3 = (b['upd'] as int).compareTo(a['upd'] as int);
          if (c3 != 0) return c3;
          final c4 = (b['owner'] as int).compareTo(a['owner'] as int);
          if (c4 != 0) return c4;
          return (b['planned'] as int).compareTo(a['planned'] as int);
        });
        final best = hits.first;
        final runnerUp = hits[1];
        final decided = (best['sync'] as int) > (runnerUp['sync'] as int) ||
            (best['planned'] as int) > (runnerUp['planned'] as int);
        final ws = '${best['ws']}';
        if (decided) {
          await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
          return ws;
        }
        throw Exception(
            'هذا الجهاز موجود في أكثر من مساحة عمل ولا يمكن الحسم تلقائياً:\n'
            '${hits.map((h) => '• ${h['ws']}').join('\n')}\n'
            'ألصق معرف المساحة الصحيح مباشرة، أو بصمة التفعيل (32 خانة) من '
            'رسالة العميل.');
      }

      // (د) الربط التلقائي — الجهاز الفردي لا يظهر في أي roster وسجله
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
    final ws = await _get('workspaces/${Uri.encodeComponent(id)}',
        {'shallow': 'true'});
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
        if (v is Map && '${v['workspace_id'] ?? ''}' == workspaceId) {
          if ('${v['device_id'] ?? ''}'.isEmpty) {
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
  }) async {
    final ws = await resolveWorkspaceId(rawInput);
    final now = await serverNowMs();
    final lifetime = duration == PlanDuration.lifetime;

    int base = now;
    if (extend) {
      final cur = await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
      if (cur is Map) {
        final e = cur['expires_at'];
        final curExp = e is num ? e.toInt() : 0;
        if (curExp > now) base = curExp; // التمديد يبني على المتبقي.
      }
    }
    final expires = base + duration.span.inMilliseconds;

    await _patch('workspaces/${Uri.encodeComponent(ws)}/subscription', {
      'status': 'active',
      'is_active': true,
      'plan_type': planType,
      'max_devices': planType == 'enterprise' ? maxDevices : 1,
      'expires_at': expires,
      'activated_at': now,
      'activated_by': 'license_admin',
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
    });

    // مزامنة فهرس /trials (مصدر العدادات المجمعة): التفعيل يقلب حالة
    // المساحة فيه أيضاً حتى تعكس بطاقة «مشتركون مدفوعون» الحقيقة فوراً.
    try {
      final cur =
          await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
      final fp = cur is Map ? '${cur['device_fingerprint'] ?? ''}' : '';
      if (fp.isNotEmpty) {
        await _patch('trials/${Uri.encodeComponent(fp)}', {
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
      await _put(
          'workspaces/${Uri.encodeComponent(ws)}/admin_log/$now', {
        'workspace_id': ws,
        'device_ref': rawInput.trim(),
        'plan_type': planType,
        'max_devices': planType == 'enterprise' ? maxDevices : 1,
        'expires_at': expires,
        'activated_at': now,
        'lifetime': lifetime,
      });
    } catch (_) {
      // السجل تحسيني: لا يُفسد نجاح التفعيل.
    }

    return ActivationResult(
      workspaceId: ws,
      planType: planType,
      maxDevices: planType == 'enterprise' ? maxDevices : 1,
      expiresAtMs: expires,
      lifetime: lifetime,
    );
  }

  /// آخر الاشتراكات المفعلة مع الحالة الحية لكل مساحة.
  ///
  /// (إصلاح 2026-09-22) السجل الإداري صار داخل كل مساحة
  /// (`workspaces/<ws>/admin_log`) لأن العقدة العامة `/admin` محجوبة
  /// بالقواعد؛ نقرأ مفاتيح المساحات (طلب واحد) ثم سجل كل مساحة —
  /// بحد أقصى 40 مساحة حتى لا نختنق، ونرتب تنازلياً بالتاريخ.
  Future<List<SubscriberEntry>> recentSubscribers({int limit = 30}) async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) return const [];
    final out = <SubscriberEntry>[];
    for (final k in keys.keys.take(40)) {
      final ws = '$k';
      final enc = Uri.encodeComponent(ws);
      Map? live;
      try {
        final sub = await _get('workspaces/$enc/subscription');
        if (sub is Map) live = sub;
      } catch (_) {}
      try {
        final logs = await _get('workspaces/$enc/admin_log');
        if (logs is Map) {
          for (final e in logs.entries) {
            final v = e.value;
            if (v is! Map) continue;
            out.add(SubscriberEntry(
              workspaceId: ws,
              planType: '${(live?['plan_type']) ?? v['plan_type'] ?? 'individual'}',
              status: '${(live?['status']) ?? 'active'}',
              maxDevices: ((live?['max_devices']) ?? v['max_devices'] is num
                      ? ((live?['max_devices']) ?? (v['max_devices'] as num))
                      : 1) is num
                  ? (((live?['max_devices']) ?? v['max_devices']) as num).toInt()
                  : 1,
              expiresAtMs: (((live?['expires_at']) ?? v['expires_at']) is num)
                  ? (((live?['expires_at']) ?? v['expires_at']) as num).toInt()
                  : 0,
              activatedAtMs: (v['activated_at'] is num)
                  ? (v['activated_at'] as num).toInt()
                  : (int.tryParse('${e.key}') ?? 0),
              deviceRef: '${v['device_ref'] ?? ''}',
            ));
          }
          continue; // هذه المساحة موثّقة — لا حاجة للفرع التالي.
        }
      } catch (_) {}
      // مساحة بلا سجل إداري لكن لها اشتراك: تُعرض بحالتها الحية.
      if (live != null) {
        out.add(SubscriberEntry(
          workspaceId: ws,
          planType: '${live['plan_type'] ?? 'individual'}',
          status: '${live['status'] ?? ''}',
          maxDevices: (live['max_devices'] is num)
              ? (live['max_devices'] as num).toInt()
              : 1,
          expiresAtMs:
              (live['expires_at'] is num) ? (live['expires_at'] as num).toInt() : 0,
          activatedAtMs: (live['activated_at'] is num)
              ? (live['activated_at'] as num).toInt()
              : 0,
          deviceRef: '${live['device_fingerprint'] ?? ''}',
        ));
      }
    }
    out.sort((a, b) => b.activatedAtMs.compareTo(a.activatedAtMs));
    return out.take(limit).toList();
  }
}

/// إحصائيات لوحة المدير — تُقرأ حياً من قاعدة البيانات.
class AdminMetrics {
  final int totalWorkspaces; // إجمالي مساحات العمل المسجلة.
  final int activePaid; // مشتركون مدفوعون فعّالون.
  final int activeTrials; // في الفترة التجريبية (سارية).
  final int expired; // منتهية (تجربة أو اشتراك) = الفئة المجانية.
  const AdminMetrics({
    required this.totalWorkspaces,
    required this.activePaid,
    required this.activeTrials,
    required this.expired,
  });
}

extension RtdbMetrics on Rtdb {
  /// جمع العدادات بلا اختناق: كان الشكل القديم يطلق طلب HTTP منفصلاً
  /// لكل مساحة (N+1). الآن قراءة مجمعة واحدة لفهرس /trials (يحمل
  /// status/expires_at لكل مساحة مفعّلة) + مفاتيح المساحات السطحية —
  /// طلبان اثنان مهما بلغ عدد العملاء، عبر عميل keep-alive موحد.
  Future<AdminMetrics> metrics() async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) {
      return const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0);
    }
    final now = await serverNowMs();
    int paid = 0, trials = 0, expired = 0;

    // القراءة المجمعة: فهرس التجارب يحمل حالة كل مساحة مفعّلة.
    final trialIdx = await _get('trials');
    final byWs = <String, Map>{};
    if (trialIdx is Map) {
      for (final v in trialIdx.values) {
        if (v is Map) {
          final ws = '${v['workspace_id'] ?? ''}';
          if (ws.isNotEmpty) byWs[ws] = v;
        }
      }
    }
    // مساحات غير مفهرسة في /trials (نادرة — قديمة جداً): قراءة مفردة
    // كاحتياط، بحد أقصى 25 حتى لا نعود للاختناق.
    final missing =
        keys.keys.map((k) => '$k').where((w) => !byWs.containsKey(w)).toList();
    for (final ws in missing.take(25)) {
      try {
        final sub =
            await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
        if (sub is Map) byWs[ws] = sub;
      } catch (_) {}
    }

    for (final ws in keys.keys) {
      final sub = byWs['$ws'];
      if (sub == null) continue; // مساحة بلا عقدة اشتراك بعد.
      final status = '${sub['status'] ?? ''}';
      final e = sub['expires_at'];
      final exp = e is num ? e.toInt() : 0;
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
    );
  }
}
