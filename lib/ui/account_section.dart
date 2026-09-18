// قسم «حساب المؤسسة (Google)» في الإعدادات — الهوية الدائمة للمؤسسة.
//
// للمدير/المستقل فقط: يعرض الحساب المربوط (البريد الإلكتروني) أو زر
// تسجيل الدخول. الربط يجعل مساحة العمل والترخيص يتبعان الحساب —
// فيستعيد المستخدم كل شيء على أي هاتف بمجرد تسجيل الدخول.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cloud_config.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/subscription_guard.dart';
import 'widgets.dart';

class AccountSection extends ConsumerStatefulWidget {
  const AccountSection({super.key});

  @override
  ConsumerState<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends ConsumerState<AccountSection> {
  bool _busy = false;
  String _email = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    final email = await FirebaseAuthRest.savedEmail(repo);
    if (!mounted) return;
    setState(() {
      _email = email;
      _loaded = true;
    });
  }

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final r = await GoogleAuthService(db).signIn();
      final gu = r.user;
      if (gu == null) {
        Sfx.error();
        if (mounted) {
          showSnack(context, r.error ?? 'تعذّر تسجيل الدخول', error: true);
        }
        return;
      }
      FirebaseAccount? account;
      final tok = gu.idToken ?? '';
      if (tok.isNotEmpty) {
        account = await FirebaseAuthRest.signInWithGoogleIdToken(tok);
      }
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
        case AccountLinkOutcome.migrated:
          Sfx.success();
          bump(ref);
          showSnack(context,
              '✅ تم تسجيل الدخول وربط الحساب — مساحة عملك ثابتة كما هي');
          // (دفعة 65) تهيئة سحابية تلقائية: مساحة العمل + بدء التجربة
          // بختم خادم Firebase + تحديث «تفاصيل الاشتراك» فوراً.
          unawaited(_provisionCloudAfterSignIn(repo, ref, url));
          break;
        case AccountLinkOutcome.memberUntouched:
          showSnack(context, 'جهاز العضو يتبع مجموعة مديره — لا حاجة للربط');
          break;
        case AccountLinkOutcome.switched:
          // (دفعة 65) الحساب كان مرتبطاً بمساحة أخرى: حُظر الدمج، وأُخذت
          // نسخة pre_switch_backup.nexora، وفُرّغت الجداول، ونُزّلت بيانات
          // المساحة الجديدة — نُبلغ المستخدم بما حدث بشفافية.
          Sfx.success();
          bump(ref);
          showSnack(context,
              '✅ تم تبديل مساحة العمل — حُفظت نسخة pre_switch_backup.nexora '
              'ونُزّلت بيانات المساحة الجديدة');
          unawaited(_provisionCloudAfterSignIn(repo, ref, url));
          break;
        case AccountLinkOutcome.switchUnavailable:
          Sfx.error();
          showSnack(context,
              'هذا الحساب مرتبط بمساحة أخرى ولا توجد لها نسخة سحابية — '
              'لم نغيّر بياناتك',
              error: true);
          break;
        case AccountLinkOutcome.switchRestored:
          // (دفعة 65) التبديل فشل بعد التفريغ — استُرجعت البيانات فوراً.
          Sfx.error();
          showSnack(context,
              'تعذّر إتمام تبديل المساحة — أُعيدت بياناتك الأصلية كما كانت '
              'ولم يضِع شيء (نسخة pre_switch_backup.nexora محفوظة)',
              error: true);
          break;
        case AccountLinkOutcome.switchDataLost:
          // (دفعة 65) أسوأ حالة: نُبلغ بمكان النسخة صراحةً ليستعيدها يدوياً.
          Sfx.error();
          showSnack(context,
              'تعذّر تبديل المساحة وتعذّر الاسترجاع التلقائي — بياناتك '
              'محفوظة في ملف pre_switch_backup.nexora داخل مجلد النسخ؛ '
              'استعدها من شاشة النسخ الاحتياطي',
              error: true);
          break;
        case AccountLinkOutcome.failed:
          Sfx.error();
          showSnack(context, 'تعذّر الربط — تحقق من اتصالك ثم أعد المحاولة',
              error: true);
          break;
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// تسجيل الخروج من حساب Google (دفعة 65).
  ///
  ///  • يقطع الجلسة عبر `GoogleSignIn.disconnect/signOut` — وبما أن المثال
  ///    موحّد (SSO) تُسحب صلاحية Drive معها في الخطوة نفسها.
  ///  • يحذف مفاتيح `account.*` من جدول settings عبر
  ///    `FirebaseAuthRest.clearSession`.
  ///  • **لا يمسّ الحركات ولا العملاء ولا الأرصدة في SQLite** — تبقى كما هي.
  ///  • يعود إلى جلسة مجهولة صامتة (`initSilentAuth`) فتبقى المزامنة
  ///    المحلية تعمل دون انقطاع.
  Future<void> _signOut() async {
    final ok = await confirmDialog(
      context,
      title: 'تسجيل الخروج من حساب Google',
      message: 'سيُفصل حساب Google عن هذا الجهاز وتتوقف المزامنة السحابية '
          'حتى تسجّل الدخول من جديد.\n\n'
          'بياناتك (الحركات، العملاء، الأرصدة) تبقى كما هي ولا تُحذف.',
      confirmText: 'تسجيل الخروج',
      danger: true,
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      await GoogleAuthService(db).signOut();
      await FirebaseAuthRest.clearSession(repo);
      // جلسة مجهولة صامتة بديلة — بلا مفاتيح حساب، وبلا مساس بالبيانات.
      await FirebaseAuthRest.initSilentAuth(repo);
      bump(ref);
      if (!mounted) return;
      showSnack(context, 'تم تسجيل الخروج — بياناتك محفوظة على الجهاز');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر تسجيل الخروج: $e', error: true);
    } finally {
      if (mounted) {
        await _load();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  /// تهيئة سحابية تلقائية بعد نجاح تسجيل الدخول بحساب Google (دفعة 65):
  ///   1) تهيئة مساحة العمل `workspaces/{ws}` وتثبيت عضوية المالك.
  ///   2) `SubscriptionGuard.ensureTrialStarted` — تسجيل بداية الثلاثين
  ///      يوماً بختم **خادم Firebase** (لا ساعة الجهاز).
  ///   3) إبطال `subscriptionProvider` فتحدّث «تفاصيل الاشتراك» فوراً
  ///      لتعرض «الخطة: تجريبية مجانية — متبقي X» بدل «فعّل المزامنة أولاً».
  ///
  /// لا ترفع استثناءً أبداً: تعذّر الشبكة يجب ألّا يُفسد تسجيل الدخول نفسه.
  Future<void> _provisionCloudAfterSignIn(
      Repo repo, WidgetRef ref, String url) async {
    if (url.isEmpty) return;
    try {
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      await CloudJoin.ensureOwnerMembership(repo,
          backendUrl: url, workspaceId: ws);
      await SubscriptionGuard.ensureTrialStarted(repo,
          backendUrl: url, workspaceId: ws);
      ref.invalidate(subscriptionProvider);
    } catch (_) {
      // خلفية صامتة.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final linked = _email.isNotEmpty;
    return Card(
      child: ListTile(
        leading: Icon(
          linked ? Icons.verified_user_outlined : Icons.account_circle_outlined,
          color: linked ? const Color(0xFF059669) : const Color(0xFF7C3AED),
        ),
        title: Text(linked ? 'مؤسستك مربوطة بحسابك' : 'اربط مؤسستك بحساب Google'),
        subtitle: Text(
          linked
              ? '$_email\nبياناتك ومؤسستك تعودان تلقائياً على أي هاتف بهذا الحساب.'
              : 'سجّل الدخول مرة واحدة لتبقى مؤسستك وترخيصك محفوظين مع '
                  'حسابك — حتى لو غيّرت هاتفك أو حذفت التطبيق.',
          style: const TextStyle(fontSize: 11.5, height: 1.5),
        ),
        isThreeLine: true,
        trailing: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : linked
                ? IconButton(
                    tooltip: 'تسجيل الخروج من حساب Google',
                    onPressed: _signOut,
                    icon: const Icon(Icons.logout),
                  )
                : const Icon(Icons.chevron_left),
        onTap: linked || _busy ? null : _signIn,
      ),
    );
  }
}
