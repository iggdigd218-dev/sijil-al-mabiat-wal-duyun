// خدمة المؤثرات الصوتية والاهتزازية التفاعلية.
// تستخدم فقط SystemSound و HapticFeedback المدمجان في Flutter، لا حاجة لمكتبات
// خارجية ولا لملفات صوت في assets (توافق فوري على Android/Windows/iOS/Linux/macOS).
//
// الأنماط مصممة لإعطاء "إحساس" مميز كالدفع الإلكتروني NFC:
//   - success   : نقرة ناجحة (حفظ عملية، تأكيد) — نغمة ثلاثية قصيرة + نقرة نظام.
//   - payment   : دفع/إتمام فاتورة ناجح — نمط أطول (medium-light-light-pop).
//   - delete    : حذف/إلغاء — اهتزاز ثقيل قصير (حذري).
//   - warning   : تنبيه غير فادح (نقص مخزون، إلخ) — اهتزاز مزدوج خفيف.
//   - error     : فشل/خطأ جسيم — اهتزاز قوي + صوت تنبيه نظام.
//   - scan      : مسح باركود ناجح — نقرة سريعة.
//   - click     : نقرة عادية (تبويبات، أزرار).
//   - pop       : فتح/إغلاق نوافذ أو إجراء كبير.
//   - pair      : اقتران جهاز ناجح — نمط احتفالي قصير.
import 'package:flutter/services.dart';

class Sfx {
  static bool _muted = false; // كتم شامل (يستخدمه وضع الاختبار).
  static bool _soundOn = true; // الأصوات (SystemSound).
  static bool _hapticOn = true; // الاهتزاز (HapticFeedback).

  static bool get muted => _muted;
  static void setMuted(bool v) => _muted = v;

  /// تحدّث حالتي الصوت والاهتزاز من إعدادات المستخدم.
  static void applySettings({required bool sound, required bool haptic}) {
    _soundOn = sound;
    _hapticOn = haptic;
  }

  static bool get _soundEnabled => !_muted && _soundOn;
  static bool get _hapticEnabled => !_muted && _hapticOn;

  // ============ النجاح ============

  /// صوت نجاح عام شبيه بصوت NFC/الدفع الإلكتروني.
  /// يُستخدم بعد حفظ العمليات، إضافة/تعديل السجلات، إلخ.
  static void success() {
    if (_muted) return;
    final h = _hapticEnabled; final s = _soundEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 70),
      h ? HapticFeedback.lightImpact : null,
    );
    Future.delayed(
      const Duration(milliseconds: 140),
      h ? HapticFeedback.lightImpact : null,
    );
    if (s) SystemSound.play(SystemSoundType.click);
  }

  /// صوت إتمام فاتورة/دفع (نمط أطول قليلاً من success).
  static void payment() {
    if (_muted) return;
    final h = _hapticEnabled; final s = _soundEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 70),
      h ? HapticFeedback.lightImpact : null,
    );
    Future.delayed(
      const Duration(milliseconds: 140),
      h ? HapticFeedback.lightImpact : null,
    );
    Future.delayed(
      const Duration(milliseconds: 220),
      h ? HapticFeedback.mediumImpact : null,
    );
    if (s) SystemSound.play(SystemSoundType.click);
  }

  /// نجاح مسح باركود (نقرة سريعة واحدة).
  static void scan() {
    if (_muted) return;
    final h = _hapticEnabled; final s = _soundEnabled;
    if (h) HapticFeedback.lightImpact();
    if (s) SystemSound.play(SystemSoundType.click);
  }

  /// نجاح اقتران/اتصال جهاز (نمط احتفالي خفيف).
  static void pair() {
    if (_muted) return;
    final h = _hapticEnabled; final s = _soundEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 90),
      h ? HapticFeedback.selectionClick : null,
    );
    Future.delayed(
      const Duration(milliseconds: 180),
      h ? HapticFeedback.mediumImpact : null,
    );
    if (s) SystemSound.play(SystemSoundType.click);
  }

  // ============ التحذيرات ============

  /// تنبيه متوسط (مثل: مخزون منخفض، رسالة غير فادحة).
  static void warning() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.lightImpact();
    Future.delayed(
      const Duration(milliseconds: 120),
      h ? HapticFeedback.lightImpact : null,
    );
  }

  // ============ الفشل ============

  /// صوت فشل/خطأ جسيم (اهتزاز قوي + صوت تنبيه نظام).
  static void error() {
    if (_muted) return;
    final h = _hapticEnabled; final s = _soundEnabled;
    if (h) HapticFeedback.heavyImpact();
    Future.delayed(
      const Duration(milliseconds: 110),
      h ? HapticFeedback.lightImpact : null,
    );
    if (s) SystemSound.play(SystemSoundType.alert);
  }

  /// فشل بسيط/رفض (مدخلات غير صالحة) — اهتزاز خفيف مزدوج.
  static void reject() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.selectionClick();
    Future.delayed(
      const Duration(milliseconds: 80),
      h ? HapticFeedback.selectionClick : null,
    );
  }

  // ============ الأزرار/التنقل ============

  /// نقرة خفيفة عامة للأزرار والتبديل بين التبويبات.
  static void click() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.selectionClick();
  }

  /// اهتزاز خفيف لفتح/إغلاق النوافذ أو العمليات الكبيرة.
  static void pop() {
    if (_muted) return;
    final h = _hapticEnabled; final s = _soundEnabled;
    if (h) HapticFeedback.lightImpact();
    if (s) SystemSound.play(SystemSoundType.click);
  }

  /// اهتزاز للحذف (ثقيل قصير — ليعطي إحساساً تحذيرياً قبل الحذف النهائي).
  static void delete() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 90),
      h ? HapticFeedback.heavyImpact : null,
    );
  }

  // ============ مساعدات ============

  /// اهتزاز طويل نسبيًا لإشعار يمكن ملاحظته في الجيب (إشعار/تنبيه خارجي).
  static void notify() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 180),
      h ? HapticFeedback.lightImpact : null,
    );
    Future.delayed(
      const Duration(milliseconds: 360),
      h ? HapticFeedback.mediumImpact : null,
    );
  }

  /// يُستخدم في حوارات التأكيد المدمرة (حذف، طرد) ليعطي إحساساً مختلفاً.
  static void dangerConfirm() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.heavyImpact();
  }
}
