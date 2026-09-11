// حوار باركود الاقتران (يُستدعى من شاشة إدارة المجموعة).
//
// (دفعة 57) هذا الملف كان يحوي قسم «المزامنة والنسخ الاحتياطي» القديم
// بواجهات IP:Port اليدوية — أُزيل بالكامل بعد اعتماد المزامنة السحابية
// (القياس الحي في CloudSyncSettingsSection). بقي هنا حوار QR فقط.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sfx.dart';

// ════════════════════════════════════════════════════════════════════
// نافذة الباركود الفعلية التي تُعرض للمستخدم عند إنشاء رمز الاقتران.
// ════════════════════════════════════════════════════════════════════
/// غلاف معلومات الاقتران (مطابق لـ PairingInfo لكن مفتوح للاستدعاء من
/// شاشات أخرى كشاشة إدارة المجموعة).
class PairingQrInfo {
  final String token;
  final String qrContent;
  final DateTime expiresAt;
  const PairingQrInfo({
    required this.token,
    required this.qrContent,
    required this.expiresAt,
  });
}

class PairingQrDialog extends StatefulWidget {
  final PairingQrInfo info;
  final int port;
  final String? ip;
  final Color primaryColor;
  const PairingQrDialog({
    super.key,
    required this.info,
    required this.port,
    required this.ip,
    required this.primaryColor,
  });

  @override
  State<PairingQrDialog> createState() => PairingQrDialogState();
}

class PairingQrDialogState extends State<PairingQrDialog> {
  Duration? _remaining;
  DateTime? _expiresAt;

  @override
  void initState() {
    super.initState();
    _expiresAt = widget.info.expiresAt;
    _tick();
  }

  void _tick() {
    if (!mounted) return;
    final rem = _expiresAt?.difference(DateTime.now());
    setState(() => _remaining = rem);
    if (rem == null || rem.isNegative) return;
    Future.delayed(const Duration(seconds: 1), _tick);
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final expired = _remaining == null || _remaining!.isNegative;
    final secondsLeft = (_remaining?.inSeconds ?? 0).clamp(0, 300);
    final progress = secondsLeft / 300.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          elevation: 12,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // عنوان.
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: widget.primaryColor.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.qr_code_2_rounded,
                        color: widget.primaryColor,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ربط جهاز جديد',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'امسح هذا الرمز بكاميرا الجهاز الآخر من داخل التطبيق',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Sfx.click();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                // الباركود على خلفية بيضاء داخل إطار ملون.
                Container(
                  width: 270,
                  height: 270,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        widget.primaryColor.withValues(alpha: .12),
                        widget.primaryColor.withValues(alpha: .04),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.primaryColor.withValues(alpha: .4),
                      width: 2,
                    ),
                  ),
                  child: QrImageView(
                    data: widget.info.qrContent,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF111111),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF111111),
                    ),
                    embeddedImageStyle: const QrEmbeddedImageStyle(
                      size: Size(40, 40),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // شريط انتهاء الصلاحية.
                if (!expired)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: Colors.black12,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        progress > .3 ? widget.primaryColor : Colors.redAccent,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  expired
                      ? 'انتهت صلاحية الرمز — اضغط "توليد رمز جديد" للمتابعة.'
                      : 'صلاحية الرمز: ${_fmtDuration(_remaining!)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: expired ? Colors.red : Colors.black54,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                // الرمز النصي ورقم المنفذ في حال تعذر المسح.
                if (widget.ip != null && widget.ip!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .04),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi, size: 16, color: Colors.black54),
                        const SizedBox(width: 6),
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: SelectableText(
                            'IP: ${widget.ip}  :  ${widget.port}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                SelectableText(
                  'رمز الاقتران: ${widget.info.token}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                // تعليمات مختصرة.
                const Text(
                  'على الجهاز الآخر: افتح إدارة المجموعة ← ربط جهاز ← "مسح QR" ثم وجّه الكاميرا نحو هذا الرمز.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.black45,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: widget.primaryColor,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Sfx.click();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.check),
                    label: const Text('تم'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
