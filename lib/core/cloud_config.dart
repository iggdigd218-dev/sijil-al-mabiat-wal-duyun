// إعدادات السحابة المضمنة برمجياً.
//
// kDefaultCloudBackendUrl: رابط قاعدة Firebase RTDB الرسمي للنظام —
// مثبّت كرابط افتراضي دائم (Zero-Config Cloud Onboarding): المستخدم
// الجديد تبدأ تجربته ويعمل محرك المزامنة فوراً دون أي إعداد يدوي.
// يمكن تجاوزه وقت البناء عبر --dart-define=NEXORA_BACKEND_URL=...
// أو وقت التشغيل بضبط رابط مخصص في الإعدادات ← المزامنة السحابية.
const String kDefaultCloudBackendUrl = String.fromEnvironment(
  'NEXORA_BACKEND_URL',
  defaultValue: 'https://nexora-ledger-default-rtdb.firebaseio.com',
);

/// (اختبارات فقط) تجاوز الرابط الافتراضي — تضبطه حزم الاختبار على ''
/// لمحاكاة «لا سحابة»؛ null = السلوك الإنتاجي الطبيعي.
String? debugDefaultBackendUrlOverride;

/// الرابط الفعّال: المضبوط يدوياً في الإعدادات أولاً، ثم الرسمي المضمّن.
String effectiveBackendUrl(String? customUrl) {
  final trimmed = (customUrl ?? '').trim();
  if (trimmed.isNotEmpty) return trimmed;
  return debugDefaultBackendUrlOverride ?? kDefaultCloudBackendUrl;
}
