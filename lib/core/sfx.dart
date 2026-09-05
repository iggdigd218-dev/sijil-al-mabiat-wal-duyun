// خدمة المؤثرات الصوتية والاهتزازية التفاعلية.
// تستخدم SystemSound و HapticFeedback المدمجان في Flutter — لا حاجة لمكتبات خارجية
// ولا ملفات صوت في assets (التوافق الفوري على Android/Windows).
import 'package:flutter/services.dart';

class Sfx {
  static bool _muted = false;
  static bool get muted => _muted;
  static void setMuted(bool v) => _muted = v;

  /// صوت نجاح (شبيه بصوت NFC/دفع إلكتروني) يصاحب العمليات الناجحة.
  static void success() {
    if (_muted) return;
    // Click + نغمة خفيفة عبر اهتزاز نمط Medium → Light → Light لمحاكاة NFC.
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 80), HapticFeedback.lightImpact);
    Future.delayed(const Duration(milliseconds: 160), HapticFeedback.lightImpact);
    SystemSound.play(SystemSoundType.click);
  }

  /// صوت خطأ/رفض.
  static void error() {
    if (_muted) return;
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
  }

  /// صوت نقرة خفيفة للأزرار/التبديل بين التبويبات.
  static void click() {
    if (_muted) return;
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  /// اهتزاز طويل للمسح/العمليات الكبيرة (حفظ ناجح بعد مسح ضوئي).
  static void pop() {
    if (_muted) return;
    HapticFeedback.mediumImpact();
  }
}
