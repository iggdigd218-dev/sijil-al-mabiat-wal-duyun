// (معمارية حساب Google) مصادقة Firebase عبر REST — بدون SDK إضافي.
//
// google_sign_in يجلب idToken من حساب Google، وهذه الخدمة تبادله مع
// Firebase Identity Toolkit (accounts:signInWithIdp) فيصدر uid الرسمي
// نفسه الذي تصدره حزمة firebase_auth تماماً — فيصبح هوية المؤسسة
// الدائمة عبر الأجهزة: مساحة العمل WS-{uid} والترخيص مربوطان به.
//
// Offline-First: الجلسة تُحفظ محلياً (settings) بعد أول دخول ناجح —
// التطبيق يعمل كاملاً بلا إنترنت ولا يُطلب تسجيل الدخول في كل مرة.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/auth_config.dart';
import '../repository.dart';

class FirebaseAccount {
  final String uid; // localId — معرف المستخدم الرسمي في Firebase
  final String email;
  final String displayName;
  const FirebaseAccount({
    required this.uid,
    required this.email,
    this.displayName = '',
  });
}

class FirebaseAuthRest {
  FirebaseAuthRest._();

  static const uidKey = 'account.uid';
  static const emailKey = 'account.email';
  static const nameKey = 'account.name';

  /// تبادل idToken الخاص بـ Google مع Firebase للحصول على uid الرسمي.
  /// يعيد null عند غياب المفاتيح أو فشل الشبكة/التبادل.
  static Future<FirebaseAccount?> signInWithGoogleIdToken(
      String googleIdToken) async {
    final key = effectiveFirebaseApiKey;
    if (key.isEmpty || googleIdToken.isEmpty) return null;
    try {
      final uri = Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp'
          '?key=$key');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'postBody':
                  'id_token=$googleIdToken&providerId=google.com',
              'requestUri': 'http://localhost',
              'returnSecureToken': true,
              'returnIdpCredential': true,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return null;
      final uid = '${m['localId'] ?? ''}'.trim();
      if (uid.isEmpty) return null;
      return FirebaseAccount(
        uid: uid,
        email: '${m['email'] ?? ''}',
        displayName: '${m['displayName'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// حفظ الجلسة محلياً — تبقى صالحة بلا إنترنت (لا انتهاء محلي).
  static Future<void> saveSession(Repo repo, FirebaseAccount a) async {
    await repo.setSetting(uidKey, a.uid);
    await repo.setSetting(emailKey, a.email);
    await repo.setSetting(nameKey, a.displayName);
  }

  /// uid المحفوظ محلياً ('' إن لم يسجل الدخول بعد).
  static Future<String> savedUid(Repo repo) async =>
      ((await repo.settings())[uidKey] ?? '').trim();

  static Future<String> savedEmail(Repo repo) async =>
      ((await repo.settings())[emailKey] ?? '').trim();

  static Future<void> clearSession(Repo repo) async {
    await repo.setSetting(uidKey, '');
    await repo.setSetting(emailKey, '');
    await repo.setSetting(nameKey, '');
  }

  // ══════ (المرحلة 2) مصادقة مجهولة صامتة — هوية جهاز دائمة ══════
  //
  // الهدف: كل طلب إلى RTDB يحمل `?auth=<idToken>` صالحاً، فتستطيع قواعد
  // الأمان الاعتماد على `auth.uid` بدل ترك القاعدة مفتوحة للعامة.
  //
  // تُنفَّذ عبر Identity Toolkit REST (نفس عائلة `accounts:signInWithIdp`
  // المستخدمة أعلاه): `accounts:signUp` بلا بيانات = حساب مجهول حقيقي،
  // فيصدر `localId` و`idToken` مطابقين تماماً لما يصدره Firebase Anonymous
  // Auth — بلا SDK، وبلا الحاجة إلى `Firebase.initializeApp()` أو ملفات
  // `google-services.json` / `GoogleService-Info.plist`.

  static const anonUidKey = 'cloud.anon.uid';
  static const _anonIdTokenKey = 'cloud.anon.idToken';
  static const _anonRefreshKey = 'cloud.anon.refresh';
  static const _anonExpiryKey = 'cloud.anon.expiryMs';

  static String? _anonUid;
  static String? _anonIdToken;
  static String? _anonRefreshToken;
  static int _anonExpiryMs = 0;
  static bool _anonStarted = false;
  static Repo? _repo;

  /// uid الفعّال لهذا الجهاز (حساب مجهول دائم، أو حساب Google إن سُجّل).
  static String get currentUid => _anonUid ?? '';

  /// هل لدينا توكن هوية صالح الآن (بلا انتظار)؟
  static bool get hasValidToken =>
      _anonIdToken != null &&
      _anonIdToken!.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch < _anonExpiryMs;

  /// التوكن الصالح لإرفاقه بطلبات RTDB (`?auth=`) — يجدّده عند الحاجة.
  /// يعيد null فقط إن تعذّرت الشبكة نهائياً ولا يوجد توكن محفوظ.
  static Future<String?> cloudIdToken() async {
    if (hasValidToken) return _anonIdToken;
    await _ensureFreshToken();
    return hasValidToken ? _anonIdToken : null;
  }

  /// (401/403) تحديث قسري للتوكن ثم إعادته — لإعادة محاولة واحدة فقط.
  static Future<String?> forceRefreshToken() async {
    _anonExpiryMs = 0;
    await _ensureFreshToken();
    return hasValidToken ? _anonIdToken : null;
  }

  /// تهيئة صامتة تماماً: بلا نافذة، بلا إذن، بلا تأخير مرئي.
  /// تُستدعى مرة واحدة من `main()` **قبل** أي اتصال بـ RTDB.
  static Future<void> initSilentAuth(Repo repo) async {
    _repo = repo;
    if (_anonStarted) return;
    _anonStarted = true;
    if (effectiveFirebaseApiKey.isEmpty) return;
    try {
      final st = await repo.settings();
      final savedUid = (st[anonUidKey] ?? '').trim();
      final savedRefresh = (st[_anonRefreshKey] ?? '').trim();
      final savedToken = (st[_anonIdTokenKey] ?? '').trim();
      if (savedUid.isNotEmpty) {
        // الهوية المجهولة ثابتة عبر إعادة التشغيل — نفس auth.uid دائماً،
        // فلا تنكسر القواعد ولا تُفقد العضوية في /members.
        _anonUid = savedUid;
        _anonRefreshToken = savedRefresh.isEmpty ? null : savedRefresh;
        _anonIdToken = savedToken.isEmpty ? null : savedToken;
        _anonExpiryMs = int.tryParse(st[_anonExpiryKey] ?? '') ?? 0;
      }
      if (hasValidToken) return;
      await _ensureFreshToken();
    } catch (_) {
      // الشبكة غائبة عند أول إقلاع: يُستأنف تلقائياً عند أول طلب سحابي
      // عبر `cloudIdToken()` — لا نُسقط الإقلاع أبداً.
    }
  }

  static Future<void> _ensureFreshToken() async {
    final key = effectiveFirebaseApiKey;
    if (key.isEmpty) return;
    final refresh = _anonRefreshToken;
    if (refresh != null && refresh.isNotEmpty && await _refreshAnonymous(key)) {
      return;
    }
    await _createAnonymous(key);
  }

  /// إنشاء حساب مجهول: `accounts:signUp` بلا بريد/كلمة سر.
  static Future<bool> _createAnonymous(String key) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://identitytoolkit.googleapis.com/v1/'
                'accounts:signUp?key=$key'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'returnSecureToken': true}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return false;
      final tok = '${m['idToken'] ?? ''}'.trim();
      final uid = '${m['localId'] ?? ''}'.trim();
      if (tok.isEmpty || uid.isEmpty) return false;
      _anonIdToken = tok;
      _anonUid = uid;
      final refresh = '${m['refreshToken'] ?? ''}'.trim();
      _anonRefreshToken = refresh.isEmpty ? null : refresh;
      _setExpiry(int.tryParse('${m['expiresIn'] ?? ''}') ?? 3600);
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// تحديث التوكن عبر `securetoken` باستخدام الـ refresh token.
  static Future<bool> _refreshAnonymous(String key) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://securetoken.googleapis.com/v1/token?key=$key'),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: 'grant_type=refresh_token&refresh_token='
                '${Uri.encodeComponent(_anonRefreshToken ?? '')}',
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return false;
      final tok = '${m['id_token'] ?? ''}'.trim();
      if (tok.isEmpty) return false;
      _anonIdToken = tok;
      final uid = '${m['user_id'] ?? ''}'.trim();
      if (uid.isNotEmpty) _anonUid = uid;
      final refresh = '${m['refresh_token'] ?? ''}'.trim();
      if (refresh.isNotEmpty) _anonRefreshToken = refresh;
      _setExpiry(int.tryParse('${m['expires_in'] ?? ''}') ?? 3600);
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// هامش أمان دقيقة قبل انتهاء الصلاحية الحقيقي.
  static void _setExpiry(int seconds) {
    _anonExpiryMs = DateTime.now().millisecondsSinceEpoch +
        (seconds * 1000) -
        const Duration(minutes: 1).inMilliseconds;
  }

  static Future<void> _persist() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      await repo.setSetting(anonUidKey, _anonUid ?? '');
      await repo.setSetting(_anonIdTokenKey, _anonIdToken ?? '');
      await repo.setSetting(_anonRefreshKey, _anonRefreshToken ?? '');
      await repo.setSetting(_anonExpiryKey, '$_anonExpiryMs');
    } catch (_) {}
  }
}
