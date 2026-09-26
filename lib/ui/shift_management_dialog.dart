import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'widgets.dart';

/// حوار التبديل السريع للمستخدم / الوردية برمز PIN (4 أرقام).
Future<void> showSwitchUserDialog(BuildContext context, WidgetRef ref) async {
  Sfx.tap();
  final repo = ref.read(repoProvider);
  final staffList = await repo.localStaffList(onlyActive: true);

  if (!context.mounted) return;

  if (staffList.isEmpty) {
    // لم يتم إنشاء موظفين بعد — توجيه المدير لإدارة الموظفين
    final isOwner = ref.read(isOwnerProvider).valueOrNull ?? true;
    final user = ref.read(currentUserProvider).valueOrNull;
    final isMasterAdmin = isOwner || user?.role == UserRole.admin;

    if (isMasterAdmin) {
      final addNow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('إعداد الورديات والموظفين'),
          content: const Text(
            'لا يوجد موظفون مسجلون على هذا الجهاز حتى الآن.\n'
            'هل تود إضافة موظف أو كاشير جديد لتمكين التبديل السريع؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لاحقاً'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('إضافة موظف'),
            ),
          ],
        ),
      );
      if (addNow == true && context.mounted) {
        await showManageStaffDialog(context, ref);
      }
    } else {
      showSnack(context, 'لا يوجد موظفون محليون مسجلون في هذا المتجر');
    }
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => _SwitchUserPinDialog(staffList: staffList),
  );
}

class _SwitchUserPinDialog extends ConsumerStatefulWidget {
  final List<LocalStaff> staffList;
  const _SwitchUserPinDialog({required this.staffList});

  @override
  ConsumerState<_SwitchUserPinDialog> createState() =>
      _SwitchUserPinDialogState();
}

class _SwitchUserPinDialogState extends ConsumerState<_SwitchUserPinDialog> {
  final TextEditingController _pinCtrl = TextEditingController();
  LocalStaff? _selectedStaff;
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _attemptLogin() async {
    final pin = _pinCtrl.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'أدخل رمز PIN المكون من 4 أرقام');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });

    try {
      final repo = ref.read(repoProvider);
      LocalStaff? authenticatedStaff;

      if (_selectedStaff != null) {
        if (Security.verify(pin, _selectedStaff!.pinCodeHash)) {
          authenticatedStaff = _selectedStaff;
        }
      } else {
        authenticatedStaff = await repo.authenticateStaffByPin(pin);
      }

      if (authenticatedStaff == null) {
        Sfx.reject();
        if (mounted) {
          setState(() {
            _busy = false;
            _error = 'رمز PIN غير صحيح، حاول مجدداً';
            _pinCtrl.clear();
          });
        }
        return;
      }

      // قفل الجلسة فوراً وتطبيق المستخدم الجديد
      ref.read(activeStaffProvider.notifier).state = authenticatedStaff;
      Sfx.success();

      if (mounted) {
        Navigator.pop(context);
        showSnack(
          context,
          'تم بدء وردية: ${authenticatedStaff.name} (${_roleLabel(authenticatedStaff.role)}) ✅',
        );

        // توجيه الإقلاع حسب الدور
        if (authenticatedStaff.role == 'cashier') {
          ref.read(navAppModeProvider.notifier).setMode(NavAppMode.pos);
        } else if (authenticatedStaff.role == 'inventory') {
          ref.read(navAppModeProvider.notifier).setMode(NavAppMode.pos);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'حدث خطأ: $e';
        });
      }
    }
  }

  static String _roleLabel(String role) => switch (role) {
        'cashier' => 'كاشير / مبيعات',
        'inventory' => 'إدارة المنتجات / جرد',
        'accountant' => 'محاسب',
        'admin' => 'مدير',
        _ => 'موظف',
      };

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(activeStaffProvider);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primaryOf(context).withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.switch_account_rounded,
              color: AppColors.primaryOf(context),
              size: 22,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'تبديل المستخدم والوردية',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (current != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoftOf(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.person, size: 20, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'الوردية الحالية: ${current.name} (${_roleLabel(current.role)})',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              const Text(
                'اختر الموظف أو أدخل رمز PIN المكون من 4 أرقام:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: widget.staffList.map((s) {
                  final isSelected = _selectedStaff?.id == s.id;
                  return ChoiceChip(
                    label: Text(s.name),
                    selected: isSelected,
                    onSelected: (val) {
                      setState(() {
                        _selectedStaff = val ? s : null;
                        _error = '';
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _pinCtrl,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: _selectedStaff == null ? 'رمز PIN الخاص بالموظف' : 'أدخل PIN لـ ${_selectedStaff!.name}',
                  counterText: '',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onSubmitted: (_) => _attemptLogin(),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _error,
                  style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _attemptLogin,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.login_rounded, size: 18),
          label: const Text('فتح الوردية'),
        ),
      ],
    );
  }
}

/// شاشة وحوار إدارة الموظفين والصلاحيات (محمي برمز المدير الرئيسي)
Future<void> showManageStaffDialog(BuildContext context, WidgetRef ref) async {
  Sfx.tap();
  final isOwner = ref.read(isOwnerProvider).valueOrNull ?? true;
  final user = ref.read(currentUserProvider).valueOrNull;
  final isMasterAdmin = isOwner || user?.role == UserRole.admin;

  if (!isMasterAdmin) {
    // طلب التحقق من رمز المدير الرئيسي
    final authed = await _verifyMasterPinPrompt(context, ref);
    if (!authed || !context.mounted) return;
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => const _ManageStaffDialog(),
  );
}

Future<bool> _verifyMasterPinPrompt(BuildContext context, WidgetRef ref) async {
  final ctl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('مطلوب رمز المدير الرئيسي (Master PIN)'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'رمز PIN للمدير',
          prefixIcon: Icon(Icons.admin_panel_settings_outlined),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, true),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('تحقق'),
        ),
      ],
    ),
  );

  if (ok != true) return false;
  final pin = ctl.text.trim();
  final st = await ref.read(repoProvider).settings();
  final masterPin = (st['auth.masterPin'] ?? st['auth.pin'] ?? '').trim();
  if (masterPin.isEmpty) {
    // لا رمز مدير مضبوط = افتراضي 1234 أو السماح
    return pin == '1234' || pin.isNotEmpty;
  }
  return Security.verify(pin, masterPin) || pin == masterPin;
}

class _ManageStaffDialog extends ConsumerStatefulWidget {
  const _ManageStaffDialog();

  @override
  ConsumerState<_ManageStaffDialog> createState() => _ManageStaffDialogState();
}

class _ManageStaffDialogState extends ConsumerState<_ManageStaffDialog> {
  List<LocalStaff> _staff = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ref.read(repoProvider).localStaffList(onlyActive: false);
    if (mounted) {
      setState(() {
        _staff = list;
        _loading = false;
      });
    }
  }

  Future<void> _openAddStaff({LocalStaff? edit}) async {
    final nameCtrl = TextEditingController(text: edit?.name ?? '');
    final pinCtrl = TextEditingController();
    var role = edit?.role ?? 'cashier';
    var canDiscount = edit?.canApplyDiscount ?? false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(edit == null ? 'إضافة موظف / كاشير جديد' : 'تعديل بيانات الموظف'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'اسم الموظف',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  decoration: InputDecoration(
                    labelText: edit == null ? 'رمز PIN (4 أرقام)' : 'رمز PIN جديد (اتركه فارغاً للإبقاء)',
                    prefixIcon: const Icon(Icons.pin_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(
                    labelText: 'الدور والمسؤولية',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'cashier', child: Text('كاشير (نقطة البيع)')),
                    DropdownMenuItem(value: 'inventory', child: Text('إدخال / جرد (إدارة المنتجات)')),
                    DropdownMenuItem(value: 'accountant', child: Text('محاسب (الدفاتر والسندات)')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialogState(() => role = v);
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('صلاحية تطبيق الخصم'),
                  subtitle: const Text('السماح للموظف بإدخال خصم في نقطة البيع دون إذن المشرف'),
                  value: canDiscount,
                  onChanged: (v) => setDialogState(() => canDiscount = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final pin = pinCtrl.text.trim();
                if (name.isEmpty) return;
                if (edit == null && pin.length < 4) {
                  showSnack(ctx, 'أدخل رمز PIN من 4 أرقام', error: true);
                  return;
                }
                final hash = pin.isNotEmpty ? Security.hash(pin) : (edit?.pinCodeHash ?? '');
                final staffObj = LocalStaff(
                  id: edit?.id,
                  name: name,
                  pinCodeHash: hash,
                  role: role,
                  canApplyDiscount: canDiscount,
                  isActive: edit?.isActive ?? true,
                  createdAt: edit?.createdAt ?? DateTime.now(),
                );
                await ref.read(repoProvider).saveLocalStaff(staffObj);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          const Icon(Icons.people_outline, color: AppColors.primary),
          const SizedBox(width: 8),
          const Text('إدارة الموظفين والورديات'),
          const Spacer(),
          IconButton(
            tooltip: 'إضافة موظف جديد',
            icon: const Icon(Icons.person_add_alt_1, color: AppColors.primary),
            onPressed: () => _openAddStaff(),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 440, maxWidth: 450),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _staff.isEmpty
                ? const Center(child: Text('لا يوجد موظفون مضافون بعد'))
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _staff.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final s = _staff[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: s.isActive
                              ? AppColors.primary.withValues(alpha: .15)
                              : Colors.grey.withValues(alpha: .2),
                          child: Icon(
                            s.role == 'cashier' ? Icons.point_of_sale : Icons.person,
                            color: s.isActive ? AppColors.primary : Colors.grey,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          s.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            decoration: s.isActive ? null : TextDecoration.lineThrough,
                          ),
                        ),
                        subtitle: Text(
                          '${_roleLabel(s.role)} • الخصم: ${s.canApplyDiscount ? "مسموح" : "بإذن المشرف"}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 19),
                              onPressed: () => _openAddStaff(edit: s),
                            ),
                            IconButton(
                              icon: Icon(
                                s.isActive ? Icons.block : Icons.check_circle_outline,
                                size: 19,
                                color: s.isActive ? Colors.red : Colors.green,
                              ),
                              onPressed: () async {
                                final updated = s.copyWith(isActive: !s.isActive);
                                await ref.read(repoProvider).saveLocalStaff(updated);
                                _load();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }

  static String _roleLabel(String role) => switch (role) {
        'cashier' => 'كاشير',
        'inventory' => 'إدارة المنتجات',
        'accountant' => 'محاسب',
        'admin' => 'مدير',
        _ => 'موظف',
      };
}

/// حوار إدخال PIN للمشرف / المدير لتخطي القيود (Supervisor Override) مثل منح خصم لفاتورة كاشير.
Future<LocalStaff?> showSupervisorPinDialog(
  BuildContext context,
  WidgetRef ref, {
  String reason = 'الموافقة على منح خصم لهذه الفاتورة',
}) async {
  Sfx.tap();
  return showDialog<LocalStaff?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SupervisorPinDialog(reason: reason),
  );
}

class _SupervisorPinDialog extends ConsumerStatefulWidget {
  final String reason;
  const _SupervisorPinDialog({required this.reason});

  @override
  ConsumerState<_SupervisorPinDialog> createState() => _SupervisorPinDialogState();
}

class _SupervisorPinDialogState extends ConsumerState<_SupervisorPinDialog> {
  final _pinCtrl = TextEditingController();
  String? _error;
  bool _verifying = false;

  void _onDigit(String d) {
    if (_pinCtrl.text.length < 4) {
      _pinCtrl.text += d;
      setState(() => _error = null);
      if (_pinCtrl.text.length == 4) {
        _verifyPin();
      }
    }
  }

  void _onBackspace() {
    if (_pinCtrl.text.isNotEmpty) {
      _pinCtrl.text = _pinCtrl.text.substring(0, _pinCtrl.text.length - 1);
      setState(() => _error = null);
    }
  }

  Future<void> _verifyPin() async {
    final entered = _pinCtrl.text;
    if (entered.length != 4) return;
    setState(() => _verifying = true);

    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final masterPin = st['pos.master_pin'] ?? '1234';

      // 1. التحقق من PIN المدير العام للمنشأة
      if (entered == masterPin) {
        Sfx.success();
        if (mounted) {
          Navigator.pop(
            context,
            LocalStaff(
              id: null,
              name: 'المدير العام',
              pinCodeHash: '',
              role: 'admin',
              canApplyDiscount: true,
              isActive: true,
              createdAt: DateTime.now(),
            ),
          );
        }
        return;
      }

      // 2. التحقق من حسابات الموظفين برتبة مدير/مشرف
      final staffList = await repo.localStaffList(onlyActive: true);
      for (final staff in staffList) {
        if (staff.role == 'admin') {
          final ok = await repo.authenticateStaffByPin(entered, staffId: staff.id);
          if (ok != null) {
            Sfx.success();
            if (mounted) {
              Navigator.pop(context, staff);
            }
            return;
          }
        }
      }

      // رمز خاطئ
      Sfx.reject();
      setState(() {
        _error = 'رمز PIN المشرف غير صحيح';
        _pinCtrl.clear();
        _verifying = false;
      });
    } catch (e) {
      setState(() {
        _error = 'حدث خطأ أثناء التحقق: $e';
        _pinCtrl.clear();
        _verifying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.amber.shade700.withValues(alpha: .15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.verified_user_rounded, color: Colors.amber.shade800, size: 24),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'طلب إذن المشرف',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.reason,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: dark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'أدخل رمز PIN الخاص بالمدير أو المشرف للموافقة',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: dark ? Colors.white54 : Colors.black54,
              ),
            ),
            const SizedBox(height: 16),
            // دوائر رمز PIN
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final filled = i < _pinCtrl.text.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? Colors.amber.shade700 : Colors.transparent,
                    border: Border.all(
                      color: _error != null
                          ? Colors.red
                          : (filled ? Colors.amber.shade700 : (dark ? Colors.white38 : Colors.grey)),
                      width: 2,
                    ),
                  ),
                );
              }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
            const SizedBox(height: 16),
            // لوحة أرقام PIN
            _buildKeypad(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('إلغاء'),
        ),
      ],
    );
  }

  Widget _buildKeypad() {
    return Column(
      children: [
        for (var row in [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['', '0', 'back'],
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: row.map((key) {
                if (key.isEmpty) {
                  return const SizedBox(width: 60, height: 48);
                }
                if (key == 'back') {
                  return SizedBox(
                    width: 60,
                    height: 48,
                    child: IconButton(
                      icon: const Icon(Icons.backspace_outlined),
                      onPressed: _verifying ? null : _onBackspace,
                    ),
                  );
                }
                return SizedBox(
                  width: 60,
                  height: 48,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _verifying ? null : () => _onDigit(key),
                    child: Text(
                      key,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

