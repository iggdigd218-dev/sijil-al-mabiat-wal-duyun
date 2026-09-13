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
}
