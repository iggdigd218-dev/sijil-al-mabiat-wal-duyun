import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'app_notice.dart';
import 'widgets.dart';

/// معالج فتح السجل المرتبط بإشعار: (نوع الكيان، معرّفه) → هل فُتحت وجهة؟
typedef NotificationEntityOpener = Future<bool> Function(
    String entityType, String entityId);

/// يفتح مركز الإشعارات الداخلية كصحيفة سفلية.
/// [onOpenEntity] يستدعى عند الضغط على إشعار مرتبط بسجل — يتكفل بالانتقال
/// إلى الشاشة المناسبة (تُغلق الصحيفة قبل الاستدعاء).
Future<void> openNotifications(
  BuildContext context,
  WidgetRef ref, {
  NotificationEntityOpener? onOpenEntity,
}) async {
  final repo = ref.read(repoProvider);
  await repo.markAllNotificationsSeen();
  bump(ref);
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NotificationsSheet(onOpenEntity: onOpenEntity),
  );
}

class _NotificationsSheet extends ConsumerWidget {
  final NotificationEntityOpener? onOpenEntity;
  const _NotificationsSheet({this.onOpenEntity});

  /// نقرة على إشعار: إن كان مرتبطاً بسجل نغلق الصحيفة وننتقل إليه،
  /// وإلا نعرض نافذة توضيحية بمحتوى الإشعار كاملاً.
  Future<void> _onTap(
    BuildContext context,
    Map<String, Object?> n,
    String kind,
  ) async {
    final entityType = (n['entity_type'] ?? '') as String;
    final entityId = (n['entity_id'] ?? '') as String;
    if (entityType.isNotEmpty && onOpenEntity != null) {
      Navigator.pop(context); // أغلق الصحيفة أولاً ثم انتقل.
      final opened = await onOpenEntity!(entityType, entityId);
      if (opened) return;
      // نوع بلا وجهة معروفة: لا شيء آخر يمكن فعله هنا (الصحيفة أُغلقت).
      return;
    }
    // إشعار عام بلا سجل محدد: نافذة توضيحية بالتفاصيل.
    final noticeKind = switch (kind) {
      'error' => AppNoticeKind.error,
      'warning' => AppNoticeKind.warning,
      'success' => AppNoticeKind.success,
      _ => AppNoticeKind.info,
    };
    final created = DateTime.tryParse((n['created_at'] ?? '') as String);
    final body = (n['body'] ?? '') as String;
    final when = created == null ? '' : '\n\n🕓 ${Fmt.dateTime(created)}';
    await showAppNotice(
      context,
      title: (n['title'] ?? '') as String,
      message: '$body$when'.trim().isEmpty
          ? 'إشعار عام — لا يوجد سجل مرتبط به.'
          : '$body$when',
      kind: noticeKind,
      playSound: false,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(notificationsProvider);
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceOf(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderOf(context),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Row(
                  children: [
                    Icon(Icons.notifications_rounded,
                        color: AppColors.primaryOf(context)),
                    const SizedBox(width: 8),
                    const Text(
                      'الإشعارات',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyState(
                    icon: Icons.error_outline,
                    title: 'تعذّر تحميل الإشعارات',
                    message: '$e',
                  ),
                  data: (list) {
                    if (list.isEmpty) {
                      return ListView(
                        controller: scrollController,
                        children: const [
                          SizedBox(height: 60),
                          EmptyState(
                            icon: Icons.notifications_off_outlined,
                            title: 'لا توجد إشعارات',
                            message: 'ستظهر هنا تنبيهات المخزون والنسخ والمزامنة',
                          ),
                        ],
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 12),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final n = list[i];
                        final kind = (n['kind'] ?? 'info') as String;
                        final (icon, color) = switch (kind) {
                          'error' => (Icons.error_outline, AppColors.danger),
                          'warning' => (Icons.warning_amber_rounded,
                              AppColors.amber),
                          'success' => (Icons.check_circle_outline,
                              AppColors.green),
                          _ => (Icons.info_outline, AppColors.info),
                        };
                        final body = (n['body'] ?? '') as String;
                        final linked =
                            ((n['entity_type'] ?? '') as String).isNotEmpty;
                        return ListTile(
                          onTap: () => _onTap(context, n, kind),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: color),
                          ),
                          title: Text(
                            (n['title'] ?? '') as String,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 14.5),
                          ),
                          subtitle: body.isEmpty
                              ? null
                              : Text(body,
                                  style: const TextStyle(fontSize: 13)),
                          // سهم يدل على أن الإشعار يقود لسجل محدد.
                          trailing: linked
                              ? Icon(Icons.chevron_left,
                                  size: 20, color: AppColors.text3Of(context))
                              : null,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
