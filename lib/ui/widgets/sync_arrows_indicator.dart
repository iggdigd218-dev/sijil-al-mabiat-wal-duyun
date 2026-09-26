// (3.71.0) مؤشرا المزامنة اللحظيان (↑↓) + ورقة التشخيص الصريحة.
//
// الودجت: سهمان مدمجان (عرض ~15dp لكل سهم) في الشريط العلوي بجوار جرس
// الإشعارات مباشرة — أخضر/أزرق عند الصحة، وميض خفيف أثناء النقل الفعلي،
// أحمر صريح عند الخلل. قابل للنقر كلياً (InkWell) ويفتح ورقة التشخيص.
// يختفي تلقائياً في الوضع الفردي المستقل (standalone).
//
// التحديث سلس: ValueListenableBuilder محلي على ValueNotifier الخاص
// بـ SyncDiagnostics — لا إعادة بناء للشاشة ولا بطء في الواجهة.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_version.dart';
import '../../core/cloud_config.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
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
          message: 'مؤشر المزامنة اللحظية — اضغط للتشخيص',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => showSyncDiagnosticsSheet(context),
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
  State<_BoldAnimatedSyncArrows> createState() => _BoldAnimatedSyncArrowsState();
}

class _BoldAnimatedSyncArrowsState extends State<_BoldAnimatedSyncArrows>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );

  @override
  void initState() {
    super.initState();
    _checkPulse();
  }

  @override
  void didUpdateWidget(covariant _BoldAnimatedSyncArrows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.upActive != widget.upActive ||
        oldWidget.downActive != widget.downActive) {
      _checkPulse();
    }
  }

  void _checkPulse() {
    if (widget.upActive || widget.downActive) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final op = widget.upActive || widget.downActive
            ? 0.35 + 0.65 * _pulse.value
            : 1.0;
        return CustomPaint(
          size: const Size(26, 26),
          painter: _BoldSyncArrowsPainter(
            upColor: widget.upColor,
            downColor: widget.downColor,
            upOpacity: widget.upActive ? op : 1.0,
            downOpacity: widget.downActive ? op : 1.0,
          ),
        );
      },
    );
  }
}

class _BoldSyncArrowsPainter extends CustomPainter {
  final Color upColor;
  final Color downColor;
  final double upOpacity;
  final double downOpacity;

  _BoldSyncArrowsPainter({
    required this.upColor,
    required this.downColor,
    this.upOpacity = 1.0,
    this.downOpacity = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // سهم صاعد عريض ومصمت
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

/// فتح ورقة التشخيص المنبثقة.
Future<void> showSyncDiagnosticsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SyncDiagnosticsSheet(),
  );
}

class _SyncDiagnosticsSheet extends ConsumerStatefulWidget {
  const _SyncDiagnosticsSheet();

  @override
  ConsumerState<_SyncDiagnosticsSheet> createState() =>
      _SyncDiagnosticsSheetState();
}

class _SyncDiagnosticsSheetState extends ConsumerState<_SyncDiagnosticsSheet> {
  bool _retrying = false;

  Future<void> _retryNow() async {
    setState(() => _retrying = true);
    try {
      // يجبر المحرك فوراً على دورة دفع + سحب كاملة — الأسهم تتحدث لحظياً
      // عبر ValueNotifier عند نهاية كل دورة.
      await ref
          .read(syncEngineProvider)
          .forceSyncNow()
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      // النتيجة الحقيقية تظهر في البطاقتين أدناه — لا حوارات إضافية.
    }
    if (mounted) setState(() => _retrying = false);
  }

  Future<void> _copyReport() async {
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      final diag = SyncDiagnostics.instance;
      // (2026-09-22) مؤشر «كل جهاز في مساحة منفصلة» يُقرأ من الإعدادات
      // فيظهر في التقرير الفني بدل أن يبقى عطلاً صامتاً.
      diag.droppedOtherWs = int.tryParse('${st['sync.droppedOtherWs']}') ?? 0;
      diag.droppedOtherWsSample = (st['sync.droppedOtherWsSample'] ?? '') as String? ?? '';
      final report = diag.buildTechnicalReport(
        appVersion: '$kAppVersion+$kAppBuild',
        workspaceId: repo.requireWorkspaceId,
        deviceId: repo.requireDeviceId,
        backendUrl: url.isEmpty ? '(غير مهيأة)' : url,
      );
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) {
        showSnack(context, '📋 تم نسخ التقرير الفني إلى الحافظة');
      }
    } catch (_) {
      if (mounted) {
        showSnack(context, 'تعذّر نسخ التقرير', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .82),
        child: ValueListenableBuilder<SyncDiagnosticsSnapshot>(
          valueListenable: SyncDiagnostics.instance.notifier,
          builder: (context, s, _) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'تشخيص المزامنة اللحظية',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                _StateCard(
                  icon: Icons.arrow_upward_rounded,
                  title: 'الإرسال ↑ (جهازك → السحابة)',
                  color: s.uploadFaulted
                      ? AppColors.dangerOf(context)
                      : (s.pushing || s.lastPushOk)
                          ? AppColors.greenOf(context)
                          : theme.disabledColor,
                  status: s.pushing
                      ? 'نقل نشط الآن…'
                      : s.uploadFaulted
                          ? 'متعثّر — فشل إرسال'
                          : s.lastPushOk
                              ? 'سليم — آخر دفعة ناجحة'
                              : 'خامل — لم تُدفع بيانات بعد',
                  rows: [
                    if (s.lastPushAt != null)
                      ('آخر دفعة', Fmt.relative(s.lastPushAt!)),
                    ('عمليات معلقة في الطابور', '${s.pendingCount}'),
                    ('عمليات فشلت', '${s.failedCount}'),
                  ],
                ),
                const SizedBox(height: 10),
                _StateCard(
                  icon: Icons.arrow_downward_rounded,
                  title: 'الاستقبال ↓ (السحابة → جهازك)',
                  color: s.downloadFaulted
                      ? AppColors.dangerOf(context)
                      : (s.pulling || s.lastPullOk)
                          ? AppColors.infoOf(context)
                          : theme.disabledColor,
                  status: s.pulling
                      ? 'استقبال نشط الآن…'
                      : s.downloadFaulted
                          ? 'متعثّر — فشل سحب'
                          : s.lastPullOk
                              ? 'سليم — السحب الدوري يعمل'
                              : 'خامل — لم يُسحب بعد',
                  rows: [
                    if (s.lastPullAt != null)
                      ('آخر دورة سحب', Fmt.relative(s.lastPullAt!)),
                    ('عمليات طُبقت في آخر سحب', '${s.lastPullApplied}'),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'مصدر الخلل والتشخيص',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (s.stable)
                  _StableBanner()
                else ...[
                  if (s.uploadFaulted && (s.lastPushError ?? '').isNotEmpty)
                    _FaultCard(
                      fault: s.lastPushFault,
                      where: 'الإرسال ↑',
                      message: s.lastPushError!,
                      contextLine: s.lastPushCtx,
                    ),
                  if (s.downloadFaulted && (s.lastPullError ?? '').isNotEmpty)
                    _FaultCard(
                      fault: s.lastPullFault,
                      where: 'الاستقبال ↓',
                      message: s.lastPullError!,
                      contextLine: s.lastPullCtx,
                    ),
                  if ((s.uploadFaulted || s.downloadFaulted) &&
                      (s.lastPushError ?? '').isEmpty &&
                      (s.lastPullError ?? '').isEmpty)
                    _FaultCard(
                      fault: SyncFaultSource.appCode,
                      where: 'الطابور',
                      message:
                          'توجد ${s.failedCount} عملية فاشلة في الطابور بلا '
                          'استثناء مسجل — أعد المحاولة لفحصها فوراً.',
                      contextLine: '',
                    ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _retrying ? null : _retryNow,
                        icon: _retrying
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('إعادة المحاولة والفحص الآن'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyReport,
                        icon: const Icon(Icons.copy_all_rounded, size: 18),
                        label: const Text('نسخ التقرير الفني'),
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
}

/// بطاقة حالة (إرسال أو استقبال) بلونها ورمزها الحاليين.
class _StateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final String status;
  final List<(String, String)> rows;
  const _StateCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.status,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: color, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          if (rows.isNotEmpty) const SizedBox(height: 8),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(label,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor)),
                  ),
                  Text(value,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// رسالة الاستقرار الخضراء — لا أعطال إطلاقاً.
class _StableBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final green = AppColors.greenOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: green.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: green.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: green, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'الاتصال مستقر — كافة البيانات متزامنة وجاهزة. '
              'لا أعطال في الإرسال أو الاستقبال.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: green, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

/// بطاقة خلل: وسم المصدر الصريح + العنوان + الرسالة الدقيقة + السياق.
class _FaultCard extends StatelessWidget {
  final SyncFaultSource fault;
  final String where;
  final String message;
  final String contextLine;
  const _FaultCard({
    required this.fault,
    required this.where,
    required this.message,
    required this.contextLine,
  });

  Color _color(BuildContext context) => switch (fault) {
        SyncFaultSource.appCode => Colors.deepOrange,
        SyncFaultSource.cloud => AppColors.dangerOf(context),
        SyncFaultSource.network => AppColors.infoOf(context),
        SyncFaultSource.none => Theme.of(context).disabledColor,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _color(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '[المصدر: ${fault.tag}] · $where',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            fault.headline,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 4),
          SelectableText(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.5,
            ),
          ),
          if (contextLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'السياق: $contextLine',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
          ],
        ],
      ),
    );
  }
}
