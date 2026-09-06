// شاشة موحّدة لإدارة المجموعة (أجهزة + مستخدمون + طرق الربط) — للمدير فقط.
// تظهر مكان شاشة "الأجهزة" للمدراء، وتجمع في مكان واحد:
//  1) زر "ربط جهاز/حساب جديد" يعرض نافذة بكل الطرق (QR، رمز نصي، IP يدوي، كود تعريف للعميل).
//  2) قائمة الأجهزة المرتبطة مع صلاحياتها.
//  3) قائمة المستخدمين والصلاحيات + إعادة تعيين PIN/كلمة المرور.
//  4) النسخ الاحتياطي.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'backup_screen.dart';
import 'devices_screen.dart' show DeviceCard;
import 'qr_pair_scanner.dart' show scanQrPair;
import 'sync_settings_section.dart' show PairingQrDialog, PairingQrInfo;
import 'users_screen.dart' show UserCard, openUserForm;
import 'widgets.dart';

class GroupManagementScreen extends ConsumerStatefulWidget {
  const GroupManagementScreen({super.key});

  @override
  ConsumerState<GroupManagementScreen> createState() => _State();
}

class _State extends ConsumerState<GroupManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // حارس صلاحيات: المدير فقط.
    final isOwnerAsync = ref.watch(isOwnerProvider);
    return isOwnerAsync.when(
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('إدارة المجموعة')),
          body: EmptyState(
              icon: Icons.error_outline, title: 'خطأ', message: '$e')),
      data: (isOwner) {
        if (!isOwner) {
          return Scaffold(
            appBar: AppBar(title: const Text('إدارة المجموعة')),
            body: const EmptyState(
              icon: Icons.block,
              title: 'غير مصرّح',
              message:
                  'هذه الشاشة للمدير (مالك المجموعة) فقط.\nاطلب من المدير منحك صلاحية إدارة المستخدمين.',
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('إدارة المجموعة'),
            bottom: TabBar(
              controller: _tab,
              tabs: const [
                Tab(icon: Icon(Icons.devices), text: 'الأجهزة'),
                Tab(icon: Icon(Icons.manage_accounts), text: 'المستخدمون'),
                Tab(icon: Icon(Icons.cloud_sync_outlined), text: 'نسخ احتياطي'),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'ربط جهاز/حساب جديد',
                icon: const Icon(Icons.add_link),
                onPressed: () => _showPairHub(context),
              ),
            ],
          ),
          body: TabBarView(
            controller: _tab,
            children: const [
              _DevicesTab(),
              _UsersTab(),
              BackupScreen(embedded: true),
            ],
          ),
        );
      },
    );
  }

  void _showPairHub(BuildContext context) {
    Sfx.click();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PairHubSheet(),
    );
  }
}

// ═══════════════════════════ تبويب الأجهزة ════════════════════════════
class _DevicesTab extends ConsumerStatefulWidget {
  const _DevicesTab();
  @override
  ConsumerState<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends ConsumerState<_DevicesTab> {
  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(devicesProvider);
    final usersAsync = ref.watch(usersProvider);

    return devicesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(icon: Icons.error_outline, title: 'خطأ', message: '$e'),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.devices_other,
            title: 'لا توجد أجهزة',
            message:
                'اضغط زر + في الأعلى لربط أول جهاز عبر QR أو الرمز أو IP يدوي.',
          );
        }
        return FutureBuilder<Map<String, Object?>?>(
          future: ref.read(repoProvider).ownDeviceRow(),
          builder: (ctx, snap) {
            final own = snap.data;
            final ownId = own?['id'] as String?;
            final amITheOwner =
                own != null && ((own['is_owner'] ?? 0) as int) == 1;
            final hostRow = list
                .where((r) => ((r['is_owner'] ?? 0) as int) == 1)
                .toList();
            final hostId =
                hostRow.isNotEmpty ? hostRow.first['id'] as String : null;
            return RefreshIndicator(
              onRefresh: () async => bump(ref),
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                children: [
                  for (final d in list)
                    DeviceCard(
                      data: d,
                      users: (usersAsync.valueOrNull ?? const <AppUser>[])
                          .cast<AppUser>(),
                      isSelf: d['id'] == ownId,
                      isOwnerDevice: d['id'] == hostId,
                      amITheOwner: amITheOwner,
                      onAssign: (uid) async {
                        await ref
                            .read(repoProvider)
                            .assignDeviceUser(d['id'] as String, uid);
                        bump(ref);
                      },
                      onRename: () async {
                        final name = await promptDialog(context,
                            title: 'إعادة تسمية الجهاز',
                            initial: (d['name'] ?? '') as String,
                            label: 'اسم الجهاز');
                        if (name == null || name.trim().isEmpty) return;
                        await ref
                            .read(repoProvider)
                            .renameDevice(d['id'] as String, name.trim());
                        bump(ref);
                      },
                      onRevoke: () async {
                        final ok = await confirmDialog(context,
                            title: 'حظر الجهاز',
                            message:
                                'سيُمنع "${d['name']}" من المزامنة حتى إعادة السماح.',
                            confirmText: 'حظر',
                            danger: true);
                        if (ok == true) {
                          await ref
                              .read(repoProvider)
                              .revokeDevice(d['id'] as String);
                          bump(ref);
                        }
                      },
                      onRestore: () async {
                        await ref
                            .read(repoProvider)
                            .restoreDevice(d['id'] as String);
                        bump(ref);
                      },
                      onExpel: () async {
                        final ok = await confirmDialog(context,
                            title: 'طرد الجهاز',
                            message:
                                'سيُطرد "${d['name']}" من المجموعة ويمسح بياناته عند أول اتصال.',
                            confirmText: 'طرد',
                            danger: true);
                        if (ok == true) {
                          await ref
                              .read(repoProvider)
                              .expelDevice(d['id'] as String);
                          bump(ref);
                        }
                      },
                      onTransferOwner: () async {
                        final ok = await confirmDialog(context,
                            title: 'تسليم الإدارة',
                            message:
                                'سيصبح "${d['name']}" هو المدير وتصبح أنت عضوًا.',
                            confirmText: 'تسليم',
                            danger: true);
                        if (ok == true) {
                          try {
                            await ref
                                .read(repoProvider)
                                .transferOwnership(d['id'] as String);
                            bump(ref);
                            if (mounted) {
                              showSnack(context, '✅ تم تسليم الإدارة.');
                              Navigator.of(context)
                                  .popUntil((r) => r.isFirst);
                            }
                          } catch (e) {
                            if (mounted) {
                              showSnack(context, 'تعذّر: $e', error: true);
                            }
                          }
                        }
                      },
                      onResetSecret: () async {
                        final ok = await confirmDialog(context,
                            title: 'إعادة تعيين مفتاح الجهاز',
                            message:
                                'سيفقد الجهاز الاتصال حتى يعيد الاقتران.',
                            confirmText: 'إعادة التعيين',
                            danger: true);
                        if (ok == true) {
                          final s = await ref
                              .read(repoProvider)
                              .resetDeviceSecret(d['id'] as String);
                          bump(ref);
                          if (mounted) {
                            showDialog(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('المفتاح الجديد'),
                                content: SelectableText(s,
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12)),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(c),
                                      child: const Text('تم'))
                                ],
                              ),
                            );
                          }
                        }
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ═══════════════════════════ تبويب المستخدمين ════════════════════════════
class _UsersTab extends ConsumerWidget {
  const _UsersTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);
    return users.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(icon: Icons.error_outline, title: 'خطأ', message: '$e'),
      data: (list) => ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
        children: [
          const SectionTitle('الأدوار'),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: .85,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: UserRole.values
                .map((r) => Card(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(r.icon, style: const TextStyle(fontSize: 22)),
                          const SizedBox(height: 4),
                          Text(r.label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 18),
          const SectionTitle('المستخدمون'),
          if (list.isEmpty)
            const EmptyState(
                icon: Icons.people_outline,
                title: 'لا مستخدمون',
                message: 'أضف مستخدمًا وحدّد صلاحياته.'),
          for (final u in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: UserCard(user: u),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => openUserForm(context, ref),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('إضافة مستخدم'),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════ نافذة الربط الموحدة ════════════════════════════
class _PairHubSheet extends ConsumerStatefulWidget {
  _PairHubSheet();
  @override
  ConsumerState<_PairHubSheet> createState() => _PairHubSheetState();
}

class _PairHubSheetState extends ConsumerState<_PairHubSheet> {
  Map<String, String?>? _pairInfo;
  DateTime? _pairAt;
  Timer? _tick;
  bool _busy = false;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _generateQr() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final info = await repo.createPairingToken();
      setState(() {
        _pairInfo = info;
        _pairAt = DateTime.now();
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_pairAt == null) return;
        final left =
            300 - DateTime.now().difference(_pairAt!).inSeconds;
        if (left <= 0 && mounted) {
          setState(() {
            _pairInfo = null;
            _pairAt = null;
          });
          _tick?.cancel();
        }
      });
      Sfx.pair();
      // افتح حوار QR الكبير.
      if (!mounted) return;
      Navigator.pop(context);
      final port = int.tryParse(
              (await repo.settings())['lanSyncPort'] ?? '43053') ??
          43053;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PairingQrDialog(
          info: PairingQrInfo(
            token: info['token']!,
            qrContent: info['qr']!,
            expiresAt: DateTime.tryParse(info['expires'] ?? '') ??
                DateTime.now().add(const Duration(minutes: 5)),
          ),
          port: port,
          ip: null,
          primaryColor: Theme.of(context).colorScheme.primary,
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanQr() async {
    Navigator.pop(context);
    Sfx.click();
    await scanQrPair(context);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: .7,
      minChildSize: .5,
      maxChildSize: .95,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 14),
            Text('ربط جهاز أو حساب جديد',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'اختر طريقة الربط المناسبة. ستنضم الأجهزة الجديدة إلى هذه المجموعة وتستلم نسخة من البيانات.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 20),
            _HubTile(
              icon: Icons.qr_code_2_rounded,
              color: const Color(0xFF4CAF50),
              title: 'إنشاء باركود QR للاقتران',
              subtitle:
                  'يعرض باركوداً يمسحه الجهاز الآخر بكاميراه (أسرع طريقة، صالح 5 دقائق).',
              onTap: _generateQr,
            ),
            _HubTile(
              icon: Icons.photo_camera_rounded,
              color: const Color(0xFF2196F3),
              title: 'مسح باركود بالكاميرا',
              subtitle:
                  'للانضمام إلى مجموعة موجودة بجهاز آخر — افتح الكاميرا وامسح باركود المضيف.',
              onTap: _scanQr,
            ),
            const _HubManualTile(),
            _HubTile(
              icon: Icons.vpn_key_outlined,
              color: const Color(0xFF9C27B0),
              title: 'كود تعريف الجهاز (لتفعيل الحسابات عن بُعد)',
              subtitle:
                  'أعطِ هذا الكود للعميل/العضو ليدخله يدوياً في جهازه بعد إدخال IP والمنفذ.',
              onTap: () {
                Navigator.pop(context);
                _showActivationCode(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showActivationCode(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('كود تعريف الجهاز'),
        content: FutureBuilder<Map<String, String?>>(
          future: ref.read(repoProvider).createPairingToken(),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final info = snap.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'أعطِ العميل/العضو البيانات التالية ليدخلها يدوياً في جهازه (صالحة 5 دقائق):',
                  style: TextStyle(fontSize: 12, color: Colors.black54, height: 1.5),
                ),
                const SizedBox(height: 14),
                _kv('الرمز', info['token'] ?? ''),
                _kv('المنفذ', '43053'),
                const SizedBox(height: 10),
                const Text(
                  'على الجهاز الآخر: شاشة المزامنة ← انضمام ← إدخال IP + المنفذ + الرمز.',
                  style: TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text('$k: ', style: const TextStyle(fontWeight: FontWeight.w700)),
            Expanded(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(v,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2)),
              ),
            ),
          ],
        ),
      );
}

class _HubTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _HubTile(
      {required this.icon,
      required this.color,
      required this.title,
      required this.subtitle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: color.withOpacity(.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: Colors.black54,
                              height: 1.5)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_left, color: Colors.black38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HubManualTile extends StatelessWidget {
  const _HubManualTile();
  @override
  Widget build(BuildContext context) {
    return _HubTile(
      icon: Icons.edit_note,
      color: Colors.orange,
      title: 'إدخال بيانات الجهاز يدوياً',
      subtitle:
          'إذا لم يعمل المسح أو كانت الشبكات مختلفة، أدخل IP الجهاز المضيف والمنفذ ورمز الاقتران مباشرة من قسم المزامنة في الإعدادات.',
      onTap: () => Navigator.pop(context),
    );
  }
}
