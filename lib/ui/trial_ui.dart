// 🔒 واجهات الفترة التجريبية: نافذة الترحيب (مرة واحدة) + الشريط العلوي
// الأنيق للوقت المتبقي + بطاقة انتهاء التجربة مع خيارات التجديد والتواصل.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';

/// رقم التواصل المباشر للتفعيل (واتساب المدير/الدعم).
const String kActivationContact = '+967700000000';

/// نافذة الترحيب بالفترة التجريبية — تظهر مرة واحدة فقط عند أول تفعيل.
Future<void> showTrialWelcomeDialog(BuildContext context) async {
  Sfx.notify();
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.workspace_premium,
                  color: Colors.white, size: 40),
            ),
            const SizedBox(height: 16),
            const Text(
              '🎉 تجربتك المجانية بدأت!',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text(
              'استمتع بكافة المزايا كاملة لمدة 24 ساعة:\n'
              '☁️ مزامنة سحابية لحظية بين أجهزتك\n'
              '👥 ربط أجهزة الفريق وإدارة الصلاحيات\n'
              '💾 نسخ احتياطي سحابي آمن\n\n'
              'العدّاد يُحتسب بتوقيت الخادم — يظهر الوقت المتبقي '
              'أعلى الشاشة الرئيسية.',
              style: TextStyle(fontSize: 13.5, height: 1.7),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ابدأ الاستخدام',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// الشريط العلوي الأنيق (غير مزعج): الوقت المتبقي بالساعات والدقائق.
/// يختفي تماماً عند عدم وجود تجربة نشطة أو عند اشتراك مدفوع.
class TrialCountdownBanner extends ConsumerWidget {
  const TrialCountdownBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = ref.watch(subscriptionProvider).valueOrNull;
    if (sub == null ||
        sub.status != 'trial' ||
        sub.expiresAtMs <= 0 ||
        sub.expired) {
      return const SizedBox.shrink();
    }
    final rem = sub.remaining;
    final h = rem.inHours;
    final m = rem.inMinutes % 60;
    final urgent = rem < const Duration(hours: 3);
    final color = urgent ? const Color(0xFFDC2626) : const Color(0xFF7C3AED);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(urgent ? Icons.hourglass_bottom : Icons.workspace_premium,
              size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              urgent
                  ? '⏳ تنتهي تجربتك خلال $h س $m د — فعّل اشتراكك الآن'
                  : 'الفترة التجريبية: متبقٍ $h ساعة و$m دقيقة',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (urgent)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => showTrialExpiredSheet(context),
              child: Text('تفعيل',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: color)),
            ),
        ],
      ),
    );
  }
}

/// بطاقة/نافذة انتهاء الفترة التجريبية: خيارات التجديد وزر تواصل مباشر.
Future<void> showTrialExpiredSheet(BuildContext context) async {
  Sfx.warning();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_clock, size: 52, color: Color(0xFFDC2626)),
          const SizedBox(height: 12),
          const Text(
            'انتهت الفترة التجريبية',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'بياناتك المحلية بأمان ويمكنك مواصلة العمل عليها، لكن المزايا '
            'السحابية توقفت:\n'
            '• المزامنة اللحظية بين الأجهزة\n'
            '• ربط أجهزة جديدة\n'
            '• النسخ الاحتياطي السحابي\n\n'
            'فعّل اشتراكك لاستئناف كل شيء فوراً من حيث توقف.',
            style: TextStyle(fontSize: 13, height: 1.7),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () async {
              final msg = Uri.encodeComponent(
                  'مرحباً، انتهت فترتي التجريبية في تطبيق مدير الحسابات '
                  'وأرغب بتفعيل الاشتراك.');
              final wa = Uri.parse(
                  'https://wa.me/${kActivationContact.replaceAll('+', '')}?text=$msg');
              try {
                await launchUrl(wa, mode: LaunchMode.externalApplication);
              } catch (_) {}
            },
            icon: const Icon(Icons.chat),
            label: const Text('تواصل مع المدير للتفعيل (واتساب)',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () async {
              final tel = Uri.parse('tel:$kActivationContact');
              try {
                await launchUrl(tel);
              } catch (_) {}
            },
            icon: const Icon(Icons.call_outlined),
            label: const Text('اتصال مباشر'),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('متابعة بالعمل المحلي فقط',
                style: TextStyle(color: AppColors.text3Of(ctx))),
          ),
        ],
      ),
    ),
  );
}
