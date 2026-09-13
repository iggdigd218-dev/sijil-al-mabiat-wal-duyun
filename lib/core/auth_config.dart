// (معمارية حساب Google) مفاتيح المصادقة المضمنة برمجياً.
//
// النهج: REST خفيف — google_sign_in يجلب idToken من حساب Google، ثم
// نبادله مع Firebase Identity Toolkit (accounts:signInWithIdp) للحصول على
// uid الرسمي نفسه الذي تصدره حزمة firebase_auth — دون أي SDK إضافي
// ودون المساس بإعداد Gradle/CI القائم.
//
// القيم تُملأ من google-services.json الخاص بالمشروع:
//  - kFirebaseWebApiKey  : client[0].api_key[0].current_key
//  - kGoogleServerClientId: oauth_client ذو client_type=3 (Web client)
// ويمكن تجاوزها وقت البناء عبر --dart-define.
library;

/// مفتاح Web API لمشروع Firebase (إلزامي لتبادل idToken → uid).
const String kFirebaseWebApiKey = String.fromEnvironment(
  'NEXORA_FIREBASE_API_KEY',
  defaultValue: '',
);

/// معرف عميل OAuth من نوع Web — يُمرَّر لـ GoogleSignIn(serverClientId)
/// كي يُصدر أندرويد idToken دون الحاجة لملف google-services.json.
const String kGoogleServerClientId = String.fromEnvironment(
  'NEXORA_GOOGLE_CLIENT_ID',
  defaultValue: '',
);

/// (اختبارات فقط) تجاوز مفتاح API — null = القيمة المضمنة.
String? debugFirebaseApiKeyOverride;

/// المفتاح الفعّال.
String get effectiveFirebaseApiKey =>
    debugFirebaseApiKeyOverride ?? kFirebaseWebApiKey;

/// هل ميزة الدخول بحساب Google مهيأة في هذا البناء؟
bool get googleSignInConfigured => effectiveFirebaseApiKey.isNotEmpty;
