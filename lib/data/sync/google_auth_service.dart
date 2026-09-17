// خدمة المصادقة بـ Google.
// تُستخدم لإثبات هوية المالك وربط Workspace بحساب Google.
// النطاقات المطلوبة محدودة: email + openid + profile (لا Drive هنا).
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/auth_config.dart';
import '../../core/token_cipher.dart';

class GoogleUser {
  final String id; // Google sub (subject) ثابت لكل حساب
  final String email;
  final String? displayName;
  final String? photoUrl;
  final String? idToken; // يُستخدم محليًا فقط للمصادقة مع Backend المستقبلي
  final DateTime signedInAt;

  const GoogleUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
    this.idToken,
    required this.signedInAt,
  });
}

class GoogleAuthResult {
  final GoogleUser? user;
  final String? error;
  const GoogleAuthResult.ok(this.user) : error = null;
  const GoogleAuthResult.fail(this.error) : user = null;
  bool get ok => user != null;
}

/// نطاق النسخ الاحتياطي — مجلد التطبيق الخاص (`appDataFolder`) داخل Drive.
///
/// الخدمة تستخدمه وحده ولا تلمس ملفات Drive العادية، فلا حاجة لنطاق
/// `drive.file` الأوسع على شاشة الموافقة.
const String kDriveAppDataScope =
    'https://www.googleapis.com/auth/drive.appdata';

/// النطاقات الموحّدة للتطبيق كله (SSO): الهوية + صلاحية النسخ.
const List<String> kUnifiedGoogleScopes = <String>[
  'email',
  'openid',
  'profile',
  kDriveAppDataScope,
];

/// مثال `GoogleSignIn` **الوحيد** في التطبيق — Single Sign-On.
///
/// كان هناك مثالان بمعرّف عميل ونطاقات مختلفين (الحساب مقابل Drive)،
/// فيلزم المستخدم تسجيلان منفصلان؛ والتسجيل من شاشة النسخ لا يربط مساحة
/// العمل فيفشل إنشاء الدعوة بـ HTTP 401. الآن مثال واحد بنطاقات موحّدة:
/// تسجيل واحد يمنح الهوية وصلاحية النسخ معاً، وتتعرّفه
/// `account_section` و`backup_screen` و`GoogleDriveService` من جلسة واحدة.
///
/// يُعيد null على المنصّات التي لا تدعم Google Sign-In (ويندوز/لينكس).
GoogleSignIn? createUnifiedGoogleSignIn() {
  try {
    // serverClientId (عميل Web من Firebase) ضروري كي يُصدر أندرويد
    // idToken صالحاً لتبادله مع Firebase (accounts:signInWithIdp) —
    // بدونه يعود idToken فارغاً على بعض الأجهزة.
    return GoogleSignIn(
      scopes: kUnifiedGoogleScopes,
      serverClientId:
          kGoogleServerClientId.isEmpty ? null : kGoogleServerClientId,
    );
  } catch (_) {
    return null;
  }
}

class GoogleAuthService {
  final Database db;
  GoogleSignIn? _googleSignIn;

  GoogleAuthService(this.db);

  /// المثال الموحّد (يعيد null على منصات لا تدعمه كويندوز/لينكس).
  ///
  /// (SSO) نفس المثال الذي تستخدمه خدمة Drive — جلسة واحدة للتطبيق كله.
  GoogleSignIn? _ensureSignIn() {
    _googleSignIn ??= createUnifiedGoogleSignIn();
    return _googleSignIn;
  }

  /// استعادة الجلسة المحفوظة من جدول google_auth (بدون فتح نافذة تسجيل).
  Future<GoogleUser?> currentUserFromDb() async {
    final rows = await db.query('google_auth', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final gid = r['google_id'] as String?;
    if (gid == null || gid.isEmpty) return null;
    final signedStr = r['signed_in_at'] as String?;
    // فك تعمية التوكن المخزّن (القيم القديمة نص صريح تمر كما هي).
    final storedTok = (r['id_token'] as String?) ?? '';
    final tok =
        storedTok.isEmpty ? storedTok : await TokenCipher.reveal(storedTok);
    return GoogleUser(
      id: gid,
      email: (r['email'] as String?) ?? '',
      displayName: r['display_name'] as String?,
      photoUrl: r['photo_url'] as String?,
      idToken: tok,
      signedInAt: signedStr != null
          ? DateTime.tryParse(signedStr) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// محاولة استعادة الجلسة بصمت من Google أيضًا (في حال كانت الجلسة في الذاكرة).
  Future<GoogleAuthResult> restoreSession() async {
    final cached = await currentUserFromDb();
    final gs = _ensureSignIn();
    if (gs == null) {
      // لا رسالة «المنصة غير مدعومة» على أندرويد/آيفون: الرسالة تخص
      // المنصات التي لا تدعم الخدمة فعلاً (ويندوز/لينكس/ويب).
      if (cached != null) return GoogleAuthResult.ok(cached);
      return GoogleAuthResult.fail(isPlatformSupportingGoogleSignIn()
          ? 'تعذّر تهيئة خدمة Google على هذا الجهاز — حدّث خدمات Google Play ثم أعد المحاولة.'
          : 'تسجيل الدخول بـ Google غير متاح على هذه المنصة حاليًا');
    }
    try {
      final a = gs.currentUser;
      final restored = a ?? await gs.signInSilently(suppressErrors: true);
      if (restored != null) {
        final auth = await restored.authentication;
        final u = _mapAccount(restored, auth.idToken);
        await _persist(u);
        return GoogleAuthResult.ok(u);
      }
      // لم يتمكن من الاستعادة؛ الجلسة المحلية (من DB) تعتبر منتهية.
      if (cached == null) {
        await _clear();
      }
      return GoogleAuthResult.ok(cached);
    } catch (e) {
      return GoogleAuthResult.ok(cached);
    }
  }

  /// تسجيل الدخول (يفتح نافذة Google للمستخدم).
  Future<GoogleAuthResult> signIn() async {
    final gs = _ensureSignIn();
    final supported = isPlatformSupportingGoogleSignIn();
    if (gs == null) {
      // لا استثناء وهمي على أندرويد: إن فشلت التهيئة هناك فالسبب حقيقي
      // (خدمات Google Play/إعداد المشروع) لا «عدم دعم المنصة».
      return GoogleAuthResult.fail(supported
          ? 'تعذّر تهيئة خدمة Google على هذا الجهاز — حدّث «خدمات Google Play» ثم أعد المحاولة.'
          : 'تسجيل الدخول بـ Google متاح على الأندرويد والآيفون.\n'
              'يمكنك استخدام التطبيق محليًا بدون حساب Google.');
    }
    try {
      final a = await gs.signIn();
      if (a == null) {
        return const GoogleAuthResult.fail('تم إلغاء تسجيل الدخول');
      }
      var auth = await a.authentication;
      // (إنتاج) ذاكرة التوكن قد تعود فارغة على بعض أجهزة أندرويد —
      // تنظيف الكاش وإعادة الطلب مرة واحدة قبل التسليم بالفشل.
      if ((auth.idToken ?? '').isEmpty && supported) {
        try {
          await a.clearAuthCache();
          auth = await a.authentication;
        } catch (_) {
          // غير حرج: نكمل بالقيمة المتاحة.
        }
      }
      final u = _mapAccount(a, auth.idToken);
      await _persist(u);
      return GoogleAuthResult.ok(u);
    } catch (e) {
      final s = '$e';
      // المنصات غير المدعومة فقط تتلقى رسالة «غير متاح على هذه المنصة».
      if (!supported) {
        return const GoogleAuthResult.fail(
          'تسجيل الدخول بـ Google متاح على الأندرويد والآيفون.',
        );
      }
      if (s.contains('DEVELOPER_ERROR') || s.contains('10:')) {
        return const GoogleAuthResult.fail(
          'تعذّر إتمام تسجيل الدخول عبر Google (خطأ إعداد 10):\n'
          'تحقّق من إضافة بصمة SHA-1 للتطبيق في إعدادات Firebase/Google Cloud '
          'ومن تطابق معرّف العميل.',
        );
      }
      if (s.contains('network_error') || s.contains('7:')) {
        return const GoogleAuthResult.fail(
          'تعذّر الاتصال بخوادم Google — تحقّق من الإنترنت ثم أعد المحاولة.',
        );
      }
      return GoogleAuthResult.fail('تعذّر تسجيل الدخول: $e');
    }
  }

  Future<void> signOut() async {
    final gs = _ensureSignIn();
    try {
      await gs?.disconnect();
      await gs?.signOut();
    } catch (_) {}
    await _clear();
  }

  GoogleUser _mapAccount(GoogleSignInAccount a, String? idToken) {
    return GoogleUser(
      id: a.id,
      email: a.email,
      displayName: a.displayName,
      photoUrl: a.photoUrl,
      idToken: idToken,
      signedInAt: DateTime.now(),
    );
  }

  Future<void> _persist(GoogleUser u) async {
    // التوكن يُعمّى قبل التخزين — لا نص صريح في SQLite.
    final tok = (u.idToken == null || u.idToken!.isEmpty)
        ? ''
        : await TokenCipher.protect(u.idToken!);
    await db.insert(
        'google_auth',
        {
          'id': 1,
          'google_id': u.id,
          'email': u.email,
          'display_name': u.displayName ?? '',
          'photo_url': u.photoUrl ?? '',
          'id_token': tok,
          'signed_in_at': u.signedInAt.toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _clear() async {
    await db.update(
        'google_auth',
        {
          'google_id': '',
          'email': '',
          'display_name': '',
          'photo_url': '',
          'id_token': '',
          'signed_in_at': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = 1');
  }
}

bool isPlatformSupportingGoogleSignIn() => Platform.isAndroid || Platform.isIOS;
