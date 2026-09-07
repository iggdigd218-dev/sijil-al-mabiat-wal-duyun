import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import 'widgets.dart';

/// فتح نموذج إضافة/تعديل حساب.
Future<bool> openAccountForm(
  BuildContext context,
  WidgetRef ref, {
  Account? existing,
}) async {
  final r = await Navigator.push<bool>(
    context,
    MaterialPageRoute(builder: (_) => AccountFormScreen(existing: existing)),
  );
  return r ?? false;
}

class AccountFormScreen extends ConsumerStatefulWidget {
  final Account? existing;
  const AccountFormScreen({super.key, this.existing});

  @override
  ConsumerState<AccountFormScreen> createState() => _State();
}

class _State extends ConsumerState<AccountFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _opening;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _notes;
  late final TextEditingController _category;
  late final TextEditingController _limit;
  late final TextEditingController _tags;

  late AccountKind _kind;
  late String _currency;
  late bool _archived;

  /// قناة إرسال إشعار السند لهذا الحساب.
  late String _notifyChannel;

  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    _name = TextEditingController(text: a?.name ?? '');
    _opening = TextEditingController(
      text: a == null || a.openingBalance == 0
          ? ''
          : Fmt.money(a.openingBalance, 2),
    );
    _phone = TextEditingController(
      text: a?.whatsapp.isNotEmpty == true ? a!.whatsapp : (a?.phone ?? ''),
    );
    _address = TextEditingController(text: a?.address ?? '');
    _notes = TextEditingController(text: a?.notes ?? '');
    _category = TextEditingController(text: a?.category ?? '');
    _limit = TextEditingController(
      text: a?.creditLimit == null ? '' : Fmt.money(a!.creditLimit!, 2),
    );
    _tags = TextEditingController(text: a?.tags.join('، ') ?? '');
    _kind = a?.kind ?? AccountKind.customer;
    _currency = a?.currency ?? 'YER';
    _archived = a?.archived ?? false;
    _notifyChannel = a?.notifyChannel ?? 'whatsapp';
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _opening,
      _phone,
      _address,
      _notes,
      _category,
      _limit,
      _tags,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final rawOpening = _opening.text.trim();
      final parsedOpening = Fmt.parseAmount(rawOpening) ?? 0;
      final double finalOpening = parsedOpening;
      final limit = Fmt.parseAmount(_limit.text);
      final now = DateTime.now();

      final acc = Account(
        id: widget.existing?.id,
        name: _name.text.trim(),
        kind: _kind,
        openingBalance: finalOpening,
        currency: _currency,
        phone: Fmt.phoneDigits(_phone.text),
        whatsapp: Fmt.phoneDigits(_phone.text),
        address: _address.text.trim(),
        notes: _notes.text.trim(),
        category: widget.existing?.category ?? '',
        creditLimit: limit,
        tags: _tags.text
            .split(RegExp('[,،]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        archived: _archived,
        notifyChannel: _notifyChannel,
        createdAt: widget.existing?.createdAt ?? now,
        updatedAt: now,
      );

      await ref.read(repoProvider).saveAccount(acc);
      if (!mounted) return;
      bump(ref);
      Navigator.pop(context, true);
      showSnack(context, _isEdit ? 'تم تحديث الحساب' : 'تمت إضافة الحساب');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر الحفظ: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? get _phoneDigits {
    final d = Fmt.phoneDigits(_phone.text);
    return d.isEmpty ? null : d;
  }

  Future<void> _launch(String scheme) async {
    final num = _phoneDigits;
    if (num == null) {
      Sfx.reject();
      showSnack(context, 'أدخل رقم الهاتف أولاً', error: true);
      return;
    }
    final uri = Uri.parse('$scheme$num');
    try {
      Sfx.pop();
      await launchUrl(uri);
    } catch (_) {
      if (mounted) showSnack(context, 'تعذّر فتح التطبيق', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'تعديل حساب' : 'حساب جديد')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            100 + MediaQuery.of(context).viewInsets.bottom,
          ),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'اسم الحساب *'),
              textInputAction: TextInputAction.next,
              validator: (v) => (v ?? '').trim().isEmpty ? 'الاسم مطلوب' : null,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Text(
                    'نوع الحساب:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Wrap(
                      spacing: 5,
                      children: AccountKind.values
                          .map(
                            (k) => ChoiceChip(
                              label: Text(
                                '${k.icon} ${k.label}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 0,
                              ),
                              selected: _kind == k,
                              showCheckmark: false,
                              onSelected: (_) => setState(() => _kind = k),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            TextFormField(
              controller: _opening,
              decoration: InputDecoration(
                labelText: 'الرصيد الافتتاحي (اختياري)',
                hintText: '0.00',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) return null;
                return Fmt.parseAmount(v!) == null ? 'مبلغ غير صالح' : null;
              },
            ),
            const SizedBox(height: 13),
            DropdownButtonFormField<String>(
              initialValue:
                  curs.any((c) => c.code == _currency) ? _currency : null,
              decoration: const InputDecoration(labelText: 'العملة'),
              items: curs
                  .map(
                    (c) => DropdownMenuItem(
                      value: c.code,
                      child: Text('${c.name} (${c.symbol})'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _currency = v ?? 'YER'),
            ),
            const SizedBox(height: 13),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'رقم الجوال',
                hintText: '7xxxxxxxx',
                prefixIcon: const Icon(Icons.phone_android),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'اتصال',
                      icon: const Icon(Icons.call, color: Colors.green),
                      onPressed: () => _launch('tel:'),
                    ),
                    IconButton(
                      tooltip: 'رسالة نصية (SMS)',
                      icon: const Icon(Icons.sms, color: Colors.blue),
                      onPressed: () => _launch('sms:'),
                    ),
                    IconButton(
                      tooltip: 'واتساب',
                      icon: const Icon(Icons.chat, color: Color(0xFF25D366)),
                      onPressed: () => _launch('https://wa.me/'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 13),
            TextFormField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'العنوان'),
            ),
            const SizedBox(height: 13),
            TextFormField(
              controller: _limit,
              decoration: const InputDecoration(
                labelText: 'حد ائتماني (اختياري)',
                hintText: '0.00',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            const SizedBox(height: 13),
            TextFormField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'علامات',
                hintText: 'افصل بينها بفاصلة',
              ),
            ),
            const SizedBox(height: 13),
            TextFormField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'ملاحظات'),
              maxLines: 3,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_isEdit ? 'حفظ التعديلات' : 'إضافة الحساب'),
            ),
          ],
        ),
      ),
    );
  }
}
