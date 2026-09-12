// إعدادات السحابة المضمنة برمجياً.
//
// kDefaultBackendUrl: رابط قاعدة Firebase RTDB الرسمي للنظام — يُستخدم
// كمسار تراجع للمستخدم الفردي الذي لم يضبط المزامنة السحابية يدوياً:
// زر «تأكيد عملية الشراء» يتحقق من التفعيل عبره مباشرة بنقرة واحدة.
//
// ⚠️ إن تُرك فارغاً يتراجع التطبيق للسلوك القديم (يطلب ضبط الرابط يدوياً).
const String kDefaultBackendUrl = String.fromEnvironment(
  'NEXORA_BACKEND_URL',
  defaultValue: '', // ← يُضبط برابط قاعدة النظام الرسمية (أو عبر --dart-define)
);

/// الرابط الفعّال: المضبوط يدوياً في الإعدادات أولاً، ثم المضمّن.
String effectiveBackendUrl(String? fromSettings) {
  final s = (fromSettings ?? '').trim();
  if (s.isNotEmpty) return s;
  return kDefaultBackendUrl;
}
