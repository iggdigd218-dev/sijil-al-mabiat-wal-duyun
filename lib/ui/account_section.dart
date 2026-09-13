// قسم «حساب المؤسسة (Google)» في الإعدادات — الهوية الدائمة للمؤسسة.
//
// للمدير/المستقل فقط: يعرض الحساب المربوط (البريد الإلكتروني) أو زر
// تسجيل الدخول. الربط يجعل مساحة العمل والترخيص يتبعان الحساب —
// فيستعيد المستخدم كل شيء على أي هاتف بمجرد تسجيل الدخول.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cloud_config.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
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
      final outcome = await AccountWorkspace.adoptOrRecover(repo,
          backendUrl: url, account: account);
      if (!mounted) return;
      switch (outcome) {
        case AccountLinkOutcome.recovered:
        case AccountLinkOutcome.migrated:
          Sfx.success();
          bump(ref);
          showSnack(context,
              '✅ تم ربط مؤسستك بحسابك — بياناتك ستعود معك على أي جهاز');
          break;
        case AccountLinkOutcome.memberUntouched:
          showSnack(context, 'جهاز العضو يتبع مجموعة مديره — لا حاجة للربط');
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
        trailing: linked
            ? null
            : (_busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_left)),
        onTap: linked || _busy ? null : _signIn,
      ),
    );
  }
}
