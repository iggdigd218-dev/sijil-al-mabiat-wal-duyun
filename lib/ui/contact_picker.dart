import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/permission_dialog.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import 'widgets.dart';

/// جهة اتصال مبسّطة يعيدها المنتقي.
class PickedContact {
  final String name;
  final String phone;
  const PickedContact(this.name, this.phone);
}

/// يفتح نافذة صلاحيات ملونة ثم يطلب إذن جهات الاتصال ويعرض منتقي داخل التطبيق.
Future<PickedContact?> pickContact(BuildContext context) async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    showSnack(context, 'اختيار جهات الاتصال متاح على الهاتف فقط');
    return null;
  }

  // شرح ملون قبل طلب الإذن الحقيقي.
  final ok = await showPermissionRationale(context, PermissionRationale.contacts);
  if (!ok || !context.mounted) return null;

  final granted = await FlutterContacts.requestPermission(readonly: true);
  if (!context.mounted) return null;
  if (!granted) {
    Sfx.error();
    showSnack(context, 'لم يُمنح إذن الوصول إلى جهات الاتصال');
    return null;
  }

  return showModalBottomSheet<PickedContact>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ContactSheet(),
  );
}

/// يفتح تطبيق "جهات الاتصال" الخاص بالنظام مباشرة. يُستخدم عندما يضغط
/// المستخدم على أيقونة جهة الاتصال ليُضيف/يعدّل اتصالاً ثم يعود للتطبيق.
Future<void> openSystemContactsApp(BuildContext context) async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    Sfx.click();
    // لا يوجد تطبيق جهات اتصال موحد على سطح المكتب — لا تفعل شيئاً سوى رسالة.
    showSnack(context, 'تطبيق جهات الاتصال متاح على الهاتف فقط');
    return;
  }
  // uri الخاص بفتح تطبيق جهات الاتصال على أندرويد/آيفون.
  final uri = Uri.parse(
      Platform.isIOS ? 'contacts://' : 'content://contacts/people/');
  try {
    if (await canLaunchUrl(uri)) {
      Sfx.pop();
      await launchUrl(uri);
    } else {
      // بديل: افتح dialer كحل أخير.
      final dial = Uri.parse('tel:');
      if (await canLaunchUrl(dial)) {
        Sfx.pop();
        await launchUrl(dial);
      } else if (context.mounted) {
        showSnack(context, 'تعذّر فتح تطبيق جهات الاتصال');
      }
    }
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'تعذّر فتح تطبيق جهات الاتصال', error: true);
    }
  }
}

class _ContactSheet extends StatefulWidget {
  const _ContactSheet();

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  List<PickedContact> _all = const [];
  String _q = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await FlutterContacts.getContacts(withProperties: true);
      final out = <PickedContact>[];
      for (final c in raw) {
        if (c.phones.isEmpty) continue;
        final name = c.displayName.trim();
        out.add(PickedContact(
          name.isEmpty ? c.phones.first.number : name,
          c.phones.first.number.trim(),
        ));
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      if (mounted) setState(() { _all = out; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim();
    final list = q.isEmpty
        ? _all
        : _all
            .where((c) => c.name.contains(q) || c.phone.contains(q))
            .toList();

    return DraggableScrollableSheet(
      initialChildSize: .85,
      minChildSize: .5,
      maxChildSize: .95,
      expand: false,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // قبضة السحب.
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.contacts_outlined,
                      color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  Text('اختيار من جهات الاتصال',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: 'فتح تطبيق جهات الاتصال',
                    onPressed: () => openSystemContactsApp(context),
                    icon: const Icon(Icons.open_in_new),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: false,
                decoration: const InputDecoration(
                  hintText: 'ابحث بالاسم أو الرقم',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? const EmptyState(
                          icon: Icons.person_off_outlined,
                          title: 'لا توجد جهات اتصال',
                          message: 'تأكد من وجود أسماء بأرقام هواتف في جهازك',
                        )
                      : ListView.builder(
                          controller: controller,
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final c = list[i];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    AppColors.primarySoftOf(context),
                                child: Text(
                                  c.name.characters.first,
                                  style: TextStyle(
                                      color: AppColors.primaryOf(context),
                                      fontWeight: FontWeight.w800),
                                ),
                              ),
                              title: Text(c.name),
                              subtitle: Directionality(
                                textDirection: TextDirection.ltr,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(c.phone),
                                ),
                              ),
                              onTap: () {
                                Sfx.click();
                                Navigator.pop(context, c);
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
