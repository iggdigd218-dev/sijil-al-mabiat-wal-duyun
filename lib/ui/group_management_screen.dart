// شاشة موحّدة لإدارة المجموعة (أجهزة + مستخدمون + طرق الربط) — للمدير فقط.
// تظهر مكان شاشة "الأجهزة" للمدراء، وتجمع في مكان واحد:
//  1) زر "ربط جهاز/حساب جديد" يعرض نافذة بكل الطرق (QR، رمز نصي، IP يدوي، كود تعريف للعميل).
//  2) قائمة الأجهزة المرتبطة مع صلاحياتها.
//  3) قائمة المستخدمين والصلاحيات + إعادة تعيين PIN/كلمة المرور.
//  4) النسخ الاحتياطي.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/cloud_join.dart';
import 'cloud_sync_section.dart';
import 'devices_screen.dart' show DeviceCard;
import 'join_group_flow.dart';
import 'qr_pair_scanner.dart' show scanQrPair;
import 'sync_settings_section.dart' show PairingQrDialog, PairingQrInfo;
import 'widgets.dart';

class GroupManagementScreen extends ConsumerStatefulWidget {
  const GroupManagementScreen({super.key});

  @override
  ConsumerState<GroupManagementScreen> createState() => _State();
}

class _State extends ConsumerState<GroupManagementScreen> {
  Timer? _joinReqTimer;

  @override
  void initState() {
    super.initState();
    // استطلاع طلبات الانضمام المعلّقة كل 5 ثوانٍ (المدير فقط).
    _joinReqTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkJoinRequests(),
    );
    _checkJoinRequests();
  }

  @override
  void dispose() {
    _joinReqTimer?.cancel();
    super.dispose();
  }

  bool _joinSheetOpen = false;

  Future<void> _checkJoinRequests() async {
    if (!mounted || _joinSheetOpen) return;
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = (st['cloudBackendUrl'] ?? '').trim();
      if (url.isEmpty) return;
      final reqs = await CloudJoin.fetchJoinRequests(repo, backendUrl: url);
      if (reqs.isEmpty || !mounted) return;
      _joinSheetOpen = true;
      await showJoinApprovalSheet(context, ref, reqs.first, backendUrl: url);
      _joinSheetOpen = false;
      if (mounted) bump(ref);
    } catch (_) {
      _joinSheetOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // حارس صلاحيات: المدير فقط.
    final isOwnerAsync = ref.watch(isOwnerProvider);
    return isOwnerAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('إدارة المجموعة')),
        body: EmptyState(
          icon: Icons.error_outline,
          title: 'خطأ',
          message: '$e',
        ),
      ),
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
        // توحيد الواجهة (دفعة 51): قائمة واحدة «الأجهزة والمستخدمين» —
        // كل بطاقة جهاز تحمل دوره وصلاحياته وإجراءاته، لا تبويبين منفصلين.
        return Scaffold(
          appBar: AppBar(
            title: const Text('الأجهزة والمستخدمين'),
            actions: [
              IconButton(
                tooltip: 'إضافة جهاز جديد',
                icon: const Icon(Icons.add_link),
                onPressed: () => _showPairHub(context),
              ),
            ],
          ),
          body: const _DevicesTab(),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showPairHub(context),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('إضافة جهاز جديد'),
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
  Future<void> _editDevicePermissions(
    BuildContext context,
    WidgetRef ref,
    Map<String, Object?> device,
  ) async {
    final users = ref.read(usersProvider).valueOrNull ?? const <AppUser>[];
    final uid = device['user_id'] as int?;
    AppUser? current;
    if (uid != null) {
      try {
        current = users.firstWhere((u) => u.id == uid);
      } catch (_) {
        current = null;
      }
    }
    var role = current?.role ?? UserRole.viewer;
    var perms = <String>{
      ...kPerms
          .where((p) => (current?.permissions[p.key] ?? false))
          .map((p) => p.key)
    };
    // نلتقط المراجع قبل فتح النافذة: الشاشة الخلفية يُعاد بناؤها مع كل
    // نشاط مزامنة، وإن أُتلفت أثناء فتح النافذة يصبح ref غير صالح
    // («Cannot use ref after the widget was disposed») فيفشل الحفظ.
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          void setRole(UserRole r) {
            setDlg(() {
              role = r;
              perms = defaultPerms(r)
                  .entries
                  .where((e) => e.value)
                  .map((e) => e.key)
                  .toSet();
            });
          }

          // دور المدير لا يُمنح لأي عضو — الوكيل أعلى دور متاح، يقوم
          // بعمل المدير أثناء غيابه ويملك كل الصلاحيات افتراضياً.
          final isAgent = role == UserRole.agent;
          return AlertDialog(
            title: Text('صلاحيات: ${device['name'] ?? 'الجهاز'}'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('الدور',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      // «مدير النظام» محذوف من الخيارات: لا يُمنح لأي عضو.
                      for (final r in UserRole.values)
                        if (r != UserRole.admin)
                          ChoiceChip(
                            label: Text('${r.icon} ${r.label}'),
                            selected: role == r,
                            onSelected: (_) => setRole(r),
                          ),
                    ],
                  ),
                  if (isAgent)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '🛡️ الوكيل يقوم بعمل المدير أثناء غيابه — يملك كل '
                        'الصلاحيات، ويمكنك تعديلها بدقة أدناه.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: AppColors.infoOf(ctx),
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  const Text('الصلاحيات التفصيلية',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                    for (final p in kPerms)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: perms.contains(p.key),
                        title: Text(p.label),
                        onChanged: (v) => setDlg(() {
                          if (v == true) {
                            perms.add(p.key);
                          } else {
                            perms.remove(p.key);
                          }
                        }),
                      ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    // repo/engine مُلتقطان قبل فتح النافذة — لا نلمس ref
                    // هنا إطلاقاً: قد تكون الشاشة الخلفية أُتلفت وأُعيد
                    // بناؤها أثناء بقاء النافذة مفتوحة.
                    await repo.setDevicePermissions(
                        device['id'] as String, role, perms);
                    // فرض فوري: نبثّ إشعارًا لكل الأقران ليسحب الجهاز المعني
                    // صلاحياته الجديدة خلال ثوانٍ (<10 ثوانٍ) دون انتظار الدورية.
                    await engine.broadcastRosterChange();
                    if (ctx.mounted) Navigator.pop(ctx);
                    Sfx.success();
                  } catch (e) {
                    Sfx.error();
                    if (ctx.mounted) {
                      showSnack(ctx, 'تعذّر حفظ الصلاحيات: $e', error: true);
                    }
                  }
                },
                child: const Text('حفظ الصلاحيات'),
              ),
            ],
          );
        },
      ),
    );
  }

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
        // مراجع مُلتقطة مرة واحدة: كل الاستدعاءات أدناه تحدث بعد await
        // (نوافذ تأكيد/إدخال) وقد تُتلف الشاشة أثناءها — استعمال ref
        // بعد الإتلاف يرمي «Cannot use ref after the widget was disposed».
        final repo = ref.read(repoProvider);
        final engine = ref.read(syncEngineProvider);
        void safeBump() {
          if (mounted) bump(ref);
        }

        return FutureBuilder<Map<String, Object?>?>(
          future: repo.ownDeviceRow(),
          builder: (ctx, snap) {
            final own = snap.data;
            final ownId = own?['id'] as String?;
            final amITheOwner =
                own != null && ((own['is_owner'] ?? 0) as int) == 1;
            final hostRow =
                list.where((r) => ((r['is_owner'] ?? 0) as int) == 1).toList();
            final hostId =
                hostRow.isNotEmpty ? hostRow.first['id'] as String : null;
            return RefreshIndicator(
              onRefresh: () async => bump(ref),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
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
                        await repo.assignDeviceUser(d['id'] as String, uid);
                        await engine.broadcastRosterChange();
                        safeBump();
                      },
                      // (دفعة 51) تعديل الدور مباشرة من البطاقة: يضبط دور
                      // مستخدم الجهاز وصلاحياته الافتراضية ويبثّها فوراً.
                      onRoleChanged: amITheOwner
                          ? (role) async {
                              await repo.setDevicePermissions(
                                d['id'] as String,
                                role,
                                defaultPerms(role)
                                    .entries
                                    .where((e) => e.value)
                                    .map((e) => e.key)
                                    .toSet(),
                              );
                              await engine.broadcastRosterChange();
                              Sfx.success();
                              safeBump();
                            }
                          : null,
                      onPermissions: () async {
                        await _editDevicePermissions(context, ref, d);
                        safeBump();
                      },
                      onRename: () async {
                        final name = await promptDialog(
                          context,
                          title: 'إعادة تسمية الجهاز',
                          initial: (d['name'] ?? '') as String,
                          label: 'اسم الجهاز',
                        );
                        if (name == null || name.trim().isEmpty) return;
                        await repo.renameDevice(d['id'] as String, name.trim());
                        safeBump();
                      },
                      onRevoke: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'حظر الجهاز',
                          message:
                              'سيُمنع "${d['name']}" من المزامنة حتى إعادة السماح.',
                          confirmText: 'حظر',
                          danger: true,
                        );
                        if (ok == true) {
                          await repo.revokeDevice(d['id'] as String);
                          // (دفعة 54) الحظر أيضاً يبث شاهدة الطرد: الجهاز
                          // المحظور يُقصى لحظياً ويعود لوضع مستقل.
                          await engine.broadcastEviction(d['id'] as String);
                          try {
                            await engine.broadcastRosterChange();
                          } catch (_) {}
                          safeBump();
                        }
                      },
                      onRestore: () async {
                        await repo.restoreDevice(d['id'] as String);
                        // (دفعة 54) حذف شاهدة الطرد وإلا أقصى الجهازُ
                        // المستعاد نفسَه عند فحصه القادم.
                        await engine.clearEvictionBroadcast(d['id'] as String);
                        try {
                          await engine.broadcastRosterChange();
                        } catch (_) {}
                        safeBump();
                      },
                      onExpel: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'طرد الجهاز',
                          message:
                              'سيُطرد "${d['name']}" من المجموعة ويمسح بياناته عند أول اتصال.',
                          confirmText: 'طرد',
                          danger: true,
                        );
                        if (ok == true) {
                          await repo.expelDevice(d['id'] as String);
                          // (دفعة 54) بروتوكول الطرد النشط: شاهدة صريحة في
                          // /evictions + حذف عقدته من /roster — تصل
                          // المستهدف لحظياً عبر قناته المخصصة.
                          await engine.broadcastEviction(d['id'] as String,
                              reason: 'expelled_by_manager');
                          // بث تغيير السجل لبقية الأجهزة (LAN + roster).
                          try {
                            await engine.broadcastRosterChange();
                          } catch (_) {}
                          safeBump();
                        }
                      },
                      onTransferOwner: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'تسليم الإدارة',
                          message:
                              'سيصبح "${d['name']}" هو المدير وتصبح أنت عضوًا.',
                          confirmText: 'تسليم',
                          danger: true,
                        );
                        if (ok == true) {
                          try {
                            await repo.transferOwnership(d['id'] as String);
                            safeBump();
                            if (mounted) {
                              showSnack(context, '✅ تم تسليم الإدارة.');
                              Navigator.of(context).popUntil((r) => r.isFirst);
                            }
                          } catch (e) {
                            if (mounted) {
                              showSnack(context, 'تعذّر: $e', error: true);
                            }
                          }
                        }
                      },
                      onResetSecret: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'إعادة تعيين مفتاح الجهاز',
                          message: 'سيفقد الجهاز الاتصال حتى يعيد الاقتران.',
                          confirmText: 'إعادة التعيين',
                          danger: true,
                        );
                        if (ok == true) {
                          final s =
                              await repo.resetDeviceSecret(d['id'] as String);
                          safeBump();
                          if (mounted) {
                            showDialog(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('المفتاح الجديد'),
                                content: SelectableText(
                                  s,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c),
                                    child: const Text('تم'),
                                  ),
                                ],
                            ),
                          );
                          }
                        }
                      },
                      onCloudLink: () => showCloudInviteDialog(context, ref),
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


// ═══════════════════════════ نافذة الربط الموحدة ════════════════════════════
class _PairHubSheet extends ConsumerStatefulWidget {
  _PairHubSheet();
  @override
  ConsumerState<_PairHubSheet> createState() => _PairHubSheetState();
}

class _PairHubSheetState extends ConsumerState<_PairHubSheet> {
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
      final st = await repo.settings();
      final port = int.tryParse(st['lanSyncPort'] ?? '43053') ?? 43053;
      // تأكّد من أن خادم المزامنة يستمع فعلاً قبل توليد الرمز.
      String? ip;
      try {
        for (final iface in await NetworkInterface.list(
            includeLoopback: false, type: InternetAddressType.IPv4)) {
          for (final a in iface.addresses) {
            if (!a.isLoopback && a.type == InternetAddressType.IPv4) {
              ip = a.address;
              break;
            }
          }
          if (ip != null) break;
        }
      } catch (_) {}
      final engine = ref.read(syncEngineProvider);
      if (engine.hasStarted) engine.start();
      final hostUp = await engine.ensureLanHost(port);
      if (!hostUp) {
        if (mounted) {
          showSnack(
              context,
              'تعذّر تشغيل خادم المزامنة على المنفذ $port. تأكد أن المنفذ حر واسمح للتطبيق في جدار الحماية.',
              error: true);
        }
        return;
      }
      final info = await repo.createPairingToken(ipAddress: ip, port: port);
      setState(() {
        _pairAt = DateTime.now();
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_pairAt == null) return;
        final left = 300 - DateTime.now().difference(_pairAt!).inSeconds;
        if (left <= 0 && mounted) {
          setState(() {
            _pairAt = null;
          });
          _tick?.cancel();
        }
      });
      Sfx.pair();
      // افتح حوار QR الكبير.
      if (!mounted) return;
      Navigator.pop(context);
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
          ip: ip,
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
    // كان الخلل هنا: الكاميرا تُفتح وتُهمل نتيجتها فيخرج الجهاز بلا ربط.
    // الآن: مسح ← تأكيد ← اقتران فعلي ← استلام لقطة البيانات كاملة.
    // نلتقط container وnavigator قبل إغلاق الـ sheet لأن ref يفنى معها.
    final container = ProviderScope.containerOf(context, listen: false);
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    Sfx.click();
    final data = await scanQrPair(rootContext);
    if (data == null || !rootContext.mounted) return;
    await joinGroupFromScan(rootContext, container, data);
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
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'ربط جهاز أو حساب جديد',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'اختر طريقة الربط المناسبة. ستنضم الأجهزة الجديدة إلى هذه المجموعة وتستلم نسخة من البيانات.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black54,
                fontSize: 12,
                height: 1.6,
              ),
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
              icon: Icons.cloud_sync_outlined,
              color: const Color(0xFF0EA5E9),
              title: 'ربط عضو عبر السحابة (عبر الإنترنت)',
              subtitle:
                  'لجهاز بعيد خارج شبكة Wi-Fi: يُنشئ دعوة سحابية (QR + رمز صالح 24 ساعة) بنفس رابط حسابك السحابي — تُحذف بيانات جهاز العضو وتُستبدل بنسخة المجموعة.',
              onTap: () {
                final rootContext =
                    Navigator.of(context, rootNavigator: true).context;
                Navigator.pop(context);
                Sfx.click();
                showCloudInviteDialog(rootContext, ref);
              },
            ),
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

  void _showActivationCode(BuildContext context) async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    final port = int.tryParse(st['lanSyncPort'] ?? '43053') ?? 43053;
    final engine = ref.read(syncEngineProvider);
    if (engine.hasStarted) engine.start();
    final ok = await engine.ensureLanHost(port);
    if (!ok) {
      if (mounted) {
        showSnack(context, 'تعذّر تشغيل خادم المزامنة على المنفذ $port.',
            error: true);
      }
      return;
    }
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('كود تعريف الجهاز'),
        content: FutureBuilder<Map<String, String?>>(
          future: repo.createPairingToken(port: port),
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
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black54,
                    height: 1.5,
                  ),
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
                child: SelectableText(
                  v,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
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
  const _HubTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

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
                    color: color.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.black54,
                          height: 1.5,
                        ),
                      ),
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

// ═══════════════ موافقة المدير على طلبات الانضمام (دفعة 51) ═══════════════

/// نافذة «طلب انضمام جهاز جديد»: اسم الجهاز + بصمته + اختيار الدور،
/// وزرا «قبول وتفعيل» / «رفض». تُستدعى تلقائياً عند رصد طلب معلّق.
Future<void> showJoinApprovalSheet(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> request, {
  required String backendUrl,
}) async {
  final repo = ref.read(repoProvider);
  final engine = ref.read(syncEngineProvider);
  final deviceId = '${request['deviceId'] ?? ''}';
  final deviceName = '${request['deviceName'] ?? 'جهاز جديد'}';
  final fp = '${request['fingerprint'] ?? ''}';
  final platform = '${request['platform'] ?? ''}';
  var role = UserRole.accountant;
  Sfx.notify();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              18, 18, 18, 18 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.devices_other,
                        color: Color(0xFF0EA5E9)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('طلب انضمام جهاز جديد',
                            style: TextStyle(
                                fontSize: 15.5, fontWeight: FontWeight.w800)),
                        Text(
                          deviceName,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'المنصة: $platform${fp.isEmpty ? '' : '  ·  بصمة العتاد: $fp'}',
                style: TextStyle(
                    fontSize: 11.5, color: AppColors.text3Of(ctx)),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<UserRole>(
                initialValue: role,
                decoration: const InputDecoration(
                  labelText: 'الدور والصلاحيات',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final r in UserRole.values)
                    if (r != UserRole.admin)
                      DropdownMenuItem(
                          value: r, child: Text('${r.icon} ${r.label}')),
                ],
                onChanged: (v) =>
                    setSheet(() => role = v ?? UserRole.accountant),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red),
                      icon: const Icon(Icons.close),
                      label: const Text('رفض'),
                      onPressed: () async {
                        try {
                          await CloudJoin.rejectJoinRequest(repo,
                              backendUrl: backendUrl, deviceId: deviceId);
                        } catch (_) {}
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('قبول وتفعيل'),
                      onPressed: () async {
                        try {
                          await CloudJoin.approveJoinRequest(repo,
                              backendUrl: backendUrl,
                              deviceId: deviceId,
                              deviceName: deviceName,
                              roleCode: role.code);
                          await engine.broadcastRosterChange();
                          Sfx.pair();
                        } catch (e) {
                          if (ctx.mounted) {
                            showSnack(ctx, 'تعذّر القبول: $e', error: true);
                          }
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
