// شاشة الإعداد الأول (Onboarding): تظهر مرة واحدة فقط عند أول تشغيل
// وقاعدة بيانات فارغة، وتسأل المستخدم عن نمط الاستخدام:
//   1) استخدام شخصي / متجر فردي  → وضع مستقل تماماً بلا أي مزامنة.
//   2) ربط شبكي / متجر متعدد الأجهزة → معالج إنشاء/انضمام مجموعة الموجود.
// بعد اختيار البطاقة يظهر إعداد مصغّر: اسم المتجر + العملة الأساسية.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import 'group_management_screen.dart';
import 'home_shell.dart';
import 'lock_gate.dart';

/// مفتاح علم «أُكمل الإعداد الأول» في جدول الإعدادات.
const kOnboardingDoneKey = 'has_completed_onboarding';

/// هل يجب عرض شاشة الإعداد الأول؟
/// تُعرض فقط إذا: لم يكتمل الإعداد من قبل، والوضع مستقل،
/// وقاعدة البيانات فارغة (لا حسابات إطلاقاً — مستخدم جديد كلياً).
/// أي حالة أخرى (ترقية تطبيق قائم، عضو مجموعة...) تُعلَّم مكتملة تلقائياً
/// حتى لا يُعاد الفحص في كل تشغيل.
Future<bool> shouldShowOnboarding(Repo repo) async {
  final st = await repo.settings();
  if (st[kOnboardingDoneKey] == '1') return false;
  final mode = await repo.workspaceMode();
  if (mode != 'standalone') {
    await repo.setSetting(kOnboardingDoneKey, '1');
    return false;
  }
  final accounts =
      await repo.accounts(includeArchived: true, includeDeleted: true);
  if (accounts.isNotEmpty) {
    await repo.setSetting(kOnboardingDoneKey, '1');
    return false;
  }
  return true;
}

/// يحفظ نتيجة الإعداد المصغّر ويعلّم الإعداد الأول مكتملاً.
/// لا يغيّر workspaceMode — الوضع المستقل هو الافتراضي أصلاً،
/// ومسار «متعدد الأجهزة» يمر عبر معالج المجموعة الذي يضبط الوضع بنفسه.
Future<void> completeOnboarding(
  Repo repo, {
  required String storeName,
  required String currencyCode,
}) async {
  final name = storeName.trim().isEmpty ? 'متجري' : storeName.trim();
  await repo.setSetting('businessName', name);
  await repo.setSetting('defaultCurrency', currencyCode);
  await repo.setSetting(kOnboardingDoneKey, '1');
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// 'personal' أو 'network' أو null (لم يُختر بعد).
  String? _choice;
  final _nameCtrl = TextEditingController(text: 'متجري');
  String _currency = 'YER';
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy || _choice == null) return;
    setState(() => _busy = true);
    Sfx.click();
    final repo = ref.read(repoProvider);
    final goNetwork = _choice == 'network';
    try {
      await completeOnboarding(
        repo,
        storeName: _nameCtrl.text,
        currencyCode: _currency,
      );
      bump(ref);
    } catch (_) {
      // حتى لو فشل الحفظ لأي سبب لا نحبس المستخدم في شاشة الإعداد.
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pushReplacement(
      MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
    );
    if (goNetwork) {
      // معالج المجموعة الموجود (إنشاء عبر QR/سحابة أو انضمام بالمسح).
      nav.push(
        MaterialPageRoute(builder: (_) => const GroupManagementScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
              children: [
                // ---------- الترويسة ----------
                Icon(Icons.storefront_rounded,
                    size: 58, color: AppColors.primaryOf(context)),
                const SizedBox(height: 14),
                Text(
                  'مرحباً بك في نكسورا',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'اختر نمط الاستخدام الأنسب لعملك للبدء في ثوانٍ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: AppColors.text2Of(context),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 26),
                // ---------- بطاقتا الاختيار ----------
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _personalCard()),
                      const SizedBox(width: 14),
                      Expanded(child: _networkCard()),
                    ],
                  )
                else ...[
                  _personalCard(),
                  const SizedBox(height: 14),
                  _networkCard(),
                ],
                // ---------- الإعداد المصغّر ----------
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: _choice == null
                      ? const SizedBox(width: double.infinity)
                      : _microSetup(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _personalCard() => _ModeCard(
        selected: _choice == 'personal',
        icon: Icons.person_outline_rounded,
        bigIcon: Icons.storefront_rounded,
        color: const Color(0xFF16A34A),
        title: 'استخدام شخصي / متجر فردي',
        badge: 'سريع وبسيط',
        description: 'كل بياناتك على هذا الجهاز فقط — بلا مزامنة ولا شبكات. '
            'مثالي للمتجر الواحد ودفتر الديون الشخصي.',
        onTap: () {
          Sfx.click();
          setState(() => _choice = 'personal');
        },
      );

  Widget _networkCard() => _ModeCard(
        selected: _choice == 'network',
        icon: Icons.devices_rounded,
        bigIcon: Icons.hub_rounded,
        color: const Color(0xFF0EA5E9),
        title: 'ربط شبكي / متجر متعدد الأجهزة',
        badge: 'مزامنة وتعاون',
        description: 'اربط أكثر من جهاز على نفس الحسابات: مدير وكاشير '
            'ومدخل بيانات — مزامنة فورية تلقائية بين الجميع.',
        onTap: () {
          Sfx.click();
          setState(() => _choice = 'network');
        },
      );

  Widget _microSetup() {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'إعداد سريع',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _nameCtrl,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'اسم المتجر / النشاط',
                  prefixIcon: Icon(Icons.store_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _currency,
                decoration: const InputDecoration(
                  labelText: 'العملة الأساسية',
                  prefixIcon: Icon(Icons.currency_exchange),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in kDefaultCurrencies)
                    DropdownMenuItem(
                      value: c.code,
                      child: Text('${c.symbol}  ${c.name}'),
                    ),
                ],
                onChanged: (v) => setState(() => _currency = v ?? 'YER'),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _start,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.rocket_launch_outlined),
                  label: const Text(
                    'ابدأ استخدام التطبيق الآن',
                    style: TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              if (_choice == 'network') ...[
                const SizedBox(height: 10),
                Text(
                  'سيُفتح بعدها معالج المجموعة: أنشئ مجموعة جديدة من هذا '
                  'الجهاز أو امسح رمز QR للانضمام إلى مجموعة قائمة.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: AppColors.text3Of(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// بطاقة اختيار نمط الاستخدام: حدود عالية التباين وحالة اختيار واضحة.
class _ModeCard extends StatefulWidget {
  final bool selected;
  final IconData icon;
  final IconData bigIcon;
  final Color color;
  final String title;
  final String badge;
  final String description;
  final VoidCallback onTap;
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.bigIcon,
    required this.color,
    required this.title,
    required this.badge,
    required this.description,
    required this.onTap,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final c = widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        decoration: BoxDecoration(
          color: sel
              ? c.withValues(alpha: .08)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: sel ? c : Theme.of(context).dividerColor,
            width: sel ? 2.4 : 1.4,
          ),
          boxShadow: (_hover || sel)
              ? [
                  BoxShadow(
                    color: c.withValues(alpha: .18),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(widget.bigIcon, color: c, size: 28),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.withValues(alpha: .35)),
                        ),
                        child: Text(
                          widget.badge,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: c,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(widget.icon, size: 18, color: c),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (sel)
                        Icon(Icons.check_circle_rounded, color: c, size: 22),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.description,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      color: AppColors.text2Of(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
