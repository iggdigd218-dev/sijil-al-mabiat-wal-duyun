import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'widgets.dart';

/// شاشة إدارة الأجهزة المرتبطة: عرض/ربط/إلغاء/تحديد الصلاحيات.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  Map<String, String?>? _pairInfo;
  DateTime? _pairAt;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _startPairing() async {
    // لا نستطيع قراءة WiFi IP بدون صلاحيات إضافية؛ يُترك IP فارغاً ويدخله
    // المستخدم يدوياً عند الاقتران (الرمز والمنفذ كافيان للمزامنة السحابية).
    try {
      final info = await ref
          .read(repoProvider)
          .createPairingToken();
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
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر توليد رمز الاقتران: $e', error: true);
    }
  }

  Future<void> _assign(int? userId, String deviceId) async {
    if (userId == null) return;
    try {
      await ref.read(repoProvider).assignDeviceToUser(deviceId, userId);
      bump(ref);
      if (mounted) showSnack(context, 'تم تعيين المستخدم للجهاز ✅');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر التعيين: $e', error: true);
    }
  }

  Future<void> _rename(String deviceId, String current) async {
    final ctl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('إعادة تسمية الجهاز'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم الجهاز'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await ref.read(repoProvider).renameDevice(deviceId, ctl.text);
      bump(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(devicesProvider);
    final usersAsync = ref.watch(usersProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
      children: [
        Card(
          color: AppColors.primarySoftOf(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.devices, size: 22),
                  const SizedBox(width: 8),
                  const Text('إدارة الأجهزة المرتبطة',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _startPairing,
                    icon: const Icon(Icons.add),
                    label: const Text('ربط جهاز جديد'),
                  ),
                ]),
                const SizedBox(height: 6),
                const Text(
                  'بصفتك مديراً يمكنك ربط أجهزة أخرى بهذه المساحة وتحديد صلاحيات كل جهاز (عبر تعيين مستخدم له). إلغاء الاقتران يمنع الجهاز من المزامنة فوراً.',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        if (_pairInfo != null) _pairingCard(),
        const SizedBox(height: 12),
        const SectionTitle('الأجهزة'),
        devicesAsync.when(
          loading: () =>
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: 'تعذّر تحميل الأجهزة',
            message: '$e',
          ),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.devices_other,
                title: 'لا توجد أجهزة مرتبطة',
                message: 'اضغط "ربط جهاز جديد" لإضافة أول جهاز.',
              );
            }
            return FutureBuilder<Map<String, Object?>?>(
              future: ref.read(repoProvider).ownDeviceRow(),
              builder: (ctx, snap) {
                final own = snap.data;
                final ownId = own?['id'] as String?;
                final amITheOwner = own != null && ((own['is_owner'] ?? 0) as int) == 1;
                final hostRow = list.where((r) => ((r['is_owner'] ?? 0) as int) == 1).toList();
                final hostId = hostRow.isNotEmpty ? hostRow.first['id'] as String : null;
                return Column(
                  children: [
                    for (final d in list)
                      _DeviceCard(
                        data: d,
                        users: (usersAsync.valueOrNull ?? const <AppUser>[]).cast<AppUser>(),
                        isSelf: d['id'] == ownId,
                        isOwnerDevice: d['id'] == hostId,
                        amITheOwner: amITheOwner,
                        onAssign: (uid) => _assign(uid, d['id'] as String),
                        onRename: () => _rename(d['id'] as String, (d['name'] ?? '') as String),
                        onRevoke: () async {
                          final ok = await confirmDialog(context,
                              title: 'حظر الجهاز مؤقتاً',
                              message:
                                  'سيتم منع "${d['name']}" من المزامنة حتى تُعيد السماح له. البيانات لن تُمسح ويمكن إعادة السماح في أي وقت.',
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
                              title: 'طرد الجهاز من المجموعة',
                              message:
                                  'سيتم طرد "${d['name']}" من المجموعة. عند أول اتصال للجهاز، ستُحذف جميع بيانات المجموعة منه ويعود إلى الوضع المستقل بحساب مدير جديد.\n\nلا يمكن التراجع عن ذلك إلا بإعادة ربط الجهاز من جديد.',
                              confirmText: 'تأكيد الطرد',
                              danger: true);
                          if (ok == true) {
                            await ref
                                .read(repoProvider)
                                .expelDevice(d['id'] as String);
                            bump(ref);
                            if (mounted) {
                              showSnack(context,
                                  '✅ تم طرد الجهاز من المجموعة. سيمسح بياناته عند أول اتصال.');
                            }
                          }
                        },
                        onTransferOwner: () async {
                          final targetName = d['name'] as String? ?? 'الجهاز';
                          final ok = await confirmDialog(context,
                              title: 'تسليم الإدارة لهذا الجهاز',
                              message:
                                  'سيتم نقل ملكية المجموعة إلى "$targetName".\n'
                                  'سيصبح هو المدير الوحيد، وستصبح أنت عضوًا عاديًا بدور "عرض فقط" (يمكنك اختيار دور مختلف من القائمة لاحقاً).\n\n'
                                  'لا يمكن التراجع عن هذا إلا إذا قام المالك الجديد بتسليمك الإدارة مرة أخرى.\n\n'
                                  'هل تريد المتابعة؟',
                              confirmText: 'تأكيد تسليم الإدارة',
                              danger: true);
                          if (ok == true) {
                            try {
                              await ref
                                  .read(repoProvider)
                                  .transferOwnership(d['id'] as String,
                                      newUserRoleForMe: 'viewer');
                              bump(ref);
                              if (mounted) {
                                showSnack(context,
                                    '✅ تم تسليم الإدارة. أنت الآن عضو بدور "عرض فقط".');
                                Navigator.of(context).popUntil((r) => r.isFirst);
                              }
                            } catch (e) {
                              if (mounted) {
                                showSnack(context,
                                    'تعذّر تسليم الإدارة: $e',
                                    error: true);
                              }
                            }
                          }
                        },
                      ),
                  ],
                );
              },
            );
          }
        ),
      ],
    );
  }

  Widget _pairingCard() {
    final info = _pairInfo!;
    final token = info['token'] ?? '';
    final qr = info['qr'] ?? '';
    final ipPart = _extractIp(qr);
    final portPart = _extractPort(qr);
    final secondsLeft = _pairAt == null
        ? 0
        : (300 - DateTime.now().difference(_pairAt!).inSeconds).clamp(0, 300);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: AppColors.infoSoftOf(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.qr_code_2, size: 22),
                const SizedBox(width: 8),
                const Text('رمز اقتران جديد (صالح 5 دقائق)',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const Spacer(),
                _chip('${secondsLeft}s', Icons.timer_outlined),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'إغلاق',
                  onPressed: () => setState(() {
                    _pairInfo = null;
                    _pairAt = null;
                    _tick?.cancel();
                  }),
                  icon: const Icon(Icons.close),
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'على الجهاز الآخر افتح التطبيق ← الإعدادات ← ربط بجهاز آخر، وأدخل المعلومات التالية:',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              _copyRow('رمز الاقتران', token),
              if (ipPart != null) _copyRow('عنوان IP للمضيف', ipPart),
              if (portPart != null) _copyRow('المنفذ', portPart),
              _copyRow('رابط الاقتران الكامل', qr, multiline: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _copyRow(String label, String value, {bool multiline = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment:
            multiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, height: 1.3),
            ),
          ),
          IconButton(
            iconSize: 18,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              showSnack(context, 'تم النسخ ✅');
            },
            icon: const Icon(Icons.copy),
            tooltip: 'نسخ',
          ),
        ],
      ),
    );
  }

  String? _extractIp(String qr) {
    try {
      final u = Uri.parse(qr);
      return u.queryParameters['ip'];
    } catch (_) {
      return null;
    }
  }

  String? _extractPort(String qr) {
    try {
      final u = Uri.parse(qr);
      return u.queryParameters['port'];
    } catch (_) {
      return null;
    }
  }

  Widget _chip(String label, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.primary.withOpacity(.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ]),
      );
}

class _DeviceCard extends StatelessWidget {
  final Map<String, Object?> data;
  final List<AppUser> users;
  final Future<void> Function(int? userId) onAssign;
  final VoidCallback onRename;
  final VoidCallback onRevoke;
  final VoidCallback onRestore;
  final VoidCallback onExpel;
  final VoidCallback onTransferOwner;
  final bool isSelf;
  final bool isOwnerDevice;
  final bool amITheOwner;
  const _DeviceCard({
    required this.data,
    required this.users,
    required this.onAssign,
    required this.onRename,
    required this.onRevoke,
    required this.onRestore,
    required this.onExpel,
    required this.onTransferOwner,
    required this.isSelf,
    required this.isOwnerDevice,
    required this.amITheOwner,
  });

  @override
  Widget build(BuildContext context) {
    final name = (data['name'] ?? 'جهاز') as String;
    final platform = (data['platform'] ?? '') as String;
    final expelled = ((data['expelled_at'] ?? '') as String).isNotEmpty;
    final revoked = ((data['revoked_at'] ?? '') as String).isNotEmpty && !expelled;
    final inactive = expelled || revoked;
    final lastSeen = (data['last_seen_at'] ?? '') as String;
    final userName = data['user_name'] as String?;
    final userRole = data['user_role'] as String?;
    final currentUserId = data['user_id'] as int?;
    final ip = (data['ip_address'] ?? '') as String;

    // تحديد الأجهزة الخاملة لأكثر من شهر (للتنبيه البصري).
    final lastSeenDt = DateTime.tryParse(lastSeen);
    final staleForMonth = lastSeenDt != null &&
        DateTime.now().difference(lastSeenDt) > const Duration(days: 30);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(_iconFor(platform), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                if (expelled)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withOpacity(.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('مطرود',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.red,
                            fontWeight: FontWeight.w700)),
                  )
                else if (revoked)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('محظور',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.deepOrange,
                            fontWeight: FontWeight.w700)),
                  )
                else if (staleForMonth)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('خامل ⚠️',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w700)),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('نشط',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.green,
                            fontWeight: FontWeight.w700)),
                  ),
              ]),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  _smallLabel('المنصة', platform.isEmpty ? '—' : platform),
                  _smallLabel('المستخدم', userName ?? 'غير معيّن'),
                  _smallLabel(
                      'الدور',
                      userRole == 'admin'
                          ? 'مدير'
                          : userRole == 'accountant'
                              ? 'محاسب'
                              : userRole == 'data_entry'
                                  ? 'إدخال'
                                  : userRole == 'viewer'
                                      ? 'عرض'
                                      : '—'),
                  if (ip.isNotEmpty) _smallLabel('IP', ip),
                  if (lastSeen.isNotEmpty)
                    _smallLabel(
                        'آخر ظهور',
                        DateTime.tryParse(lastSeen) == null
                            ? lastSeen
                            : Fmt.relative(DateTime.parse(lastSeen))),
                ],
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    value: currentUserId,
                    decoration: const InputDecoration(
                      labelText: 'الصلاحيات (المستخدم المرتبط)',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('— بدون صلاحيات —')),
                      ...users.map((u) => DropdownMenuItem<int?>(
                            value: u.id,
                            child: Text('${u.name} (${u.role.label})'),
                          )),
                    ],
                    onChanged: inactive ? null : onAssign,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'إعادة التسمية',
                  onPressed: isSelf || inactive ? null : onRename,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                if (expelled)
                  const SizedBox.shrink() // أجهزة مطرودة لا إجراء عليها.
                else if (revoked)
                  IconButton(
                    tooltip: 'إعادة السماح (إلغاء الحظر)',
                    onPressed: isSelf ? null : onRestore,
                    icon: const Icon(Icons.verified_user_outlined,
                        size: 20, color: Colors.green),
                  )
                else
                  IconButton(
                    tooltip: 'حظر مؤقت',
                    onPressed: isSelf ? null : onRevoke,
                    icon: const Icon(Icons.block,
                        size: 20, color: Colors.orange),
                  ),
                if (!expelled && !isSelf && !isOwnerDevice && amITheOwner)
                  IconButton(
                    tooltip: 'تسليم الإدارة (نقل الملكية) لهذا الجهاز',
                    onPressed: onTransferOwner,
                    icon: const Icon(Icons.swap_horiz,
                        size: 20, color: Colors.purple),
                  ),
                if (!expelled && !isSelf && !isOwnerDevice)
                  IconButton(
                    tooltip: 'طرد من المجموعة',
                    onPressed: onExpel,
                    icon: const Icon(Icons.person_remove,
                        size: 20, color: Colors.red),
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String p) => switch (p) {
        'android' => Icons.phone_android,
        'ios' => Icons.phone_iphone,
        'windows' => Icons.laptop_windows,
        'linux' || 'macos' => Icons.computer,
        _ => Icons.devices,
      };

  Widget _smallLabel(String k, String v) => RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 11, color: Colors.black54, height: 1.4),
          children: [
            TextSpan(
                text: '$k: ',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: v),
          ],
        ),
      );
}
