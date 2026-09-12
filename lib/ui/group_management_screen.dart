// شاشة موحّدة لإدارة المجموعة (أجهزة + مستخدمون + طرق الربط) — للمدير فقط.
// تظهر مكان شاشة "الأجهزة" للمدراء، وتجمع في مكان واحد:
//  1) زر "ربط جهاز/حساب جديد" يعرض نافذة بكل الطرق (QR، رمز نصي، IP يدوي، كود تعريف للعميل).
//  2) قائمة الأجهزة المرتبطة مع صلاحياتها.
//  3) قائمة المستخدمين والصلاحيات + إعادة تعيين PIN/كلمة المرور.
//  4) النسخ الاحتياطي.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/cloud_join.dart';
import 'cloud_sync_section.dart';
import 'devices_screen.dart' show DeviceCard;
import 'trial_ui.dart' show SeatUsageBadge;
import 'widgets.dart';

class GroupManagementScreen extends ConsumerStatefulWidget {
  const GroupManagementScreen({super.key});

  @override
  ConsumerState<GroupManagementScreen> createState() => _State();
}

class _State extends ConsumerState<GroupManagementScreen> {
  // (دفعة 57) قناة SSE حيّة على /joinRequests بدل استطلاع كل 5 ثوانٍ —
  // طلب الاقتران يصل للمدير لحظياً بصفر كمون وبلا ضجيج شبكي دوري.
  JoinRequestWatcher? _joinReqWatcher;

  @override
  void initState() {
    super.initState();
    _startJoinRequestWatcher();
    _checkJoinRequests();
  }

  Future<void> _startJoinRequestWatcher() async {
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = (st['cloudBackendUrl'] ?? '').trim();
      if (url.isEmpty || !mounted) return;
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws =
          wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      _joinReqWatcher = JoinRequestWatcher(
        backendUrl: url,
        workspaceId: ws,
        onRequestsChanged: () {
          if (mounted) _checkJoinRequests();
        },
      )..start();
    } catch (_) {}
  }

  @override
  void dispose() {
    _joinReqWatcher?.stop();
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
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      final reqs = await CloudJoin.fetchJoinRequests(repo,
          backendUrl: url, workspaceId: ws);
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
              // (باقة المؤسسات) عدّاد المقاعد الدائم أمام المدير.
              const Center(child: SeatUsageBadge()),
              const SizedBox(width: 8),
              // (دفعة 56) تنظيف كل الأجهزة المطرودة دفعة واحدة.
              IconButton(
                tooltip: 'تنظيف الأجهزة المطرودة',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _purgeAllExpelled(context),
              ),
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

  /// (دفعة 56) «تنظيف الأجهزة المطرودة»: حذف نهائي لكل البطاقات
  /// المطرودة دفعة واحدة — محلياً وسحابياً.
  Future<void> _purgeAllExpelled(BuildContext context) async {
    Sfx.click();
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    List<String> ids;
    try {
      ids = await repo.expelledDeviceIds();
    } catch (e) {
      if (context.mounted) showSnack(context, 'تعذّر: $e', error: true);
      return;
    }
    if (!context.mounted) return;
    if (ids.isEmpty) {
      showSnack(context, 'لا توجد أجهزة مطرودة في السجل.');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'تنظيف الأجهزة المطرودة',
      message: 'سيُحذف ${ids.length} جهاز مطرود نهائياً من السجل '
          'ومن السحابة. لا يمكن التراجع.',
      confirmText: 'حذف الكل نهائياً',
      danger: true,
    );
    if (ok != true) return;
    var done = 0;
    for (final id in ids) {
      try {
        await engine.purgeDeviceRecordEverywhere(id);
        done++;
      } catch (_) {}
    }
    Sfx.success();
    if (context.mounted) {
      bump(ref);
      showSnack(context, '✅ حُذف $done من ${ids.length} جهاز مطرود نهائياً.');
    }
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
                  // (دفعة 58 — متطلب 16) جهاز المدير نفسه لا يُعرض في
                  // قائمة أجهزة المجموعة — القائمة لأجهزة الأعضاء فقط.
                  for (final d in list)
                    if (d['id'] != ownId)
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
                      // (دفعة 56) حذف نهائي من السجل لبطاقة مطرودة/محظورة.
                      onPurge: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'حذف نهائي من السجل',
                          message:
                              'سيُمحى سجل "${d['name']}" نهائياً من قائمة '
                              'الأجهزة هنا ومن السحابة (roster + شواهد الطرد). '
                              'لا يمكن التراجع — إعادة ربط الجهاز لاحقاً تتم '
                              'بدعوة جديدة كأي جهاز جديد.',
                          confirmText: 'حذف نهائي',
                          danger: true,
                        );
                        if (ok != true) return;
                        try {
                          await engine.purgeDeviceRecordEverywhere(
                              d['id'] as String);
                          Sfx.success();
                          safeBump();
                        } catch (e) {
                          Sfx.error();
                          if (context.mounted) {
                            showSnack(context, 'تعذّر الحذف: $e', error: true);
                          }
                        }
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
                        // (صمام أمان) فحص جاهزية المستلم قبل التسليم —
                        // جهاز قديم/غائب يُنبَّه عنه قبل نقل الملكية.
                        final warnings = await repo
                            .transferReadinessCheck(d['id'] as String);
                        if (!context.mounted) return;
                        final warnBlock = warnings.isEmpty
                            ? ''
                            : '⚠️ تحذيرات الجاهزية:\n'
                                '${warnings.map((w) => '• $w').join('\n')}\n\n';
                        final ok = await confirmDialog(
                          context,
                          title: 'تسليم الإدارة',
                          message: '$warnBlock'
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
            // (دفعة 58) الاقتران سحابي حصرياً — أزيلت طرق LAN (QR بعنوان IP،
            // الإدخال اليدوي IP+منفذ، كود التفعيل المحلي) نهائياً.
            _HubTile(
              icon: Icons.cloud_sync_outlined,
              color: const Color(0xFF0EA5E9),
              title: 'ربط عضو عبر السحابة',
              subtitle:
                  'يُنشئ دعوة سحابية (QR + رمز PIN صالح 15 دقيقة) — يمسحها العضو أو يُدخل الرمز، وبعد موافقتك تُستبدل بياناته بنسخة المجموعة.',
              onTap: () {
                final rootContext =
                    Navigator.of(context, rootNavigator: true).context;
                Navigator.pop(context);
                Sfx.click();
                showCloudInviteDialog(rootContext, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

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

// ═══════════════ موافقة المدير على طلبات الانضمام (دفعة 51) ═══════════════

/// نافذة «طلب انضمام جهاز جديد»: اسم الجهاز + بصمته + اختيار الدور،
/// وزرا «قبول وتفعيل» / «رفض». تُستدعى تلقائياً عند رصد طلب معلّق.
Future<void> showJoinApprovalSheet(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> request, {
  required String backendUrl,
}) async {
  // (دفعة 58 — متطلب 11) طلب مغادرة عضو يمر من نفس القناة بوسم kind=leave
  // — له حوار خاص (موافقة = طرد نظيف، رفض = بقاء العضو).
  if ('${request['kind'] ?? ''}' == 'leave') {
    return showLeaveApprovalDialog(context, ref, request,
        backendUrl: backendUrl);
  }
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
                // (دفعة 56) وسم منصة نظيف بدل القيمة الخام.
                'الجهاز: ${switch (platform) {
                  'android' => 'Android',
                  'ios' => 'iPhone',
                  'windows' => 'Windows',
                  'linux' => 'Linux',
                  'macos' => 'Mac',
                  _ => 'جهاز',
                }}${fp.isEmpty ? '' : '  ·  بصمة العتاد: $fp'}',
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


/// (دفعة 58 — متطلب 11) حوار موافقة المدير على طلب مغادرة عضو:
/// الموافقة تنفّذ فك ارتباط نظيفاً كاملاً (طرد محلي + بث شاهدة سحابية
/// فيمسح جهاز العضو بيانات المجموعة ويعود مستقلاً)، والرفض يبقيه عضواً.
Future<void> showLeaveApprovalDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> request, {
  required String backendUrl,
}) async {
  final repo = ref.read(repoProvider);
  final engine = ref.read(syncEngineProvider);
  final deviceId = '${request['deviceId'] ?? ''}';
  final deviceName = '${request['deviceName'] ?? 'جهاز عضو'}';
  Sfx.notify();
  final approve = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.logout, color: Colors.orange, size: 40),
      title: const Text('طلب مغادرة المجموعة'),
      content: Text(
        'الجهاز «$deviceName» يطلب مغادرة المجموعة.\n\n'
        'الموافقة تفكّ ارتباطه نظيفاً: تُحذف بيانات المجموعة من جهازه '
        'ويعود مستقلاً، وتختفي عملياته المعلقة من متابعة المزامنة.',
        style: const TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('رفض — يبقى عضواً'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: () => Navigator.pop(ctx, true),
          icon: const Icon(Icons.check),
          label: const Text('الموافقة على المغادرة'),
        ),
      ],
    ),
  );
  // في الحالتين نحذف الطلب من السحابة (استُهلك).
  final db = await repo.database;
  final wsRows = await db.query('workspaces', limit: 1);
  final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
  try {
    await CloudJoin.deleteJoinRequest(
        backendUrl: backendUrl, workspaceId: ws, deviceId: deviceId);
  } catch (_) {}
  if (approve != true) return;
  try {
    await repo.expelDevice(deviceId);
    // بث شاهدة الإبطال — يصل العضو لحظياً عبر SSE فيفك ارتباطه بنفسه.
    await engine.broadcastEviction(deviceId, reason: 'leave_approved');
  } catch (_) {}
  if (context.mounted) {
    showSnack(context, '✅ تمت الموافقة على المغادرة وفُكّ ارتباط الجهاز.');
  }
}
