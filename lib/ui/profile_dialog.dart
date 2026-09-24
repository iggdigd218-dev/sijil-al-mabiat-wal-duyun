// نافذة الحساب الشخصي والمنشأة التفاعلية (2026-09-24).
//
// تفتح عند النقر على ترويسة الحساب الزرقاء أعلى القائمة الجانبية.
// تتيح تعديل:
//  • اسم المستخدم
//  • البريد الإلكتروني
//  • رقم الهاتف
//  • اسم المنشأة
//  • نشاط المنشأة
//  • العنوان الجغرافي
//  • رفع وتعديل الشعار
// مع زر "حفظ التعديلات" وزر صريح لـ "تسجيل الخروج".
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'logout_flow.dart';
import 'widgets.dart';

Future<void> showAccountProfileDialog(BuildContext context, WidgetRef ref) async {
  Sfx.click();
  await showDialog<void>(
    context: context,
    builder: (ctx) => const _ProfileDialog(),
  );
}

class _ProfileDialog extends ConsumerStatefulWidget {
  const _ProfileDialog();

  @override
  ConsumerState<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends ConsumerState<_ProfileDialog> {
  late final TextEditingController _userNameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _bizNameCtrl;
  late final TextEditingController _bizActivityCtrl;
  late final TextEditingController _addressCtrl;

  bool _saving = false;
  bool _logoBusy = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider).valueOrNull;
    final devName = ref.read(ownDeviceNameProvider).valueOrNull?.trim() ?? '';
    final st = ref.read(settingsProvider).valueOrNull ?? const {};

    _userNameCtrl = TextEditingController(
      text: devName.isNotEmpty ? devName : (user?.name ?? ''),
    );
    _emailCtrl = TextEditingController(
      text: (st['account.email'] ?? user?.email ?? '').trim(),
    );
    _phoneCtrl = TextEditingController(
      text: (st['phone'] ?? st['whatsapp'] ?? '').trim(),
    );
    _bizNameCtrl = TextEditingController(
      text: (st['businessName'] ?? '').trim(),
    );
    _bizActivityCtrl = TextEditingController(
      text: (st['businessActivity'] ?? '').trim(),
    );
    _addressCtrl = TextEditingController(
      text: (st['address'] ?? '').trim(),
    );
  }

  @override
  void dispose() {
    _userNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _bizNameCtrl.dispose();
    _bizActivityCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAndSetLogo() async {
    final isOwner = ref.read(isOwnerProvider).valueOrNull ?? true;
    if (!isOwner) {
      showSnack(context, 'تعديل الشعار متاح للمدير العام فقط');
      return;
    }
    setState(() => _logoBusy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 80,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final b64 = base64Encode(bytes);
      if (b64.length > 400000) {
        if (mounted) {
          showSnack(context, 'الصورة أكبر من اللازم — اختر صورة أصغر',
              error: true);
        }
        return;
      }
      final repo = ref.read(repoProvider);
      await repo.setSyncedSetting('org.icon.b64', b64);
      ref.invalidate(drawerPhotoProvider);
      bump(ref);
      Sfx.pop();
      if (mounted) {
        showSnack(context, '✅ تم تحديث الشعار بنجاح');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر رفع الشعار: $e', error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _removeLogo() async {
    final isOwner = ref.read(isOwnerProvider).valueOrNull ?? true;
    if (!isOwner) return;
    setState(() => _logoBusy = true);
    try {
      final repo = ref.read(repoProvider);
      await repo.setSyncedSetting('org.icon.b64', '');
      ref.invalidate(drawerPhotoProvider);
      bump(ref);
      Sfx.pop();
      if (mounted) showSnack(context, 'تم حذف الشعار');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر حذف الشعار: $e', error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    Sfx.tap();
    try {
      final repo = ref.read(repoProvider);
      final newName = _userNameCtrl.text.trim();
      if (newName.isNotEmpty) {
        await repo.renameSelfDevice(newName);
        try {
          await ref.read(syncEngineProvider).broadcastRosterChange();
        } catch (_) {}
      }

      await repo.setSetting('account.email', _emailCtrl.text.trim());
      await repo.setSetting('email', _emailCtrl.text.trim());
      await repo.setSetting('phone', _phoneCtrl.text.trim());
      await repo.setSetting('whatsapp', _phoneCtrl.text.trim());
      await repo.setSetting('businessName', _bizNameCtrl.text.trim());
      await repo.setSetting('businessActivity', _bizActivityCtrl.text.trim());
      await repo.setSetting('address', _addressCtrl.text.trim());

      bump(ref);
      Sfx.success();
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, 'تم حفظ التعديلات بنجاح ✅');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'تعذّر حفظ التعديلات: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = ref.watch(drawerPhotoProvider).valueOrNull ?? '';
    const fallback = Icon(Icons.person, color: Colors.white, size: 34);
    final Widget face = photo.startsWith('http')
        ? Image.network(
            photo,
            width: 72,
            height: 72,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          )
        : (photo.isNotEmpty
            ? Image.file(
                File(photo),
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              )
            : fallback);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.account_circle_outlined,
                color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 10),
          const Text('الملف الشخصي والمنشأة',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // الشعار والأيقونة
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: .28),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipOval(child: face),
                    ),
                    if (_logoBusy)
                      const Positioned.fill(
                        child: Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _logoBusy ? null : _pickAndSetLogo,
                    icon: const Icon(Icons.photo_camera_outlined, size: 17),
                    label: Text(photo.isNotEmpty ? 'تغيير الشعار' : 'رفع الشعار'),
                  ),
                  if (photo.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _logoBusy ? null : _removeLogo,
                      icon: const Icon(Icons.delete_outline,
                          size: 17, color: Colors.red),
                      label: const Text('حذف',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // الحقول
              _field(
                controller: _userNameCtrl,
                label: 'اسم المستخدم / هذا الجهاز',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _emailCtrl,
                label: 'البريد الإلكتروني',
                icon: Icons.email_outlined,
                keyboard: TextInputType.emailAddress,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _phoneCtrl,
                label: 'رقم الهاتف / واتساب',
                icon: Icons.phone_outlined,
                keyboard: TextInputType.phone,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _bizNameCtrl,
                label: 'اسم المنشأة / المتجر',
                icon: Icons.business_outlined,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _bizActivityCtrl,
                label: 'نشاط المنشأة',
                icon: Icons.storefront_outlined,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _addressCtrl,
                label: 'العنوان الجغرافي',
                icon: Icons.location_on_outlined,
                maxLines: 2,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        // زر صريح لتسجيل الخروج
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.dangerOf(context),
          ),
          onPressed: () {
            Navigator.pop(context);
            showSecuredLogout(ref);
          },
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('تسجيل الخروج',
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _saveProfile,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check, size: 18),
          label: const Text('حفظ التعديلات',
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboard,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
        ),
      ),
    );
  }
}
