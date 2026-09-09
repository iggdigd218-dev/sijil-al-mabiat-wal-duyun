// شاشة العمليات المتزامنة: تعرض كل عملية بانتظار/قيد/فشل مزامنتها مع
// نوع العملية وحالتها، مع زر إعادة مزامنة فورية. لا يوجد "فشل نهائي":
// أي عملية تبقى قيد المحاولة التلقائية حتى تصل لكل الأجهزة.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/sync/sync_activity.dart';
import '../data/sync/sync_queue.dart';
import 'widgets.dart';

class SyncOpsScreen extends ConsumerStatefulWidget {
  const SyncOpsScreen({super.key});

  @override
  ConsumerState<SyncOpsScreen> createState() => _SyncOpsScreenState();
}

class _SyncOpsScreenState extends ConsumerState<SyncOpsScreen> {
  Timer? _ticker;
  StreamSubscription<int>? _bus;
  bool _syncing = false;

  /// وضع التحديد لحذف عمليات فاشلة/منتظرة من طابور المزامنة.
  bool _selectMode = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    _bus = SyncActivityBus.instance.stream.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bus?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(syncOpsProvider);
    ref.invalidate(syncCountsProvider);
    ref.invalidate(deviceSyncStatusProvider);
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await ref.read(syncEngineProvider).forceSyncNow();
      await Future.delayed(const Duration(milliseconds: 600));
      _refresh();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// يحذف (يلغي) العمليات المحددة من طابور المزامنة بعد تأكيد صريح.
  /// البيانات نفسها تبقى محفوظة محلياً — الإلغاء يمنع إرسالها للأجهزة فقط.
  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ok = await confirmDialog(
      context,
      title: 'حذف ${_selected.length} من طابور المزامنة',
      message: 'ستُلغى مزامنة العمليات المحددة نهائياً فلا تُرسل إلى بقية '
          'الأجهزة، وتبقى بياناتها محفوظة على هذا الجهاز فقط.\n\n'
          'هل تريد المتابعة؟',
      danger: true,
    );
    if (!ok || !mounted) return;
    final db = await ref.read(repoProvider).database;
    final n = await SyncQueueOps(db).cancelRows(_selected.toList());
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    _refresh();
    if (mounted) showSnack(context, 'أُلغيت مزامنة $n عملية 🗑️');
  }

  String _entityLabel(String t) => switch (t) {
        'tx' => 'عملية حسابية',
        'account' => 'حساب/زبون',
        'item' => 'صنف',
        'itemCategory' => 'تصنيف صنف',
        'stockMove' => 'حركة مخزون',
        'voucher' => 'سند',
        'user' => 'مستخدم/صلاحية',
        'currency' => 'عملة',
        'setting' => 'إعداد',
        'message' => 'رسالة دردشة',
        'conversation' => 'محادثة',
        'category' => 'تصنيف حسابات',
        _ => t,
      };

  String _opLabel(String t) => switch (t) {
        'create' => 'إضافة',
        'update' => 'تعديل',
        'delete_' || 'delete' => 'حذف',
        'restore' => 'استعادة',
        'settings' => 'إعداد',
        _ => t,
      };

  IconData _entityIcon(String t) => switch (t) {
        'tx' => Icons.receipt_long,
        'account' => Icons.people_alt,
        'item' => Icons.inventory_2,
        'itemCategory' => Icons.category,
        'stockMove' => Icons.swap_vert,
        'voucher' => Icons.receipt,
        'user' => Icons.verified_user,
        'currency' => Icons.currency_exchange,
        'setting' => Icons.settings,
        _ => Icons.sync,
      };

  Color _statusColor(String s, bool hasError) => switch (s) {
        'syncing' => Colors.blue,
        'synced' => Colors.green,
        'failed' => Colors.red,
        _ => hasError ? Colors.deepOrange : Colors.amber.shade700,
      };

  String _statusLabel(String s, bool hasError) {
    if (s == 'syncing') return 'قيد الإرسال الآن';
    if (s == 'synced') return 'مكتملة';
    if (s == 'failed') return 'فشلت — ستُعاد تلقائيًا';
    return hasError ? 'إعادة محاولة تلقائية' : 'بانتظار الإرسال';
  }

  String _targetLabel(String t) =>
      t == 'cloud' ? 'السحابة' : (t == 'lan' ? 'الشبكة المحلية' : t);

  String _time(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      String two(int x) => x.toString().padLeft(2, '0');
      return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final opsAsync = ref.watch(syncOpsProvider);
    final countsAsync = ref.watch(syncCountsProvider);
    final counts = countsAsync.valueOrNull ?? const {};
    final pending = counts['pending'] ?? 0;
    final withError = counts['withError'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode
            ? 'المحدد: ${_selected.length}'
            : 'العمليات المتزامنة'),
        actions: [
          if (_selectMode) ...[
            IconButton(
              tooltip: 'حذف المحدد من الطابور',
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              color: Colors.red,
            ),
            IconButton(
              tooltip: 'إلغاء التحديد',
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            IconButton(
              tooltip: 'تحديد للحذف',
              onPressed: () => setState(() => _selectMode = true),
              icon: const Icon(Icons.checklist),
            ),
            IconButton(
              tooltip: 'تحديث',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _syncNow,
        child: opsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: 'تعذّر القراءة',
            message: '$e',
          ),
          data: (ops) {
            // اعرض فقط غير المكتملة (بانتظار/قيد الإرسال/إعادة محاولة).
            final active =
                ops.where((o) => o.status != 'synced').toList();
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _Summary(
                  pending: pending,
                  withError: withError,
                  syncing: _syncing,
                  onSync: _syncNow,
                ),
                const SizedBox(height: 12),
                // أجهزة المجموعة: المتزامنة بالكامل ✅ وغير المكتملة.
                Consumer(
                  builder: (ctx, rref, _) {
                    final devs =
                        rref.watch(deviceSyncStatusProvider).valueOrNull ??
                            const <DeviceSyncStatus>[];
                    if (devs.isEmpty) return const SizedBox.shrink();
                    final done = devs.where((d) => d.fullySynced).length;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.devices_other, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  'أجهزة المجموعة ($done/${devs.length} متزامنة بالكامل)',
                                  style: Theme.of(ctx).textTheme.titleSmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            for (final d in devs) _DeviceSyncTile(d: d),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                if (active.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: EmptyState(
                      icon: Icons.cloud_done,
                      title: 'كل العمليات متزامنة',
                      message:
                          'لا توجد عمليات معلّقة. أي عملية جديدة تُزامَن فورًا '
                          'مع كل الأجهزة، وإن فشل الإرسال تبقى قيد المحاولة '
                          'التلقائية حتى تنجح.',
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'عمليات قيد المزامنة (${active.length})',
                      style:
                          Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final o in active) _OpCard(
                    o: o,
                    entityLabel: _entityLabel(o.entityType),
                    opLabel: _opLabel(o.opType),
                    icon: _entityIcon(o.entityType),
                    statusColor: _statusColor(o.status, o.lastError.isNotEmpty),
                    statusLabel:
                        _statusLabel(o.status, o.lastError.isNotEmpty),
                    targetLabel: _targetLabel(o.target),
                    time: _time(o.updatedAt),
                    selectMode: _selectMode,
                    selected: _selected.contains(o.queueId),
                    onSelectToggle: (v) => setState(() {
                      if (v) {
                        _selected.add(o.queueId);
                      } else {
                        _selected.remove(o.queueId);
                      }
                    }),
                    onLongPress: () => setState(() {
                      _selectMode = true;
                      _selected.add(o.queueId);
                    }),
                    onRetry: () async {
                      await ref.read(syncEngineProvider).forceSyncNow();
                      _refresh();
                    },
                  ),
                  const SizedBox(height: 8),
                  Card(
                    color: Colors.teal.withValues(alpha: 0.08),
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.shield_outlined,
                              color: Colors.teal, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'لا مجال لفقدان أي عملية: تبقى محفوظة على هذا '
                              'الجهاز وتُعاد محاولتها تلقائيًا كل ثوانٍ حتى تصل '
                              'إلى كل الأجهزة المرتبطة.',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final int pending;
  final int withError;
  final bool syncing;
  final VoidCallback onSync;
  const _Summary({
    required this.pending,
    required this.withError,
    required this.syncing,
    required this.onSync,
  });

  @override
  Widget build(BuildContext context) {
    final allClear = pending == 0 && withError == 0;
    final color = allClear
        ? Colors.green
        : (withError > 0 ? Colors.deepOrange : Colors.amber.shade700);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                allClear
                    ? Icons.cloud_done
                    : (syncing ? Icons.sync : Icons.cloud_sync),
                color: color,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    allClear ? 'كل شيء متزامن' : 'تجري المزامنة الآن',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    allClear
                        ? 'لا توجد عمليات معلّقة'
                        : 'عمليات معلّقة: $pending'
                            '${withError > 0 ? ' — إعادة محاولة: $withError' : ''}',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: syncing ? null : onSync,
              icon: syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: const Text('مزامنة الآن'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpCard extends StatelessWidget {
  final SyncOpRow o;
  final String entityLabel;
  final String opLabel;
  final IconData icon;
  final Color statusColor;
  final String statusLabel;
  final String targetLabel;
  final String time;
  final VoidCallback onRetry;
  final bool selectMode;
  final bool selected;
  final ValueChanged<bool> onSelectToggle;
  final VoidCallback onLongPress;
  const _OpCard({
    required this.o,
    required this.entityLabel,
    required this.opLabel,
    required this.icon,
    required this.statusColor,
    required this.statusLabel,
    required this.targetLabel,
    required this.time,
    required this.onRetry,
    required this.selectMode,
    required this.selected,
    required this.onSelectToggle,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: selected
          ? Colors.red.withValues(alpha: 0.06)
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: onLongPress,
        onTap: selectMode ? () => onSelectToggle(!selected) : null,
        child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            if (selectMode) ...[
              Checkbox(
                value: selected,
                onChanged: (v) => onSelectToggle(v ?? false),
              ),
              const SizedBox(width: 2),
            ],
            CircleAvatar(
              radius: 20,
              backgroundColor: statusColor.withValues(alpha: 0.12),
              child: Icon(icon, size: 20, color: statusColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$opLabel — $entityLabel',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                      // شارة التسليم: ✅ عند الوصول لكل الأجهزة، وإلا عداد N/M.
                      if (o.totalPeers > 0)
                        o.deliveredToAll
                            ? const Icon(Icons.check_circle,
                                size: 18, color: Colors.green)
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${o.deliveredCount}/${o.totalPeers}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.blue,
                                  ),
                                ),
                              ),
                    ],
                  ),
                  if (o.summary.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      o.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey[700]),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      _Chip(
                        label: statusLabel,
                        color: statusColor,
                        icon: o.status == 'syncing'
                            ? Icons.sync
                            : Icons.circle,
                        smallIcon: o.status != 'syncing',
                      ),
                      Text('إلى: $targetLabel',
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.grey[600])),
                      if (o.attempts > 1)
                        Text('محاولات: ${o.attempts}',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey[600])),
                      if (time.isNotEmpty)
                        Text(time,
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey[600])),
                    ],
                  ),
                  if (o.lastError.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      o.lastError,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.red.shade700),
                    ),
                  ],
                ],
              ),
            ),
            if (!selectMode)
              IconButton(
                tooltip: 'إعادة المحاولة الآن',
                onPressed: onRetry,
                icon: const Icon(Icons.send),
                color: statusColor,
              ),
          ],
        ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final bool smallIcon;
  const _Chip({
    required this.label,
    required this.color,
    required this.icon,
    this.smallIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: smallIcon ? 8 : 13, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  color: color,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// صف جهاز في قسم أجهزة المجموعة: اسم + حالة اتصال + اكتمال المزامنة.
class _DeviceSyncTile extends StatelessWidget {
  final DeviceSyncStatus d;
  const _DeviceSyncTile({required this.d});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: d.online ? Colors.green : Colors.grey,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    d.name,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (d.isOwner) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.security, size: 12, color: Colors.amber),
                ],
              ],
            ),
          ),
          if (d.fullySynced)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 15, color: Colors.green),
                SizedBox(width: 4),
                Text('متزامن بالكامل',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.green,
                        fontWeight: FontWeight.w700)),
              ],
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.hourglass_bottom,
                    size: 14, color: Colors.orange),
                const SizedBox(width: 4),
                Text('بانتظار ${d.missingOps} عملية',
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                        fontWeight: FontWeight.w700)),
              ],
            ),
        ],
      ),
    );
  }
}
