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
///
/// (تثبيت الإنتاج) القيمة الرسمية مضمّنة افتراضياً: كانت تُترك فارغة في كل
/// بناء لا يُمرَّر له --dart-define، فيُجهض التبادل مع Identity Toolkit
/// قبل أن يبدأ (يرجع null فوراً) ولا يُستخرج localId أبداً.
/// يبقى --dart-define قادراً على التجاوز عند الحاجة (بناء خاص/اختبار).
const String kFirebaseWebApiKey = String.fromEnvironment(
  'NEXORA_FIREBASE_API_KEY',
  defaultValue: 'AIzaSyBHmi_00j58JKi2kNLR8gQQHhRN3grRg3U',
);

/// معرف عميل OAuth من نوع Web — يُمرَّر لـ GoogleSignIn(serverClientId)
/// كي يُصدر أندرويد idToken صالحاً للتبادل دون الحاجة لملف
/// google-services.json. بدونه يعود idToken فارغاً على كثير من الأجهزة،
/// فتُستخدم هوية Google المؤقتة (sub) بدل uid الرسمي.
const String kGoogleServerClientId = String.fromEnvironment(
  'NEXORA_GOOGLE_CLIENT_ID',
  defaultValue:
      '843243539740-knmm6opqabnt9aloiprh8d5e5d545j0n.apps.googleusercontent.com',
);

/// (اختبارات فقط) تجاوز مفتاح API — null = القيمة المضمنة.
String? debugFirebaseApiKeyOverride;

/// المفتاح الفعّال.
String get effectiveFirebaseApiKey =>
    debugFirebaseApiKeyOverride ?? kFirebaseWebApiKey;

/// هل ميزة الدخول بحساب Google مهيأة في هذا البناء؟
bool get googleSignInConfigured => effectiveFirebaseApiKey.isNotEmpty;
