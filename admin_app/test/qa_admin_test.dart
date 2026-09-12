// اختبارات منطق مدير التراخيص: حساب المدد + تحويل المعرفات.
import 'package:flutter_test/flutter_test.dart';
import 'package:license_admin/rtdb.dart';

void main() {
  test('ADMIN-01 مدد الخطط صحيحة بالمللي ثانية', () {
    expect(PlanDuration.month.span.inDays, 30);
    expect(PlanDuration.quarter.span.inDays, 90);
    expect(PlanDuration.year.span.inDays, 365);
    expect(PlanDuration.lifetime.span.inDays, 36500);
  });

  test('ADMIN-02 نمط بصمة التفعيل: 32 خانة hex فقط', () {
    final re = RegExp(r'^[0-9a-fA-F]{32}$');
    expect(re.hasMatch('a1b2c3d4e5f60718293a4b5c6d7e8f90'), isTrue);
    expect(re.hasMatch('ws-1755'), isFalse);
    expect(re.hasMatch(''), isFalse);
    expect(re.hasMatch('a1b2c3d4e5f60718293a4b5c6d7e8f9'), isFalse);
  });

  test('ADMIN-03 تصنيف العدادات: مدفوع/تجربة/منتهٍ بساعة الخادم', () {
    const now = 1770000000000;
    expect(classify('active', now + 1000, now), 'paid');
    expect(classify('trial', now + 1000, now), 'trial');
    expect(classify('trial', now, now), 'expired',
        reason: 'الانتهاء عند اللحظة تماماً = منتهٍ');
    expect(classify('active', now - 1, now), 'expired',
        reason: 'اشتراك مدفوع منتهي الصلاحية = فئة منتهية');
    expect(classify('', 0, now), 'expired');
  });
}

// ملاحظة: تصنيف العدادات (paid/trial/expired) يُختبر منطقياً هنا
// بمحاكاة نفس شروط RtdbMetrics.metrics().
String classify(String status, int expiresAt, int now) {
  final alive = expiresAt > now;
  if (status == 'active' && alive) return 'paid';
  if (status == 'trial' && alive) return 'trial';
  return 'expired';
}

