import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_version.dart';
import '../core/receipt_image.dart';
import '../core/security.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'update_section.dart';
import 'appearance_screen.dart';
import 'cloud_sync_section.dart';
import 'join_approval_flow.dart' show startJoinApprovalFlow;
import 'group_management_screen.dart';
import 'widgets.dart';

/// الإعدادات — نقل مفاتيح `settings.js` كاملة، مع حفظ صريح بزر واحد.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

/// مفاتيح المؤسسة القابلة للتحرير النصي، بالترتيب المعروض.
const _orgFields = <(String, String, IconData, TextInputType?, int)>[
  ('businessName', 'اسم المؤسسة', Icons.business_outlined, null, 1),
  ('businessNameEn', 'الاسم بالإنجليزية', Icons.translate, null, 1),
  ('address', 'العنوان', Icons.location_on_outlined, null, 2),
  ('phone', 'الهاتف', Icons.phone_outlined, TextInputType.phone, 1),
  ('whatsapp', 'واتساب', Icons.chat_outlined, TextInputType.phone, 1),
  (
    'email',
    'البريد الإلكتروني',
    Icons.email_outlined,
    TextInputType.emailAddress,
    1,
  ),
  (
    'managerName',
    'اسم المسؤول (يظهر على السندات)',
    Icons.badge_outlined,
    null,
    1,
  ),
  ('voucherFooter', 'تذييل السند', Icons.notes_outlined, null, 2),
  (
    'defaultVoucherNotes',
    'ملاحظات وشروط افتراضية في السند',
    Icons.rule_outlined,
    null,
    2,
  ),
];

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _ctrls = <String, TextEditingController>{};
  bool _dirty = false;
  bool _saving = false;
  bool _loaded = false;
  bool _bioSupported = false;
  String _bioLabel = '…';
  String _logoPath = '';
  bool _logoBusy = false;

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  /// نسخة احتياطية محلية لجهاز العضو — تُكتب في مستندات التطبيق فقط.
  Future<void> _createLocalBackup(BuildContext context) async {
    try {
      final repo = ref.read(repoProvider);
      final payload = await repo.exportForLocalBackup(withImages: true);
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final f = File('${dir.path}/nexora-local-backup-$ts.nexora');
      await f.writeAsString(jsonEncode(payload));
      if (mounted) {
        showSnack(context, '✅ حُفظت نسخة محلية: ${f.path.split('/').last}');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر إنشاء النسخة: $e', error: true);
    }
  }

  Future<void> _checkBiometrics() async {
    final ok = await Security.biometricsAvailable();
    final label = await Security.availableLabel();
    if (mounted)
      setState(() {
        _bioSupported = ok;
        _bioLabel = label;
      });
  }

  /// نملأ الحقول مرة واحدة فقط حتى لا يُمحى ما يكتبه المستخدم عند التحديث.
  void _hydrate(Map<String, String> st) {
    if (_loaded) return;
    _logoPath = st['logo'] ?? '';
    for (final f in _orgFields) {
      _ctrls[f.$1] = TextEditingController(text: st[f.$1] ?? '');
    }
    _ctrls['labelOweUs'] = TextEditingController(
      text: st['labelOweUs'] ?? 'عليه',
    );
    _ctrls['labelOweThem'] = TextEditingController(
      text: st['labelOweThem'] ?? 'له',
    );
    for (final c in _ctrls.values) {
      c.addListener(() {
        if (!_dirty && mounted) setState(() => _dirty = true);
      });
    }
    _loaded = true;
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _hasLogo =>
      _logoPath.trim().isNotEmpty && File(_logoPath).existsSync();

  Future<void> _pickLogo() async {
    setState(() => _logoBusy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
      );
      if (picked == null) return;
      final old = _logoPath;
      final path = await saveImageBytes(
        await picked.readAsBytes(),
        prefix: 'logo',
      );
      await ref.read(repoProvider).setSetting('logo', path);
      if (old.isNotEmpty && old != path) {
        try {
          final oldFile = File(old);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {
          // لا نفشل حفظ الشعار الجديد بسبب ملف قديم غير قابل للحذف.
        }
      }
      if (mounted) {
        setState(() => _logoPath = path);
        bump(ref);
        showSnack(context, 'تم حفظ شعار المؤسسة ✅');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر حفظ الشعار: $e', error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _removeLogo() async {
    if (_logoBusy) return;
    setState(() => _logoBusy = true);
    final old = _logoPath;
    try {
      await ref.read(repoProvider).setSetting('logo', '');
      if (old.isNotEmpty) {
        try {
          final oldFile = File(old);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {
          // لا نفشل حذف الإعداد بسبب ملف قديم غير قابل للحذف.
        }
      }
      if (!mounted) return;
      setState(() => _logoPath = '');
      bump(ref);
      showSnack(context, 'تم حذف شعار المؤسسة');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر حذف الشعار: $e', error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(repoProvider);
      for (final e in _ctrls.entries) {
        await repo.setSetting(e.key, e.value.text.trim());
      }
      await repo.logActivity('حفظ الإعدادات', 'settings', '');
      bump(ref);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      showSnack(context, 'تم حفظ الإعدادات ✅');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'تعذّر حفظ الإعدادات: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final currencies = ref.watch(currenciesProvider).valueOrNull ?? [];

    return settings.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('جارٍ تحميل الإعدادات…'),
            ],
          ),
        ),
      ),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EmptyState(
                icon: Icons.error_outline,
                title: 'تعذّر تحميل الإعدادات',
                message:
                    '${e.toString().length > 200 ? e.toString().substring(0, 200) + '…' : e}',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => bump(ref),
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      ),
      data: (st) {
        _hydrate(st);
        // جهاز العضو داخل مجموعة لا يعدّل بيانات المؤسسة — المجموعة حساب
        // واحد وبياناتها بيد المدير فقط، لذا نخفي القسم بالكامل.
        final wsMode =
            ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
        final wsOwner = ref.watch(isOwnerProvider).valueOrNull ?? true;
        final canEditOrg = wsMode == 'standalone' || wsOwner;
        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
              children: [
                const SectionTitle('الإعدادات'),
                const SizedBox(height: 6),
                if (canEditOrg)
                _Collapsible(
                  title: 'بيانات المؤسسة',
                  icon: Icons.business_outlined,
                  color: const Color(0xFF2563EB),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          children: [
                            for (final f in _orgFields)
                              _Field(
                                controller: _ctrls[f.$1]!,
                                label: f.$2,
                                icon: f.$3,
                                keyboard: f.$4,
                                maxLines: f.$5,
                              ),
                            const Divider(height: 24),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                'شعار المؤسسة',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            if (_hasLogo) ...[
                              const SizedBox(height: 10),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.file(
                                    File(_logoPath),
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 96,
                                      height: 96,
                                      color: AppColors.surface2Of(context),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: AppColors.text3Of(context),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _logoBusy ? null : _pickLogo,
                                    icon: _logoBusy
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.image_outlined),
                                    label: Text(
                                      _hasLogo
                                          ? 'استبدال الشعار'
                                          : 'اختيار صورة',
                                    ),
                                  ),
                                ),
                                if (_hasLogo) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'حذف الشعار',
                                    onPressed: _logoBusy ? null : _removeLogo,
                                    icon: Icon(
                                      Icons.delete_outline,
                                      color: AppColors.dangerOf(context),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _saving ? null : _saveAll,
                                icon: _saving
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.save_outlined),
                                label: Text(
                                  _saving ? 'جارٍ الحفظ…' : 'حفظ البيانات',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('المظهر والأصوات'),
                    subtitle: const Text('السمة، إخفاء الأرصدة، حجم الخط، الأصوات والاهتزاز'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AppearanceScreen()),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _Collapsible(
                  title: 'العملة والترقيم',
                  icon: Icons.currency_exchange,
                  color: const Color(0xFF0D9488),
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.currency_exchange),
                      title: const Text('العملة الافتراضية'),
                      subtitle: Text(st['defaultCurrency'] ?? 'YER'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () async {
                        final v = await showModalBottomSheet<String>(
                          context: context,
                          builder: (_) => SafeArea(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final c in currencies)
                                  ListTile(
                                    title: Text('${c.symbol}  ${c.name}'),
                                    onTap: () => Navigator.pop(context, c.code),
                                  ),
                              ],
                            ),
                          ),
                        );
                        if (v != null) {
                          await ref
                              .read(repoProvider)
                              .setSetting('defaultCurrency', v);
                          bump(ref);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _Collapsible(
                  title: 'المبيعات والسندات',
                  icon: Icons.receipt_long_outlined,
                  color: const Color(0xFF0EA5E9),
                  initiallyExpanded: true,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('نوع العملية الافتراضي'),
                      subtitle: const Text(
                        'يُختار تلقائياً عند فتح شاشة إضافة عملية',
                      ),
                      trailing: DropdownButton<String>(
                        value: st['defaultOp'] ?? 'inflow',
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(
                            value: 'inflow',
                            child: Text('قبض (مبيعة/دفعة)'),
                          ),
                          DropdownMenuItem(
                            value: 'debit',
                            child: Text('عليه (دين آجل)'),
                          ),
                          DropdownMenuItem(
                            value: 'outflow',
                            child: Text('صرف'),
                          ),
                          DropdownMenuItem(
                            value: 'credit',
                            child: Text('له (دائن)'),
                          ),
                          DropdownMenuItem(
                            value: 'revenue',
                            child: Text('إيراد'),
                          ),
                          DropdownMenuItem(
                            value: 'expense',
                            child: Text('مصروف'),
                          ),
                        ],
                        onChanged: (v) async {
                          if (v == null) return;
                          await ref
                              .read(repoProvider)
                              .setSetting('defaultOp', v);
                          bump(ref);
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.inventory_2_outlined),
                      title: const Text('تنبيه انخفاض المخزون'),
                      subtitle: const Text(
                        'تحذير عند بيع صنف وصل لحد إعادة الطلب',
                      ),
                      value: (st['warnLowStock'] ?? '1') == '1',
                      onChanged: (v) async {
                        await ref
                            .read(repoProvider)
                            .setSetting('warnLowStock', v ? '1' : '0');
                        bump(ref);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.trending_down_rounded),
                      title:
                          const Text('السماح بالبيع عند نفاد الرصيد الدفتري'),
                      subtitle: const Text(
                        'تفعيل: يسمح ببيع صنف نفد رصيده (حركة سالبة مع '
                        'تنبيه). تعطيل: نقطة البيع تمنع الإضافة عند النفاد.',
                      ),
                      value: (st['allowNegativeStock'] ?? '0') == '1',
                      onChanged: (v) async {
                        await ref
                            .read(repoProvider)
                            .setSetting('allowNegativeStock', v ? '1' : '0');
                        bump(ref);
                      },
                    ),
                    // القفل التاريخي للتدقيق: منع غير المدير من تعديل/حذف
                    // سجلات مالية أقدم من المدة المحددة (0 = معطل).
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.lock_clock_outlined),
                      title: const Text('قفل السجلات المالية القديمة'),
                      subtitle: Text(
                        (int.tryParse(st['auditLockDays'] ?? '0') ?? 0) <= 0
                            ? 'معطل — كل السجلات قابلة للتعديل حسب الصلاحيات'
                            : 'السجلات الأقدم من ${st['auditLockDays']} يوماً '
                                'مقفلة ضد التعديل والحذف لغير المدير',
                      ),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () async {
                        final v = await showQuickAmountPad(
                          context,
                          title: 'مدة القفل بالأيام (0 = تعطيل)',
                          initial: double.tryParse(
                              st['auditLockDays'] ?? '0'),
                          hint: 'مثال: 30',
                        );
                        if (v == null) return;
                        await ref.read(repoProvider).setSetting(
                            'auditLockDays', '${v.toInt().clamp(0, 3650)}');
                        bump(ref);
                      },
                    ),
                  ],
                ),
                _Collapsible(
                  title: 'الأمان والخصوصية',
                  icon: Icons.lock_outline,
                  color: const Color(0xFFE11D48),
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.fingerprint),
                      title: const Text('فتح التطبيق بالبصمة'),
                      subtitle: Text(
                        _bioSupported
                            ? 'الوسائل المتاحة: $_bioLabel'
                            : 'غير متاحة — فعّل بصمة في إعدادات الجهاز',
                      ),
                      value: _bioSupported && (st['biometric'] ?? '0') == '1',
                      onChanged: !_bioSupported
                          ? null
                          : (v) async {
                              if (v) {
                                final ok = await Security.authenticate(
                                  reason: 'أكّد بصمتك لتفعيل القفل',
                                );
                                if (!ok) {
                                  if (context.mounted) {
                                    showSnack(context, 'لم يتم التحقق');
                                  }
                                  return;
                                }
                              }
                              await ref
                                  .read(repoProvider)
                                  .setSetting('biometric', v ? '1' : '0');
                              bump(ref);
                            },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.lock_clock_outlined),
                      title: const Text('القفل عند العودة للتطبيق'),
                      subtitle: const Text('يُطلب التحقق بعد كل تصغير'),
                      value: (st['autoLock'] ?? '0') == '1',
                      onChanged: (st['biometric'] ?? '0') != '1'
                          ? null
                          : (v) async {
                              await ref
                                  .read(repoProvider)
                                  .setSetting('autoLock', v ? '1' : '0');
                              bump(ref);
                            },
                    ),
                  ],
                ),
                // مسار الترقية من الوضع المستقل: تفعيل المزامنة وربط أجهزة —
                // يفتح معالج إنشاء المجموعة (يصبح هذا الجهاز مضيفاً) دون أي
                // فقدان للبيانات المحلية القائمة.
                if (wsMode == 'standalone') ...[
                  const SizedBox(height: 18),
                  _Collapsible(
                    title: 'المزامنة وربط الأجهزة',
                    icon: Icons.hub_outlined,
                    color: const Color(0xFF7C3AED),
                    children: [
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.sync_alt_rounded,
                              color: Color(0xFF7C3AED)),
                          title: const Text(
                              'تفعيل المزامنة وربط أجهزة أخرى'),
                          subtitle: const Text(
                            'حوّل هذا الجهاز إلى مضيف مجموعة واربط أجهزة '
                            'الكاشير والمحاسبين — كل بياناتك الحالية تبقى '
                            'كما هي وتُزامَن للأجهزة الجديدة.',
                            style: TextStyle(fontSize: 11.5, height: 1.5),
                          ),
                          trailing: const Icon(Icons.chevron_left),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const GroupManagementScreen(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // المزامنة السحابية — تظهر للجميع:
                // المدير/المستقل يضبط الرابط وينشئ دعوات، والعضو يرى الحالة
                // ويستطيع إدخال الرابط يدوياً إن لم يصله من المدير.
                const SizedBox(height: 18),
                _Collapsible(
                  title: 'المزامنة السحابية (Firebase)',
                  icon: Icons.cloud_sync_outlined,
                  color: const Color(0xFF0EA5E9),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: CloudSyncSettingsSection(
                          isManager: canEditOrg,
                        ),
                      ),
                    ),
                    // جهاز مستقل (ليس عضواً): يمكنه الانضمام لمجموعة عبر السحابة.
                    if (wsMode == 'standalone')
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.group_add_outlined,
                              color: Color(0xFF7C3AED)),
                          title: const Text('الانضمام إلى مجموعة عبر السحابة'),
                          subtitle: const Text(
                            'سمِّ جهازك ثم امسح رمز QR أو أدخل رمزاً من 6 '
                            'أرقام — يُفعَّل الجهاز بعد موافقة المدير.',
                            style: TextStyle(fontSize: 11.5, height: 1.5),
                          ),
                          trailing: const Icon(Icons.chevron_left),
                          onTap: () => startJoinApprovalFlow(context, ref),
                        ),
                      ),
                  ],
                ),
                // جهاز العضو: قسم النسخ الاحتياطي محذوف من القائمة الجانبية،
                // ويظهر هنا فقط خيار إنشاء نسخة محلية (بلا Google ولا سحابة).
                if (!canEditOrg) ...[
                  const SizedBox(height: 18),
                  _Collapsible(
                    title: 'نسخة احتياطية محلية',
                    icon: Icons.save_outlined,
                    color: const Color(0xFF0D9488),
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.backup_outlined),
                        title: const Text('إنشاء نسخة احتياطية محلية الآن'),
                        subtitle: const Text(
                          'تُحفظ داخل مجلد التطبيق على هذا الجهاز فقط، '
                          'ولا يمكن استخدامها خارج مجموعتك.',
                          style: TextStyle(fontSize: 11.5, height: 1.5),
                        ),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => _createLocalBackup(context),
                      ),
                    ],
                  ),
                ],
                // تهيئة المجموعة من الصفر: على جهاز المدير (المالك) فقط —
                // لا تظهر إطلاقاً في إعدادات الأعضاء ولا الوكيل.
                if (canEditOrg) ...[
                  const SizedBox(height: 18),
                  _Collapsible(
                    title: 'منطقة الخطر — تهيئة المجموعة',
                    icon: Icons.warning_amber_rounded,
                    color: const Color(0xFFDC2626),
                    children: [_GroupWipeTile()],
                  ),
                ],
                const SizedBox(height: 18),
                const UpdateSection(),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          'مدير الحسابات',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$appVersionLabel — تطبيق أصلي بالكامل',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.text3Of(context),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'موجب (+) = مستحق لنا «عليه»  ·  سالب (−) = مستحق منا «له»',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.6,
                            color: AppColors.text3Of(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // شريط حفظ عائم يظهر فور أي تعديل غير محفوظ.
            if (_dirty)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(16),
                  color: AppColors.primaryOf(context),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _saving ? null : _saveAll,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.save_outlined, color: Colors.white),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'لديك تعديلات غير محفوظة',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            _saving ? 'جارٍ الحفظ…' : 'حفظ الآن',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// حقل نصي بسيط مربوط بمتحكّم يملكه الأب.
class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboard;

  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.maxLines = 1,
    this.keyboard,
  }) : hint = null;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboard,
          decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            prefixIcon: Icon(icon),
            isDense: true,
          ),
        ),
      );
}

/// قسم إعدادات قابل للطيّ برمز يميّزه — يقابل «الطي في أيقونات حسب النوع».
class _Collapsible extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color? color;
  final List<Widget> children;
  final bool initiallyExpanded;
  const _Collapsible({
    required this.title,
    required this.icon,
    this.color,
    required this.children,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primaryOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderOf(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          shape: const RoundedRectangleBorder(),
          collapsedShape: const RoundedRectangleBorder(),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: c, size: 22),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          children: children,
        ),
      ),
    );
  }
}

/// خيار «تهيئة المجموعة من الصفر» — جهاز المدير فقط:
/// حذف كامل لبيانات التطبيق والأعضاء (دون المساس بالإعدادات والصلاحيات)،
/// ينفَّذ بعد مصادقة النظام (بصمة/رمز قفل الشاشة)، ويُقفل شهراً بعد التنفيذ.
class _GroupWipeTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_GroupWipeTile> createState() => _GroupWipeTileState();
}

class _GroupWipeTileState extends ConsumerState<_GroupWipeTile> {
  DateTime? _lockedUntil;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLock();
  }

  Future<void> _loadLock() async {
    final at = await ref.read(repoProvider).groupWipeAvailableAt();
    if (mounted) setState(() => _lockedUntil = at);
  }

  Future<void> _wipe() async {
    // 1) تأكيد نصي واضح.
    final sure = await confirmDialog(
      context,
      title: '⚠️ تهيئة المجموعة من الصفر',
      message: 'سيُحذف كل شيء نهائياً من جهازك ومن أجهزة كل الأعضاء:\n'
          'الحسابات، العمليات، السندات، الأصناف، المخزون، الدردشة، '
          'سلة المهملات، سجل النشاط والإشعارات.\n\n'
          'تبقى المجموعة قائمة: الأجهزة المقترنة والمستخدمون والصلاحيات '
          'والإعدادات لا تُمس.\n\n'
          'بعد التنفيذ يُقفل هذا الخيار لمدة شهر كامل. لا يمكن التراجع!',
      confirmText: 'متابعة',
      danger: true,
    );
    if (!sure || !mounted) return;
    // 2) مصادقة النظام: بصمة أو رمز قفل الشاشة — إلزامية للتنفيذ.
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك لتهيئة المجموعة وحذف كل البيانات',
    );
    if (!authed) {
      if (mounted) {
        showSnack(context, 'لم تكتمل المصادقة — أُلغيت التهيئة', error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).wipeGroupData();
      // دفع فوري لعمليات الحذف نحو الأعضاء.
      try {
        ref.read(syncEngineProvider).notifyNewOperation();
      } catch (_) {}
      bump(ref);
      await _loadLock();
      if (mounted) {
        showSnack(context, 'تمت التهيئة — بدأت المجموعة من الصفر 🧹');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockedUntil != null;
    final lockLabel = locked
        ? 'مقفل حتى ${_lockedUntil!.toIso8601String().substring(0, 10)} — '
            'يُتاح مرة واحدة كل شهر'
        : 'يتطلب بصمة أو رمز قفل الشاشة للتنفيذ';
    return Card(
      child: ListTile(
        enabled: !locked && !_busy,
        leading: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                locked ? Icons.lock_clock : Icons.delete_forever,
                color: locked ? AppColors.text3Of(context) : Colors.red,
              ),
        title: Text(
          'حذف كامل البيانات وتهيئة المجموعة من الصفر',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: locked ? AppColors.text3Of(context) : Colors.red,
          ),
        ),
        subtitle: Text(
          'يفرغ دفاتر جهازك وأجهزة الأعضاء دون المساس بالإعدادات '
          'والصلاحيات.\n$lockLabel',
          style: const TextStyle(fontSize: 11.5, height: 1.5),
        ),
        onTap: locked || _busy ? null : _wipe,
      ),
    );
  }
}
