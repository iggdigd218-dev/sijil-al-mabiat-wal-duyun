// (3.71.0) مؤشرا المزامنة اللحظيان (↑↓) — تصميم عريض ومصمت.
//
// الودجت: سهمان مدمجان في الشريط العلوي بجوار جرس الإشعارات مباشرة:
//  - أخضر/أزرق عند الاتصال والاستقرار
//  - وميض خفيف أثناء النقل الفعلي
//  - أحمر صريح عند وجود خلل في الإرسال أو الاستقبال
//  - عند الضغط: يبدأ دورة تحديث فورية ويظهر رسالة واضحة بحالة المزامنة أو تفاصيل العطل (دون نوافذ منبثقة).
//  - يختفي تلقائياً في الوضع الفردي المستقل (standalone).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sfx.dart';
import '../../data/providers.dart';
import '../../data/sync/sync_diagnostics.dart';
import '../widgets.dart' show showSnack;

/// مؤشرا السهمين — يُثبَّت في الشريط العلوي بجوار الجرس.
class SyncArrowsIndicator extends ConsumerWidget {
  const SyncArrowsIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // الوضع الفردي المستقل: لا سحابة ولا مزامنة — الودجت مخفي كلياً.
    final mode = ref.watch(workspaceModeProvider).valueOrNull;
    if (mode == null || mode == 'standalone') return const SizedBox.shrink();

    return ValueListenableBuilder<SyncDiagnosticsSnapshot>(
      valueListenable: SyncDiagnostics.instance.notifier,
      builder: (context, s, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final disabled = isDark ? Colors.white38 : Colors.black38;
        final upColor = s.uploadFaulted
            ? const Color(0xFFEF4444)
            : (s.pushing || s.lastPushOk)
                ? const Color(0xFF10B981)
                : disabled;
        final downColor = s.downloadFaulted
            ? const Color(0xFFEF4444)
            : (s.pulling || s.lastPullOk)
                ? const Color(0xFF0EA5E9)
                : disabled;
        return Tooltip(
          message: 'مؤشر المزامنة اللحظية',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              Sfx.tap();
              try {
                ref.read(syncEngineProvider).forceSyncNow();
              } catch (_) {}

              final diag = SyncDiagnostics.instance.snapshot;
              if (diag.uploadFaulted ||
                  diag.downloadFaulted ||
                  diag.failedCount > 0) {
                final err = (diag.lastPushError?.isNotEmpty == true)
                    ? diag.lastPushError!
                    : (diag.lastPullError?.isNotEmpty == true)
                        ? diag.lastPullError!
                        : '';
                final String msg;
                if (err.contains('SocketException') ||
                    err.contains('Failed host lookup') ||
                    err.contains('Network') ||
                    err.contains('connect') ||
                    err.contains('ClientException')) {
                  msg = 'تعذّر الاتصال بالسحابة: يرجى التحقق من توفر الإنترنت';
                } else if (err.contains('401') ||
                    err.contains('permission') ||
                    err.contains('auth')) {
                  msg = 'تنبيه: خطأ في تصريح الجهاز أو صلاحيات المزامنة';
                } else if (diag.failedCount > 0) {
                  msg =
                      'توجد ${diag.failedCount} عملية معلقة لم تكتمل — جاري إعادة الإرسال';
                } else if (err.isNotEmpty) {
                  msg = 'عطل في المزامنة: $err';
                } else {
                  msg =
                      'تعذّرت المزامنة: يرجى التأكد من اتصال الإنترنت وإعادة المحاولة';
                }
                showSnack(context, msg, error: true);
              } else if (diag.pushing || diag.pulling) {
                showSnack(context, 'المزامنة السحابية جارية الآن...');
              } else {
                showSnack(context, 'المزامنة السحابية متصلة ومستقرة ✅');
              }
            },
            child: Container(
              width: 38,
              height: 38,
              padding: const EdgeInsets.all(4),
              child: _BoldAnimatedSyncArrows(
                upColor: upColor,
                downColor: downColor,
                upActive: s.pushing && !s.uploadFaulted,
                downActive: s.pulling && !s.downloadFaulted,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// أسهم مزامنة بارزة ومصمتة بخط عريض وبلا تباعد مفرط
class _BoldAnimatedSyncArrows extends StatefulWidget {
  final Color upColor;
  final Color downColor;
  final bool upActive;
  final bool downActive;

  const _BoldAnimatedSyncArrows({
    required this.upColor,
    required this.downColor,
    required this.upActive,
    required this.downActive,
  });

  @override
  State<_BoldAnimatedSyncArrows> createState() =>
      _BoldAnimatedSyncArrowsState();
}

class _BoldAnimatedSyncArrowsState extends State<_BoldAnimatedSyncArrows>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _evaluatePulse();
  }

  @override
  void didUpdateWidget(covariant _BoldAnimatedSyncArrows old) {
    super.didUpdateWidget(old);
    if (old.upActive != widget.upActive ||
        old.downActive != widget.downActive) {
      _evaluatePulse();
    }
  }

  void _evaluatePulse() {
    if (widget.upActive || widget.downActive) {
      if (!_pulseCtrl.isAnimating) _pulseCtrl.repeat(reverse: true);
    } else {
      if (_pulseCtrl.isAnimating) {
        _pulseCtrl.stop();
        _pulseCtrl.value = 1.0;
      }
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, _) {
        final upAlpha = widget.upActive ? _pulseAnim.value : 1.0;
        final downAlpha = widget.downActive ? _pulseAnim.value : 1.0;
        return CustomPaint(
          size: const Size(30, 30),
          painter: _BoldSyncArrowsPainter(
            upColor: widget.upColor,
            downColor: widget.downColor,
            upOpacity: upAlpha,
            downOpacity: downAlpha,
          ),
        );
      },
    );
  }
}

/// رسم الأسهم المتوازية العريضة والمقتربة
class _BoldSyncArrowsPainter extends CustomPainter {
  final Color upColor;
  final Color downColor;
  final double upOpacity;
  final double downOpacity;

  _BoldSyncArrowsPainter({
    required this.upColor,
    required this.downColor,
    required this.upOpacity,
    required this.downOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // سهم صاعد عريض ومصمت مقترب تماماً
    final upPaint = Paint()
      ..color = upColor.withValues(alpha: upOpacity)
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final upX = cx - 4.0;
    canvas.drawLine(Offset(upX, cy + 7), Offset(upX, cy - 6), upPaint);
    final upHead = Path()
      ..moveTo(upX - 4.0, cy - 2.0)
      ..lineTo(upX, cy - 6.5)
      ..lineTo(upX + 4.0, cy - 2.0);
    canvas.drawPath(upHead, upPaint);

    // سهم هابط عريض ومصمت مقترب تماماً
    final downPaint = Paint()
      ..color = downColor.withValues(alpha: downOpacity)
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final downX = cx + 4.0;
    canvas.drawLine(Offset(downX, cy - 7), Offset(downX, cy + 6), downPaint);
    final downHead = Path()
      ..moveTo(downX - 4.0, cy + 2.0)
      ..lineTo(downX, cy + 6.5)
      ..lineTo(downX + 4.0, cy + 2.0);
    canvas.drawPath(downHead, downPaint);
  }

  @override
  bool shouldRepaint(covariant _BoldSyncArrowsPainter old) =>
      old.upColor != upColor ||
      old.downColor != downColor ||
      old.upOpacity != upOpacity ||
      old.downOpacity != downOpacity;
}

/// فتح إشعار حالة المزامنة اللحظية (تم الاستغناء عن النافذة المنبثقة بطلب صريح).
Future<void> showSyncDiagnosticsSheet(BuildContext context) async {
  final diag = SyncDiagnostics.instance.snapshot;
  if (diag.uploadFaulted || diag.downloadFaulted || diag.failedCount > 0) {
    showSnack(
      context,
      'توجد مشكلة في المزامنة — يرجى التحقق من الاتصال بالإنترنت',
      error: true,
    );
  } else {
    showSnack(context, 'المزامنة السحابية متصلة ومستقرة ✅');
  }
}
