// 🔒 واجهات الفترة التجريبية: نافذة الترحيب (مرة واحدة) + الشريط العلوي
// الأنيق للوقت المتبقي + بطاقة انتهاء التجربة مع خيارات التجديد والتواصل.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';

/// رقم التواصل المباشر للتفعيل (واتساب المدير/الدعم).
const String kActivationContact = '+96774190040';

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

/// صياغة الوقت المتبقي: «X يوماً وY ساعة» فوق اليومين، «X ساعة وY دقيقة»
/// دونهما — للاستخدام الموحد في الشريط وقسم تفاصيل الاشتراك.
String formatTrialRemaining(Duration rem) {
  if (rem.inHours >= 48) {
    final d = rem.inDays;
    final h = rem.inHours % 24;
    return h == 0 ? '$d أيام' : '$d أيام و$h ساعة';
  }
  final h = rem.inHours;
  final m = rem.inMinutes % 60;
  if (h == 0) return '$m دقيقة';
  return '$h ساعة و$m دقيقة';
}

/// الشريط الدائم أعلى الشاشة الرئيسية (للمدير فقط): عدّاد تنازلي حي
/// يحسب الفارق بين expires_at ووقت الخادم اللحظي، ويتجدد كل دقيقة.
/// يبقى ظاهراً طوال سريان التجربة — عبر كل الإقلاعات — ولا يختفي إلا
/// عند اشتراك مدفوع (active) أو بعد الانتهاء (تحل محله بطاقة الانتهاء).
class TrialCountdownBanner extends ConsumerStatefulWidget {
  const TrialCountdownBanner({super.key});

  @override
  ConsumerState<TrialCountdownBanner> createState() =>
      _TrialCountdownBannerState();
}

class _TrialCountdownBannerState extends ConsumerState<TrialCountdownBanner> {
  // نبضة عرض محلية كل 30 ثانية: تعيد بناء النص من نفس حالة المزود
  // (التي تسند وقت الخادم لحظياً) دون انتظار دورة المزود الدقيقية.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // (المتطلب) الشريط للمدير فقط — تحصين مزدوج كبقية واجهات المالك.
    final isOwner = (ref.watch(isOwnerProvider).valueOrNull ?? false) ||
        ref.watch(workspaceModeProvider).valueOrNull == 'host';
    if (!isOwner) return const SizedBox.shrink();
    final sub = ref.watch(subscriptionProvider).valueOrNull;
    if (sub == null || sub.status != 'trial' || sub.expiresAtMs <= 0) {
      return const SizedBox.shrink();
    }
    if (sub.expired) {
      // شريط انتهاء مصغر دائم (بدل الاختفاء): تفعيل بنقرة.
      const color = Color(0xFFDC2626);
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
            const Icon(Icons.lock_clock, size: 16, color: color),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'انتهت الفترة التجريبية — المزايا السحابية متوقفة',
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => showTrialExpiredSheet(context),
              child: const Text('تفعيل الآن',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: color)),
            ),
          ],
        ),
      );
    }
    final rem = sub.remaining;
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
                  ? '⏳ تنتهي تجربتك خلال ${formatTrialRemaining(rem)} — فعّل اشتراكك الآن'
                  : 'الفترة التجريبية: متبقٍ ${formatTrialRemaining(rem)}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => showTrialExpiredSheet(context, expired: false),
            child: Text(urgent ? 'تفعيل' : 'ترقية',
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

/// (الإعدادات — للمدير) قسم «تفاصيل الاشتراك»: حالة الترخيص، تاريخ
/// الانتهاء، الوقت المتبقي، وزر تجديد/ترقية الاشتراك.
class SubscriptionDetailsSection extends ConsumerWidget {
  const SubscriptionDetailsSection({super.key});

  String _fmtDate(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} — ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subAsync = ref.watch(subscriptionProvider);
    final sub = subAsync.valueOrNull;
    if (sub == null || sub.status == 'none') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.workspace_premium_outlined),
          title: const Text('تفاصيل الاشتراك'),
          subtitle: Text(
            subAsync.isLoading
                ? 'جارٍ تحميل حالة الاشتراك…'
                : 'فعّل المزامنة السحابية أولاً لبدء الفترة التجريبية.',
            style: const TextStyle(fontSize: 11.5, height: 1.5),
          ),
        ),
      );
    }
    final (label, color, icon) = switch ((sub.status, sub.expired)) {
      ('active', _) => (
          'اشتراك مدفوع فعّال',
          const Color(0xFF16A34A),
          Icons.verified,
        ),
      ('trial', false) => (
          'فترة تجريبية سارية',
          const Color(0xFF7C3AED),
          Icons.workspace_premium,
        ),
      _ => (
          'انتهت الفترة التجريبية',
          const Color(0xFFDC2626),
          Icons.lock_clock,
        ),
    };
    Widget row(String k, String v, {Color? vColor}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Text(k,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.text2Of(context))),
              const Spacer(),
              Text(v,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: vColor ?? AppColors.textOf(context))),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('تفاصيل الاشتراك',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w800)),
                      Text(label,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: color)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            row('حالة الترخيص', label, vColor: color),
            if (sub.status != 'active') ...[
              row('تاريخ بداية التجربة', _fmtDate(sub.createdAtMs)),
              row('تاريخ الانتهاء', _fmtDate(sub.expiresAtMs)),
              if (!sub.expired)
                row('الوقت المتبقي', formatTrialRemaining(sub.remaining),
                    vColor: color),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor:
                    sub.expired ? const Color(0xFFDC2626) : color,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () =>
                  showTrialExpiredSheet(context, expired: sub.expired),
              icon: const Icon(Icons.rocket_launch_outlined, size: 18),
              label: Text(
                sub.status == 'active'
                    ? 'إدارة الاشتراك'
                    : sub.expired
                        ? 'تجديد الاشتراك الآن'
                        : 'ترقية الاشتراك',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة التفعيل/التجديد: تُستخدم بعد الانتهاء (تجديد) وأثناء السريان
/// (ترقية مبكرة) — العنوان والنبرة يتكيفان مع الحالة.
Future<void> showTrialExpiredSheet(BuildContext context,
    {bool expired = true}) async {
  if (expired) {
    Sfx.warning();
  } else {
    Sfx.notify();
  }
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
          Icon(expired ? Icons.lock_clock : Icons.rocket_launch,
              size: 52,
              color: expired
                  ? const Color(0xFFDC2626)
                  : const Color(0xFF7C3AED)),
          const SizedBox(height: 12),
          Text(
            expired ? 'انتهت الفترة التجريبية' : 'ترقية / تجديد الاشتراك',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            expired
                ? 'بياناتك المحلية بأمان ويمكنك مواصلة العمل عليها، لكن المزايا '
                    'السحابية توقفت:\n'
                    '• المزامنة اللحظية بين الأجهزة\n'
                    '• ربط أجهزة جديدة\n'
                    '• النسخ الاحتياطي السحابي\n\n'
                    'فعّل اشتراكك لاستئناف كل شيء فوراً من حيث توقف.'
                : 'فعّل اشتراكك الدائم قبل انتهاء التجربة لتستمر كل المزايا '
                    'السحابية دون أي انقطاع:\n'
                    '• المزامنة اللحظية بين الأجهزة\n'
                    '• ربط أجهزة الفريق\n'
                    '• النسخ الاحتياطي السحابي',
            style: const TextStyle(fontSize: 13, height: 1.7),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () async {
              final msg = Uri.encodeComponent(expired
                  ? 'مرحباً، انتهت فترتي التجريبية في تطبيق مدير الحسابات '
                      'وأرغب بتفعيل الاشتراك.'
                  : 'مرحباً، أستخدم تطبيق مدير الحسابات وأرغب بترقية/تجديد '
                      'اشتراكي.');
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
            child: Text(expired ? 'متابعة بالعمل المحلي فقط' : 'لاحقاً',
                style: TextStyle(color: AppColors.text3Of(ctx))),
          ),
        ],
      ),
    ),
  );
}
