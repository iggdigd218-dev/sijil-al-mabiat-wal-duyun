// 🔒 واجهات الفترة التجريبية: نافذة الترحيب (مرة واحدة) + الشريط العلوي
// الأنيق للوقت المتبقي + بطاقة انتهاء التجربة مع خيارات التجديد والتواصل.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/cloud_config.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/device_id.dart';
import '../data/sync/subscription_guard.dart';
import 'widgets.dart' show showSnack;

/// رقم التواصل المباشر للتفعيل (واتساب المدير/الدعم).
const String kActivationContact = '+967774190040';

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
              'استمتع بكافة المزايا كاملة مجاناً لمدة شهر كامل (30 يوماً):\n'
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
              final msg = expired
                  ? 'مرحباً، انتهت فترتي التجريبية في تطبيق مدير الحسابات '
                      'وأرغب بتفعيل الاشتراك.'
                  : 'مرحباً، أستخدم تطبيق مدير الحسابات وأرغب بترقية/تجديد '
                      'اشتراكي.';
              await launchActivationWhatsApp(msg);
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
          const SizedBox(height: 8),
          // شاشة الشراء الكاملة: المزايا + إرسال كود التفعيل + تأكيد الشراء.
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PurchaseScreen()));
            },
            icon: const Icon(Icons.workspace_premium),
            label: const Text('شراء التطبيق — عرض كل المزايا',
                style: TextStyle(fontWeight: FontWeight.w700)),
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


/// فتح محادثة واتساب على رقم التفعيل — متانة أندرويد 11+:
/// (1) الرابط المباشر whatsapp://send (يتطلب <queries> المصرّح بها)،
/// (2) احتياط wa.me في المتصفح الخارجي، (3) احتياط أخير بالوضع الافتراضي.
Future<bool> launchActivationWhatsApp(String text) async {
  final phone = kActivationContact.replaceAll('+', '');
  final encoded = Uri.encodeComponent(text);
  final direct = Uri.parse('whatsapp://send?phone=$phone&text=$encoded');
  final web = Uri.parse('https://wa.me/$phone?text=$encoded');
  try {
    if (await canLaunchUrl(direct)) {
      if (await launchUrl(direct, mode: LaunchMode.externalApplication)) {
        return true;
      }
    }
  } catch (_) {}
  try {
    if (await launchUrl(web, mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (_) {}
  try {
    return await launchUrl(web); // آخر احتياط: الوضع الافتراضي للمنصة.
  } catch (_) {
    return false;
  }
}

// ==================== شاشة شراء التطبيق (الخطة الفردية) ====================

/// صف ميزة في شاشة الشراء.
class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  const _FeatureRow(this.icon, this.title, this.desc);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0xFF7C3AED).withValues(alpha: .10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: const Color(0xFF7C3AED)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800)),
                  Text(desc,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: AppColors.text2Of(context))),
                ],
              ),
            ),
          ],
        ),
      );
}

/// شاشة «شراء التطبيق»: مزايا الاشتراك + [إرسال كود التفعيل] عبر واتساب
/// برسالة مجهزة تحمل معرف الجهاز + [تأكيد عملية الشراء] بفحص التفعيل
/// السحابي فوراً — الترقية تسري دون مسح بيانات أو إعادة تثبيت.
class PurchaseScreen extends ConsumerStatefulWidget {
  /// اسم الميزة التي قادت المستخدم هنا (للعنوان التسويقي) — اختياري.
  final String? lockedFeature;
  const PurchaseScreen({super.key, this.lockedFeature});

  @override
  ConsumerState<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends ConsumerState<PurchaseScreen> {
  bool _verifying = false;

  Future<void> _sendActivationRequest() async {
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final devId = await ensureDeviceId(repo);
      final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
      final fp = SubscriptionGuard.fingerprintHash(raw);
      final ok = await launchActivationWhatsApp(
          'مرحباً، أرغب بشراء اشتراك تطبيق مدير الحسابات.\n'
          'معرف الجهاز: $devId\n'
          'بصمة التفعيل: $fp');
      if (!ok) throw Exception('wa-launch-failed');
    } catch (_) {
      if (mounted) {
        showSnack(context, 'تعذّر فتح واتساب — تأكد من تثبيته.',
            error: true);
      }
    }
  }

  /// التحقق من التفعيل السحابي: فحص قسري لعقدة الاشتراك — إن قلبها
  /// المشغّل إلى active تسري الترقية فوراً على هذا الجهاز.
  Future<void> _confirmPurchase() async {
    setState(() => _verifying = true);
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      // (تفعيل الفردي بنقرة) لا نشترط ضبط المزامنة يدوياً: المستخدم
      // الفردي يتحقق عبر الرابط الرسمي المضمّن برمجياً مباشرة.
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) {
        if (mounted) {
          showSnack(context,
              'فعّل المزامنة السحابية أولاً من الإعدادات ليكتمل التحقق.',
              error: true);
        }
        return;
      }
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      SubscriptionGuard.debugReset(); // تجاوز الكاش — قراءة حقيقية الآن.
      final sub = await SubscriptionGuard.check(repo,
          backendUrl: url, workspaceId: ws, force: true);
      if (!mounted) return;
      if (sub.isSubscribed) {
        Sfx.success();
        bump(ref);
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.verified,
                color: Color(0xFF16A34A), size: 44),
            title: const Text('🎉 تم تفعيل اشتراكك بنجاح'),
            content: const Text(
              'كل المزايا فُتحت فوراً على هذا الجهاز — دون مسح بيانات '
              'أو إعادة تثبيت. شكراً لثقتك!',
              style: TextStyle(height: 1.6),
              textAlign: TextAlign.center,
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ابدأ الاستخدام'),
              ),
            ],
          ),
        );
        if (mounted) Navigator.of(context).maybePop();
      } else {
        Sfx.warning();
        showSnack(
            context,
            'لم يُرصد تفعيل بعد. أرسل كود التفعيل عبر واتساب وسيُفعَّل '
            'اشتراكك خلال دقائق، ثم اضغط هنا مجدداً.',
            error: true);
      }
    } catch (_) {
      if (mounted) {
        showSnack(context, 'تعذّر التحقق — تأكد من اتصال الإنترنت.',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('شراء التطبيق')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                const Icon(Icons.workspace_premium,
                    color: Colors.white, size: 44),
                const SizedBox(height: 8),
                Text(
                  widget.lockedFeature == null
                      ? 'افتح كل المزايا — اشتراك واحد'
                      : '«${widget.lockedFeature}» ميزة مدفوعة',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                const Text(
                  'فعّل اشتراكك وافتح كل القدرات فوراً — بياناتك تبقى كما هي.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _FeatureRow(Icons.category_outlined, 'التصنيفات',
              'إنشاء واستخدام تصنيفات الحسابات والأصناف بلا حدود.'),
          const _FeatureRow(Icons.notifications_active_outlined,
              'الإشعارات والرسائل التلقائية',
              'رسائل الرصيد للعملاء وتنبيهات تلقائية ذكية.'),
          const _FeatureRow(Icons.cloud_upload_outlined,
              'النسخ الاحتياطي السحابي',
              'نسخة يومية آمنة ومزامنة بياناتك عبر السحابة.'),
          const _FeatureRow(Icons.settings_backup_restore_outlined,
              'نقاط الاسترجاع',
              'استرجاع بياناتك لأي نقطة محددة أو دمج قواعد البيانات.'),
          const _FeatureRow(Icons.manage_search_outlined,
              'البحث الشامل المتقدم',
              'بحث فوري عميق في الحسابات والعمليات والتصنيفات.'),
          const _FeatureRow(Icons.devices_other_outlined,
              'تعدد الأجهزة (باقة المؤسسات)',
              'فريق كامل بأدوار وصلاحيات ومزامنة لحظية وسجل تدقيق.'),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _sendActivationRequest,
            icon: const Icon(Icons.send_rounded),
            label: const Text('إرسال كود التفعيل (واتساب)',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _verifying ? null : _confirmPurchase,
            icon: _verifying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2))
                : const Icon(Icons.verified_outlined),
            label: Text(
                _verifying
                    ? 'جارٍ التحقق من التفعيل…'
                    : 'اضغط هنا لتأكيد عملية الشراء',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'بعد الدفع يُفعَّل اشتراكك سحابياً خلال دقائق — اضغط زر '
              'التأكيد ليسري فوراً.',
              style:
                  TextStyle(fontSize: 11, color: AppColors.text3Of(context)),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== ودجة القفل 🔒 للمزايا المدفوعة ====================

/// تغلّف أي قسم/بلاطة ميزة مدفوعة: مفتوحة = تُعرض كما هي؛ مقفلة = تبقى
/// ظاهرة بتدرج رمادي ومؤشر 🔒، والضغط يعرض رسالة تعريفية ثم شاشة الشراء.
class FeatureGate extends ConsumerWidget {
  /// مفتاح الميزة في featureUnlockedProvider.
  final String featureKey;

  /// اسم الميزة للعرض في الرسالة التعريفية.
  final String featureName;

  /// وصف تسويقي قصير يظهر في الرسالة التعريفية.
  final String description;
  final Widget child;

  const FeatureGate({
    super.key,
    required this.featureKey,
    required this.featureName,
    required this.description,
    required this.child,
  });

  static Future<void> showLockedNotice(
    BuildContext context, {
    required String featureName,
    required String description,
  }) async {
    Sfx.warning();
    final buy = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_outline,
            color: Color(0xFF7C3AED), size: 42),
        title: Text('«$featureName» ميزة مدفوعة'),
        content: Text('$description\n\nفعّل اشتراكك لفتحها فوراً — '
            'بياناتك الحالية تبقى كما هي دون أي مسح.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('لاحقاً'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7C3AED)),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.workspace_premium, size: 18),
            label: const Text('شراء التطبيق'),
          ),
        ],
      ),
    );
    if (buy == true && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PurchaseScreen(lockedFeature: featureName)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked =
        ref.watch(featureUnlockedProvider(featureKey)).valueOrNull ?? true;
    if (unlocked) return child;
    // مقفلة: تظل ظاهرة (تشويق) بتدرج رمادي + قفل، والضغط يفتح التعريف.
    return Stack(
      children: [
        // امتصاص كل النقرات الداخلية ثم تحويلها لرسالة التعريف.
        AbsorbPointer(
          child: Opacity(
            opacity: 0.45,
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                0.2126, 0.7152, 0.0722, 0, 0, //
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0, 0, 0, 1, 0,
              ]),
              child: child,
            ),
          ),
        ),
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showLockedNotice(context,
                  featureName: featureName, description: description),
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text('مدفوعة',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// (باقة المؤسسات) شارة عدّاد المقاعد: «الأجهزة 3/5» — تظهر للمدير في
/// شاشة إدارة المجموعة وتفاصيل الاشتراك.
class SeatUsageBadge extends ConsumerWidget {
  const SeatUsageBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(seatUsageProvider).valueOrNull;
    if (usage == null) return const SizedBox.shrink();
    final (connected, maxSeats) = usage;
    final full = connected >= maxSeats;
    final color = full ? const Color(0xFFDC2626) : const Color(0xFF0EA5E9);
    return Tooltip(
      message: full
          ? 'استُنفدت مقاعد الباقة — رقِّ الاشتراك لإضافة أجهزة'
          : 'الأجهزة المتصلة من أصل الحد الأقصى للباقة',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: .35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(full ? Icons.event_busy : Icons.devices, size: 13,
                color: color),
            const SizedBox(width: 5),
            Text('الأجهزة $connected/$maxSeats',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      ),
    );
  }
}

/// بوابة نقرة لميزة مدفوعة: true = مفتوحة فامضِ؛ false = عُرضت رسالة
/// التعريف (مع زر شاشة الشراء) وعلى المستدعي التوقف.
Future<bool> ensureFeatureUnlocked(
  BuildContext context,
  WidgetRef ref, {
  required String featureKey,
  required String featureName,
  required String description,
}) async {
  bool ok = true;
  try {
    ok = await ref.read(featureUnlockedProvider(featureKey).future);
  } catch (_) {}
  if (ok) return true;
  if (context.mounted) {
    await FeatureGate.showLockedNotice(context,
        featureName: featureName, description: description);
  }
  return false;
}
