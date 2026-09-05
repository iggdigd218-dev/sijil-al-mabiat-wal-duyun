// خدمة المصادقة بـ Google.
// تُستخدم لإثبات هوية المالك وربط Workspace بحساب Google.
// النطاقات المطلوبة محدودة: email + openid + profile (لا Drive هنا).
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:sqflite/sqflite.dart';

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

class GoogleAuthService {
  final Database db;
  GoogleSignIn? _googleSignIn;

  static const _scopes = <String>['email', 'openid', 'profile'];

  GoogleAuthService(this.db);

  /// يُنشئ GoogleSignIn بأمان (يعيد null على منصات لا تدعمه كويندوز/لينكس).
  GoogleSignIn? _ensureSignIn() {
    if (_googleSignIn != null) return _googleSignIn;
    try {
      // لا نضع serverClientId هنا — هذا نسجّل دخول OpenID فقط.
      // serverClientId يُحتاج فقط لتبادل auth code مع backend في المراحل اللاحقة.
      _googleSignIn = GoogleSignIn(scopes: _scopes);
    } catch (_) {
      _googleSignIn = null;
    }
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
    return GoogleUser(
      id: gid,
      email: (r['email'] as String?) ?? '',
      displayName: r['display_name'] as String?,
      photoUrl: r['photo_url'] as String?,
      idToken: r['id_token'] as String?,
      signedInAt: signedStr != null ? DateTime.tryParse(signedStr) ?? DateTime.now() : DateTime.now(),
    );
  }

  /// محاولة استعادة الجلسة بصمت من Google أيضًا (في حال كانت الجلسة في الذاكرة).
  Future<GoogleAuthResult> restoreSession() async {
    final cached = await currentUserFromDb();
    final gs = _ensureSignIn();
    if (gs == null) {
      // سطح المكتب لا يدعم GoogleSignIn.
      if (cached != null) return GoogleAuthResult.ok(cached);
      return const GoogleAuthResult.fail('تسجيل الدخول بـ Google غير متاح على هذه المنصة حاليًا');
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
    if (gs == null) {
      return const GoogleAuthResult.fail(
          'تسجيل الدخول بـ Google غير متاح على هذه المنصة.\n'
          'يمكنك استخدام التطبيق محليًا بدون حساب Google، وسيُتاح تسجيل الدخول في نسخة الأندرويد.');
    }
    try {
      final a = await gs.signIn();
      if (a == null) return const GoogleAuthResult.fail('تم إلغاء تسجيل الدخول');
      final auth = await a.authentication;
      final u = _mapAccount(a, auth.idToken);
      await _persist(u);
      return GoogleAuthResult.ok(u);
    } catch (e) {
      final s = '$e';
      if (s.contains('sign_in_failed') || s.contains('DEVELOPER_ERROR') || s.contains('10:')) {
        return const GoogleAuthResult.fail(
            'تعذّر تسجيل الدخول عبر Google على هذه المنصة.\n'
            'هذا طبيعي على ويندوز/لينكس ويعمل على الأندرويد.');
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
    await db.insert('google_auth', {
      'id': 1,
      'google_id': u.id,
      'email': u.email,
      'display_name': u.displayName ?? '',
      'photo_url': u.photoUrl ?? '',
      'id_token': u.idToken ?? '',
      'signed_in_at': u.signedInAt.toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _clear() async {
    await db.update('google_auth', {
      'google_id': '',
      'email': '',
      'display_name': '',
      'photo_url': '',
      'id_token': '',
      'signed_in_at': '',
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'id = 1');
  }
}

bool isPlatformSupportingGoogleSignIn() =>
    Platform.isAndroid || Platform.isIOS;
