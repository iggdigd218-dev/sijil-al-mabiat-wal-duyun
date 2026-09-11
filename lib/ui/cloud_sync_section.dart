// قسم «المزامنة السحابية» في الإعدادات + حوارات الدعوة/الانضمام عبر السحابة.
//
// - المدير: يضبط رابط فيربيس ورمز النسخ، وينشئ «دعوة سحابية» (QR + رمز)
//   لربط أعضاء بعيدين خارج الشبكة المحلية — بنفس رابط حسابه تماماً.
// - العضو: يرى حالة الاتصال السحابي (يصله رابط المدير تلقائياً عبر المزامنة)
//   ويمكنه إدخاله يدوياً إن لزم.
// - الجهاز المستقل: يمكنه الانضمام لمجموعة عبر السحابة (رابط + رمز دعوة أو
//   مسح QR) — تُحذف كل بياناته المحلية وتُستبدل بنسخة المجموعة ثم يتزامن.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sfx.dart';
import '../data/cloud_sync.dart';
import '../data/providers.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/operation.dart';
import 'widgets.dart';

/// قسم إعدادات المزامنة السحابية — يُعرض داخل شاشة الإعدادات لكل الأدوار.
class CloudSyncSettingsSection extends ConsumerStatefulWidget {
  /// true لجهاز المدير/المستقل، false لجهاز العضو.
  final bool isManager;
  const CloudSyncSettingsSection({super.key, required this.isManager});

  @override
  ConsumerState<CloudSyncSettingsSection> createState() =>
      _CloudSyncSettingsSectionState();
}

class _CloudSyncSettingsSectionState
    extends ConsumerState<CloudSyncSettingsSection> {
  final _urlCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _autoSync = true;
  bool _busy = false;
  bool _loaded = false;
  String _lastSync = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = (st['cloudBackendUrl'] ?? '').trim();
      _codeCtrl.text = (st['cloudCode'] ?? '').trim();
      _autoSync = (st['cloudAutoSync'] ?? '1') != '0';
      _lastSync = st['lastCloudSync'] ?? '';
      _loaded = true;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      try {
        await CloudSync.setBackendUrl(repo, _urlCtrl.text);
      } on ArgumentError catch (e) {
        Sfx.reject();
        if (mounted) showSnack(context, '${e.message}', error: true);
        return;
      }
      var code = _codeCtrl.text.trim();
      if (code.isEmpty && _urlCtrl.text.trim().isNotEmpty) {
        code = CloudSync.generateCode();
      }
      final clean = await CloudSync.setCode(repo, code);
      _codeCtrl.text = clean;
      await repo.setSetting('cloudAutoSync', _autoSync ? '1' : '0');

      // المدير يوزّع إعدادات السحابة لكل أجهزة المجموعة كعمليات مزامنة —
      // فيصل رابط فيربيس للأعضاء تلقائياً (عبر LAN أو السحابة نفسها).
      if (widget.isManager) {
        try {
          for (final e in {
            'cloudBackendUrl': _urlCtrl.text.trim(),
            'cloudCode': clean,
            'cloudAutoSync': _autoSync ? '1' : '0',
          }.entries) {
            await repo.queueOperation(
              entityType: EntityKind.setting,
              entityId: e.key,
              opType: OpKind.settings,
              payload: {'key': e.key, 'value': e.value},
            );
          }
        } catch (_) {}
      }

      // تفعيل فوري دون إعادة تشغيل.
      try {
        final engine = ref.read(syncEngineProvider);
        if (engine.hasStarted) await engine.reconfigureCloud();
      } catch (_) {}
      Sfx.success();
      bump(ref);
      await _load();
      if (mounted) {
        showSnack(context, '✅ تم حفظ إعدادات المزامنة السحابية وتفعيلها');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final connected = _urlCtrl.text.trim().isNotEmpty && _autoSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 18,
              color: connected ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                connected
                    ? 'المزامنة السحابية مفعّلة${_lastSync.isEmpty ? '' : ' — آخر مزامنة: $_lastSync'}'
                    : 'المزامنة السحابية غير مفعّلة بعد',
                style: TextStyle(
                  fontSize: 12,
                  color: connected ? Colors.green : Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlCtrl,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'رابط قاعدة بيانات Firebase',
            hintText: 'https://xxxx-default-rtdb.....firebasedatabase.app',
            isDense: true,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeCtrl,
                textDirection: TextDirection.ltr,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'رمز النسخة السحابية',
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.tag),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'توليد رمز جديد',
              onPressed: () =>
                  setState(() => _codeCtrl.text = CloudSync.generateCode()),
              icon: const Icon(Icons.casino_outlined),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('مزامنة تلقائية فورية عبر السحابة'),
          subtitle: const Text(
            'ترسل وتستقبل العمليات لحظياً بين كل أجهزة المجموعة عبر الإنترنت.',
            style: TextStyle(fontSize: 11.5, height: 1.5),
          ),
          value: _autoSync,
          onChanged: (v) => setState(() => _autoSync = v),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('حفظ وتفعيل'),
              ),
            ),
          ],
        ),
        if (widget.isManager) ...[
          const Divider(height: 28),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_add_alt_1_outlined,
                color: Color(0xFF7C3AED)),
            title: const Text('إنشاء دعوة انضمام عبر السحابة'),
            subtitle: const Text(
              'لربط جهاز عضو بعيد (خارج شبكة Wi-Fi): يظهر QR ورمز دعوة '
              'صالح 24 ساعة، والعضو ينضم بنفس رابط حسابك السحابي.',
              style: TextStyle(fontSize: 11.5, height: 1.5),
            ),
            trailing: const Icon(Icons.chevron_left),
            onTap: _busy ? null : () => showCloudInviteDialog(context, ref),
          ),
        ],
      ],
    );
  }
}

/// حوار «دعوة سحابية» — للمدير: يرفع لقطة المجموعة ويعرض QR + رمز الدعوة.
Future<void> showCloudInviteDialog(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(repoProvider);
  // مؤشر تقدم أثناء رفع اللقطة (قد تكون كبيرة).
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(
            child: Text('جارٍ رفع نسخة المجموعة إلى السحابة وإنشاء الدعوة...',
                style: TextStyle(height: 1.5)),
          ),
        ],
      ),
    ),
  );
  CloudInviteInfo? invite;
  String? error;
  try {
    invite = await CloudJoin.createInvite(repo);
  } catch (e) {
    error = e is CloudJoinException ? e.message : '$e';
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  if (invite == null) {
    Sfx.error();
    showSnack(context, '❌ تعذّر إنشاء الدعوة: ${error ?? 'خطأ غير معروف'}',
        error: true);
    return;
  }
  Sfx.pair();
  final inv = invite;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _CloudInviteDialog(invite: inv),
  );
}

/// حوار دعوة الاقتران (دفعة 51): QR + رمز PIN كبير من 6 أرقام
/// + عدّاد تنازلي لصلاحية 15 دقيقة.
class _CloudInviteDialog extends StatefulWidget {
  const _CloudInviteDialog({required this.invite});
  final CloudInviteInfo invite;

  @override
  State<_CloudInviteDialog> createState() => _CloudInviteDialogState();
}

class _CloudInviteDialogState extends State<_CloudInviteDialog> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final left = inv.expiresAt.difference(DateTime.now());
    final expired = left.isNegative;
    final mm = left.inMinutes.clamp(0, 99).toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');
    return AlertDialog(
      title: const Text('إضافة جهاز جديد'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: inv.qrContent,
                  size: 180,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (inv.pin.isNotEmpty) ...[
              Center(
                child: Column(
                  children: [
                    const Text('أو أدخل هذا الرمز على الجهاز الجديد:',
                        style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: SelectableText(
                        '${inv.pin.substring(0, 3)} ${inv.pin.substring(3)}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: (expired ? Colors.red : Colors.orange)
                      .withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  expired
                      ? '⛔ انتهت صلاحية الدعوة — أنشئ دعوة جديدة'
                      : '⏱ تنتهي الدعوة خلال $mm:$ss',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: expired ? Colors.red : Colors.orange.shade800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'على الجهاز الجديد: «الانضمام إلى مجموعة» ← تسمية الجهاز ← '
              'مسح الرمز أو إدخال الأرقام. سيصلك هنا طلب موافقة قبل تفعيله.',
              style: TextStyle(fontSize: 11.5, height: 1.6),
            ),
            const SizedBox(height: 8),
            _copyRow(context, 'الرابط', inv.backendUrl),
            _copyRow(context, 'رمز الدعوة', inv.token),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}

Widget _copyRow(BuildContext context, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SelectableText(
                value,
                maxLines: 2,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          IconButton(
            iconSize: 16,
            tooltip: 'نسخ',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Sfx.click();
              showSnack(context, 'تم النسخ ✅');
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
    );

/// حوار «الانضمام عبر السحابة» — للجهاز الجديد: رابط + رمز دعوة (أو من QR).
Future<void> showCloudJoinDialog(
  BuildContext context,
  WidgetRef ref, {
  String? prefillUrl,
  String? prefillToken,
  String? prefillWs,
  String? prefillCode,
}) async {
  final urlCtrl = TextEditingController(text: prefillUrl ?? '');
  final tokCtrl = TextEditingController(text: prefillToken ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('الانضمام إلى مجموعة عبر السحابة'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'أدخل رابط قاعدة البيانات ورمز الدعوة اللذين أنشأهما المدير '
            'من إعداداته (المزامنة السحابية ← دعوة انضمام).',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: urlCtrl,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'رابط قاعدة البيانات (https://...)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: tokCtrl,
            textDirection: TextDirection.ltr,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'رمز الدعوة',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('متابعة'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await performCloudJoin(
    context,
    ProviderScope.containerOf(context, listen: false),
    backendUrl: urlCtrl.text,
    token: tokCtrl.text,
    workspaceId: prefillWs ?? 'default',
    cloudCode: prefillCode ?? '',
  );
}

/// ينفّذ الانضمام السحابي الكامل: تأكيد مسح البيانات ← جلب اللقطة ←
/// استبدال البيانات ← إعادة تشغيل محرك المزامنة كعضو.
Future<void> performCloudJoin(
  BuildContext context,
  ProviderContainer container, {
  required String backendUrl,
  required String token,
  String workspaceId = 'default',
  String cloudCode = '',
}) async {
  // تأكيد صريح: الانضمام يحذف كل البيانات المحلية أولاً.
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تأكيد الانضمام إلى المجموعة'),
      content: const Text(
        'سيتم حذف جميع البيانات والسجلات المحلية في هذا الجهاز بالكامل، '
        'واستبدالها بنسخة كاملة من بيانات المجموعة من السحابة، '
        'ثم يتزامن الجهاز تلقائياً مع بقية الأجهزة.\n\n'
        'هذا الإجراء لا يمكن التراجع عنه.\n\nهل تريد المتابعة؟',
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
          child: const Text('انضمام ومسح البيانات'),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(
            child: Text('جارٍ تنزيل نسخة المجموعة من السحابة واستبدال البيانات...',
                style: TextStyle(height: 1.5)),
          ),
        ],
      ),
    ),
  );

  String? failure;
  try {
    final repo = container.read(repoProvider);
    await CloudJoin.join(
      repo,
      backendUrl: backendUrl,
      token: token,
      workspaceId: workspaceId,
      cloudCode: cloudCode,
    );
    // إعادة تشغيل محرك المزامنة بالحالة الجديدة (عضو + سحابة مفعّلة).
    final engine = container.read(syncEngineProvider);
    engine.stop();
    await engine.start();
  } catch (e) {
    failure = e is CloudJoinException ? e.message : '$e';
  }

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  if (failure != null) {
    Sfx.error();
    showSnack(context, '❌ فشل الانضمام: $failure', error: true);
    return;
  }
  Sfx.pair();
  container.read(refreshProvider.notifier).state++;
  showSnack(
    context,
    '✅ تم الانضمام إلى المجموعة عبر السحابة: حُذفت البيانات المحلية '
    'واستُبدلت بنسخة المجموعة. سيعين لك المدير الصلاحيات.',
  );
  await Future.delayed(const Duration(milliseconds: 300));
  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
}
