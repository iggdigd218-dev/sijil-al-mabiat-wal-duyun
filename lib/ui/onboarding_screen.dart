// شاشة الإعداد الأول (Onboarding): تظهر مرة واحدة فقط عند أول تشغيل
// وقاعدة بيانات فارغة، وتسأل المستخدم عن نمط الاستخدام:
//   1) استخدام شخصي / متجر فردي  → وضع مستقل تماماً بلا أي مزامنة.
//   2) ربط شبكي / متجر متعدد الأجهزة → معالج إنشاء/انضمام مجموعة الموجود.
// بعد اختيار البطاقة يظهر إعداد مصغّر: اسم المتجر + العملة الأساسية.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/accounting.dart';
import '../core/factory_reset.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../core/cloud_config.dart';
import '../core/media_paths.dart';
import '../data/google_drive_service.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import 'account_section.dart' show provisionCloudAfterSignIn;
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
  /// نمط الحساب المختار — يُضبط لحظة فتح نافذة الخيار ('personal'/'network').
  String? _choice;

  /// (3.70.0) نية الاسترجاع: تُرفع من زر «استرجع بياناتك عبر Google» فقط —
  /// بعدها (وبعد نجاح التسجيل حصراً) يفحص التطبيق Drive/الملفات المحلية.
  bool _restoreIntent = false;
  String _name = 'متجري';
  String _currency = 'YER';
  bool _busy = false;

  /// إكمال الإعداد المحلي: اسم المتجر والعملة ونمط الاستخدام.
  ///
  /// (دفعة 65) يثبّت أيضاً `account.type`: الاختيار الشبكي = مؤسسة
  /// (`enterprise`) والشخصي = فردي (`individual`). ويُرقّى تلقائياً إلى
  /// `enterprise` عند الانضمام الفعلي لمجموعة.
  Future<void> _completeSetup() async {
    Sfx.click();
    final repo = ref.read(repoProvider);
    try {
      await completeOnboarding(
        repo,
        storeName: _name,
        currencyCode: _currency,
      );
      await repo.setSetting(
          'account.type', _choice == 'network' ? 'enterprise' : 'individual');
      bump(ref);
    } catch (_) {
      // حتى لو فشل الحفظ لأي سبب لا نحبس المستخدم في شاشة الإعداد.
    }
  }

  /// الانتقال إلى الشاشة الرئيسية (وإلى معالج المجموعة عند الاختيار الشبكي).
  Future<void> _finishAndNavigate() async {
    if (!mounted) return;
    final nav = Navigator.of(context);
    final goNetwork = _choice == 'network';
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

  /// المتابعة بدون حساب Google — عمل محلي كامل (المحلية أولاً).
  Future<void> _startLocal() async {
    if (_busy || _choice == null) return;
    setState(() => _busy = true);
    try {
      await _completeSetup();
      await _finishAndNavigate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// إكمال الإعداد ثم ربط حساب Google (تدفق تدريجي — Progressive Auth).
  Future<void> _startWithGoogle() async {
    if (_busy || _choice == null) return;
    setState(() => _busy = true);
    try {
      await _completeSetup();
      if (!mounted) return;
      await _signInWithGoogle();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// (حساب Google) تسجيل الدخول من شاشة الترحيب: الهوية الدائمة للمؤسسة.
  ///  - حساب معروف سابقاً؟ تُستعاد مؤسسته WS-{uid} كاملة بالبيانات
  ///    وصلاحية المالك فوراً (جهاز جديد/بعد مسح البيانات).
  ///  - حساب جديد؟ تُربط مساحته الحالية بـ WS-{uid} وتُؤمَّن سحابياً.
  Future<void> _signInWithGoogle() async {
    // (إصلاح القانون 2026-09-19 — زر Google «لا يستجيب»): كان هنا حارس
    // `if (_busy) return;` يرتد فوراً لأن _startWithGoogle ترفع العلم قبل
    // الاستدعاء — فيموت الضغط بصمت. الحارس الواحد عند المدخل يكفي،
    // والمسار صار مطابقاً لتسجيل الإعدادات (ربط + تهيئة سحابية).
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final auth = GoogleAuthService(db);
      final r = await auth.signIn();
      final gu = r.user;
      if (gu == null) {
        _restoreIntent = false;
        Sfx.error();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(r.error ?? 'تعذّر تسجيل الدخول')));
        }
        return;
      }
      // تبادل idToken مع Firebase → uid الرسمي (REST، بلا SDK إضافي).
      FirebaseAccount? account;
      final tok = gu.idToken ?? '';
      if (tok.isNotEmpty) {
        account = await FirebaseAuthRest.signInWithGoogleIdToken(tok);
      }
      // بلا مفاتيح Firebase (بناء غير مهيأ): نستخدم Google sub كهوية —
      // ثابت لكل حساب أيضاً، فلا يُحرم المستخدم من الميزة.
      account ??= FirebaseAccount(
        uid: gu.id,
        email: gu.email,
        displayName: gu.displayName ?? '',
      );
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      // (استعادة سلوك 3.55) تسجيل الدخول يثبّت الجلسة ويربط الحساب فقط —
      // لا يعيد تسمية مساحة العمل ولا يلمس البيانات المحلية، فلا ينكسر
      // الربط أبداً بتعذّر الشبكة أو فشل تبادل الرمز.
      final outcome = await AccountWorkspace.linkAccountOnly(repo,
          backendUrl: url, account: account);
      if (!mounted) return;
      switch (outcome) {
        case AccountLinkOutcome.recovered:
          Sfx.pair();
          await repo.setSetting(kOnboardingDoneKey, '1');
          bump(ref);
          // (كارثة العقد المتنازعة 2026-09-19) التهيئة السحابية للمؤسسة
          // فقط — الفردي لا يُنشأ له عقدة ولا فهرس شخصي ينازع مجموعته.
          if (_choice == 'network') {
            unawaited(provisionCloudAfterSignIn(repo, ref, url));
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content:
                  Text('✅ تم استرجاع مؤسستك وبياناتك كاملة — أهلاً بعودتك')));
          // (3.70.0) فحص النسخ الاحتياطية بعد نجاح تسجيل Google — قبل الانتقال.
          await _postSignInBackupScan();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => const LockGate(child: HomeShell())));
          return;
        case AccountLinkOutcome.migrated:
          Sfx.success();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  '✅ تم تسجيل الدخول وربط الحساب — مساحة عملك ثابتة كما هي')));
          // (كارثة العقد المتنازعة 2026-09-19) التهيئة السحابية للمؤسسة
          // فقط — الفردي لا يُنشأ له عقدة ولا فهرس شخصي ينازع مجموعته.
          if (_choice == 'network') {
            unawaited(provisionCloudAfterSignIn(repo, ref, url));
          }
          // (3.70.0) فحص النسخ الاحتياطية بعد نجاح تسجيل Google.
          await _postSignInBackupScan();
          if (!mounted) return;
          // النمط مختار مسبقاً في التدفق التدريجي — نكمل الانتقال.
          await _finishAndNavigate();
          return;
        case AccountLinkOutcome.memberUntouched:
          _restoreIntent = false;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('هذا الجهاز عضو في مجموعة — لا حاجة للربط هنا')));
          return;
        case AccountLinkOutcome.switched:
          Sfx.success();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('✅ تم تبديل مساحة العمل — حُفظت نسخة احتياطية '
                  'ونُزّلت بيانات المساحة الجديدة')));
          // (كارثة العقد المتنازعة 2026-09-19) التهيئة السحابية للمؤسسة
          // فقط — الفردي لا يُنشأ له عقدة ولا فهرس شخصي ينازع مجموعته.
          if (_choice == 'network') {
            unawaited(provisionCloudAfterSignIn(repo, ref, url));
          }
          await _postSignInBackupScan();
          if (!mounted) return;
          await _finishAndNavigate();
          return;
        case AccountLinkOutcome.switchUnavailable:
          Sfx.error();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('هذا الحساب مرتبط بمساحة أخرى ولا توجد لها نسخة '
                  'سحابية — لم نغيّر بياناتك')));
          return;
        case AccountLinkOutcome.switchRestored:
          // (دفعة 65) التبديل فشل بعد التفريغ — استُرجعت البيانات فوراً.
          Sfx.error();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('تعذّر إتمام تبديل المساحة — أُعيدت بياناتك '
                  'الأصلية كما كانت ولم يضِع شيء')));
          return;
        case AccountLinkOutcome.switchDataLost:
          // (دفعة 65) أسوأ حالة: نُبلغ بمكان النسخة صراحةً.
          Sfx.error();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('تعذّر تبديل المساحة وتعذّر الاسترجاع التلقائي — '
                  'بياناتك محفوظة في ملف pre_switch_backup.nexora داخل مجلد '
                  'النسخ')));
          return;
        case AccountLinkOutcome.failed:
          Sfx.error();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('تعذّر الربط — تحقق من اتصالك ثم أعد المحاولة')));
          return;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
                // (2026-09-24) علامة الهوية: العربة نفسها في أيقونة التطبيق.
                Icon(Icons.shopping_cart_rounded,
                    size: 58, color: AppColors.primaryOf(context)),
                const SizedBox(height: 14),
                Text(
                  'مرحباً بك في سجل الحسابات',
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
                const SizedBox(height: 16),
                // (طلب 2026-09-19) استرجاع صريح من أول صفحة: تسجيل Google
                // يعيد المؤسسة وبياناتها المرتبطة بالحساب تلقائياً.
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _restoreWithGoogle,
                    icon: const Icon(Icons.settings_backup_restore_rounded,
                        size: 19),
                    label: const Text(
                      'لديك حساب سابق؟ استرجع بياناتك عبر Google',
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // (طلب 2026-09-19) حذف كامل من الجهاز والسحابة — من نفس
                // الصفحة، وبعده لا استرجاع للبيانات ولا لموقع المجموعة.
                Center(
                  child: TextButton.icon(
                    onPressed: _busy ? null : _purgeEverything,
                    icon: const Icon(Icons.delete_forever_outlined,
                        size: 17, color: Colors.red),
                    label: const Text(
                      'حذف كامل من الجهاز والسحابة',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.red,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // (قانون 2026-09-19) الإعداد يتم داخل نافذة الخيار نفسها —
                // هنا مؤشر انشغال فقط ريثما يكتمل الحفظ أو تسجيل Google.
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(child: CircularProgressIndicator()),
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
        onTap: () => _openModeWindow('personal'),
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
        onTap: () => _openModeWindow('network'),
      );

  /// (3.70.0 — بوابة الاسترجاع) يُمنع منعاً باتاً استرجاع أي بيانات سابقة
  /// أو فحص ملفات النسخ الاحتياطي (هاتف/سحابة) قبل تسجيل دخول Google ناجح:
  /// التحقق من ملكية البيانات أولاً، ثم البحث التلقائي عن النسخة.
  Future<void> _restoreWithGoogle() async {
    if (_busy) return;
    Sfx.click();
    // هل يوجد حساب Google موثق مسبقاً (جدول google_auth)؟
    GoogleUser? linked;
    try {
      final db = await ref.read(repoProvider).database;
      linked = await GoogleAuthService(db).currentUserFromDb();
    } catch (_) {}
    if (linked == null) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تسجيل الدخول مطلوب للاسترجاع'),
          content: const Text(
            'لتأمين وحماية بياناتك المالية، يجب تسجيل الدخول بحساب Google '
            'أولاً للتحقق من ملكية البيانات قبل الاسترجاع.',
            style: TextStyle(height: 1.7),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لاحقاً'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('المتابعة باستخدام Google'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    _restoreIntent = true;
    setState(() => _choice = 'personal');
    await _startWithGoogle();
    // فشل التسجيل أو مسار لا يسترجع: تُنزل النية حتى لا تتسرب لمسار آخر.
    _restoreIntent = false;
  }

  /// (3.70.0) بعد اكتمال تسجيل Google في مسار الاسترجاع: بحث تلقائي عن
  /// nexora-backup-latest.nexora في Google Drive، أو السماح باختيار ملف
  /// نسخة محلية واستعادتها بسلاسة (استعادة ذرّية عبر importAll).
  Future<void> _postSignInBackupScan() async {
    if (!_restoreIntent) return;
    _restoreIntent = false;
    try {
      final repo = ref.read(repoProvider);
      GoogleDriveBackupInfo? info;
      try {
        info = await GoogleDriveService.instance.latestBackup();
      } catch (_) {}
      String? raw;
      var source = '';
      final driveInfo = info;
      if (driveInfo != null && mounted) {
        final when = driveInfo.modifiedTime != null
            ? DateFormat('yyyy-MM-dd HH:mm')
                .format(driveInfo.modifiedTime!.toLocal())
            : '';
        final act = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('نسخة احتياطية على Google Drive'),
            content: Text(
              'وُجد الملف ${GoogleDriveService.backupFileName}'
              '${when.isEmpty ? '' : '\nآخر تعديل: $when'}'
              '${driveInfo.sizeLabel.isEmpty ? '' : '\nالحجم: ${driveInfo.sizeLabel}'}\n\n'
              'استعادتها الآن؟ تُستبدل البيانات الحالية بالكامل (استعادة ذرّية).',
              style: const TextStyle(height: 1.6),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'skip'),
                child: const Text('تخطي'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, 'local'),
                child: const Text('ملف محلي بدلاً منها'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'drive'),
                child: const Text('استعادة من Drive'),
              ),
            ],
          ),
        );
        if (act == 'drive') {
          final docs = await MediaPaths.ensureDocsDir();
          final tmp =
              File('${docs ?? Directory.systemTemp.path}/drive_restore.nexora');
          await GoogleDriveService.instance.downloadLatestTo(tmp);
          raw = await tmp.readAsString();
          source = 'Google Drive';
          try {
            await tmp.delete();
          } catch (_) {}
        } else if (act != 'local') {
          return;
        }
      }
      if (raw == null) {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('استرجاع نسخة محلية'),
            content: Text(
              info == null
                  ? 'لم يُعثر على نسخة احتياطية في Google Drive.\n\n'
                      'يمكنك اختيار ملف نسخة محلية (‎.nexora‎ أو JSON) '
                      'واستعادته الآن.'
                  : 'اختر ملف النسخة المحلية (‎.nexora‎ أو JSON) لاستعادته.',
              style: const TextStyle(height: 1.6),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('تخطي'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('اختيار ملف'),
              ),
            ],
          ),
        );
        if (go != true || !mounted) return;
        final res = await FilePicker.platform
            .pickFiles(type: FileType.any, withData: true);
        if (res == null) return;
        final f = res.files.single;
        if (f.path != null) {
          raw = await File(f.path!).readAsString();
        } else if (f.bytes != null) {
          raw = utf8.decode(f.bytes!);
        }
        source = 'ملف محلي';
      }
      if (raw == null) return;
      final cleaned = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) throw const FormatException('ملف غير صالح');
      final n = await repo.importAll(Map<String, Object?>.from(decoded));
      try {
        final queued = await repo.resyncAllToGroup();
        if (queued > 0) ref.read(syncEngineProvider).notifyNewOperation();
      } catch (_) {}
      bump(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ تمت الاستعادة من $source ($n سجلًا)')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّرت استعادة النسخة: $e')));
      }
    }
  }

  /// (طلب 2026-09-19) «حذف كامل من كل مكان»: الجهاز + السحابة — لا يبقى
  /// ما يُسترجع: لا البيانات ولا موقع الجهاز في مجموعته (تُحذف بصمة
  /// device_index وفهرس Google وقيود العضوية). الاشتراك المدفوع وحده
  /// يبقى أصلاً مالياً.
  Future<void> _purgeEverything() async {
    if (_busy) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ حذف كامل من الجهاز والسحابة'),
        content: const Text(
          'سيُحذف كل شيء نهائياً ومن كل مكان:\n\n'
          '• كل البيانات المحلية على هذا الجهاز.\n'
          '• كل بياناتك من السحابة (المساحة، النسخ، السجل).\n'
          '• موقع جهازك في مجموعته (إن كان عضواً) وبصمة الجهاز وفهرس '
          'حساب Google.\n\n'
          'بعد هذا الحذف لا يمكن استرجاع بياناتك ولا موقعك في المجموعة '
          'أبداً. يُستثنى الاشتراك المدفوع فقط.\n\n'
          'هل أنت متأكد تماماً؟',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف كل شيء من كل مكان'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك للحذف الكامل من الجهاز والسحابة',
    );
    if (!authed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لم تكتمل المصادقة — أُلغي الحذف')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final engine = ref.read(syncEngineProvider);
      try {
        engine.stop();
      } catch (_) {}
      // 1) السحابة: قيود الجهاز تُ مسح من كل مكان (عضواً كان أو مالكاً).
      try {
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        if (url.isNotEmpty) {
          await CloudJoin.purgeDeviceEverywhere(repo, backendUrl: url);
        }
        final db = await repo.database;
        try {
          await GoogleAuthService(db).signOut();
        } catch (_) {}
      } catch (_) {}
      // 2) الجهاز: مسح كامل (القاعدة + الوسائط + ملفات الاقتران).
      await FactoryReset.wipeAllLocalData();
      Sfx.success();
      // 3) إقلاع نظيف وبقاء في شاشة الترحيب — نظيفاً تماماً.
      try {
        await repo.initSyncInfra().timeout(const Duration(seconds: 8));
      } catch (_) {}
      try {
        await engine.start();
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ تم الحذف الكامل — الجهاز والسحابة نظيفان'),
          backgroundColor: Color(0xFF16A34A)));
      setState(() => _choice = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر الحذف الكامل: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// (قانون 2026-09-19) الضغط على بطاقة النوع يفتح **نافذة جديدة** خاصة
  /// بالخيار — بلا أي قائمة منسدلة — فيها وصف كامل لنوع الحساب ثم الإعداد
  /// السريع (الاسم + العملة بشرائح اختيار) وزرّا Google / المتابعة محلياً.
  Future<void> _openModeWindow(String mode) async {
    if (_busy) return;
    Sfx.click();
    setState(() => _choice = mode);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ModeWindow(
        mode: mode,
        initialName: _name,
        initialCurrency: _currency,
        onGoogle: (name, currency) async {
          _name = name;
          _currency = currency;
          Navigator.of(ctx).pop();
          await _startWithGoogle();
        },
        onSkip: (name, currency) async {
          _name = name;
          _currency = currency;
          Navigator.of(ctx).pop();
          await _startLocal();
        },
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

/// (قانون 2026-09-19) نافذة خيار نوع الحساب: وصف موسّع للنوع + إعداد
/// سريع (اسم النشاط + العملة بشرائح اختيار — بلا قوائم منسدلة) + زرّا
/// «ربط بحساب Google» و«المتابعة بدون حساب».
class _ModeWindow extends StatefulWidget {
  final String mode; // 'personal' | 'network'
  final String initialName;
  final String initialCurrency;
  final Future<void> Function(String name, String currency) onGoogle;
  final Future<void> Function(String name, String currency) onSkip;
  const _ModeWindow({
    required this.mode,
    required this.initialName,
    required this.initialCurrency,
    required this.onGoogle,
    required this.onSkip,
  });

  @override
  State<_ModeWindow> createState() => _ModeWindowState();
}

class _ModeWindowState extends State<_ModeWindow> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName);
  late String _currency = widget.initialCurrency;
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit(Future<void> Function(String, String) action) {
    if (_busy) return;
    setState(() => _busy = true);
    final name =
        _nameCtrl.text.trim().isEmpty ? 'متجري' : _nameCtrl.text.trim();
    action(name, _currency);
  }

  @override
  Widget build(BuildContext context) {
    final personal = widget.mode == 'personal';
    final color = personal ? const Color(0xFF16A34A) : const Color(0xFF0EA5E9);
    final title = personal ? 'حساب فردي' : 'حساب مؤسسة';
    final icon = personal ? Icons.storefront_rounded : Icons.hub_rounded;
    final lead = personal
        ? 'مناسب للمتجر الواحد ودفتر الديون الشخصي — كل بياناتك على هذا '
            'الجهاز، وإعداداتك محصورة وبسيطة.'
        : 'مناسب للمنشآت متعددة الأجهزة والفروع — مزامنة سحابية فورية '
            'وإعدادات مؤسسة كاملة.';
    final bullets = personal
        ? const [
            '• بياناتك محلية على هذا الجهاز — سرعة وبساطة بلا تعقيد.',
            '• لا يمكن إنشاء مجموعات من الحساب الفردي إطلاقاً.',
            '• يمكنك الانضمام لاحقاً إلى مؤسسة قائمة عبر رمز دعوة المدير.',
            '• زر «حذف الحساب» في الإعدادات يمسح كل بياناتك نهائياً '
                '(عدا بصمة الجهاز والاشتراك المدفوع).',
          ]
        : const [
            '• أنشئ مجموعتك وكن مديرها الوحيد — لا مدير ثانياً أبداً.',
            '• اربط أجهزة الكاشير والمحاسبين بدعوات QR أو رمز من 6 أرقام.',
            '• مزامنة فورية للعمليات والأرصدة بين كل الأجهزة.',
            '• إعدادات المؤسسة الكاملة: الأجهزة، الصلاحيات، الاشتراك، '
                'والنسخ السحابي.',
            '• هوية Google دائمة: مؤسستك تعود كاملة على أي جهاز بتسجيل واحد.',
          ];
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, color: color, size: 30),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق',
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(lead,
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.6,
                      color: AppColors.text2Of(context))),
              const SizedBox(height: 10),
              for (final b in bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(b,
                      style: const TextStyle(fontSize: 12.5, height: 1.55)),
                ),
              const SizedBox(height: 10),
              const Divider(height: 1),
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
              const Text('العملة الأساسية',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in kDefaultCurrencies)
                    ChoiceChip(
                      label: Text('${c.symbol} ${c.code}'),
                      selected: _currency == c.code,
                      onSelected: (_) => setState(() => _currency = c.code),
                    ),
                ],
              ),
              if (!personal) ...[
                const SizedBox(height: 12),
                Text(
                  'بعد الإكمال سيفتح معالج المجموعة: أنشئ مجموعتك من هذا '
                  'الجهاز أو اربط أجهزة فريقك.',
                  style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: AppColors.text3Of(context)),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _submit(widget.onGoogle),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.account_circle_outlined),
                  label: const Text('ربط بحساب Google والمتابعة',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _submit(widget.onSkip),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text('المتابعة بدون حساب (محلياً)',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
