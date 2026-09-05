// خدمة الاستعلام عن حالة المزامنة (تُستخدم في UI لعرض المؤشر).
import '../repository.dart';
import 'operation.dart';
import 'sync_engine.dart';
import 'sync_queue.dart';

enum SyncState {
  synced,       // 🟢 لا توجد عمليات معلقة
  syncing,      // 🟡 توجد عملية في حالة syncing
  pending,      // 🟠 توجد عمليات في الانتظار
  failed,       // 🔴 توجد عمليات فشلت بعد عدة محاولات
  offline,      // ⚪ غير مُهيّأ للعمل
}

class SyncStatusInfo {
  final SyncState state;
  final int pending;
  final int failed;
  final String? lastSyncAt;
  final String? cloudUrl;
  final bool cloudConfigured;
  final bool lanConfigured;
  final String? error;

  const SyncStatusInfo({
    required this.state,
    required this.pending,
    required this.failed,
    this.lastSyncAt,
    this.cloudUrl,
    required this.cloudConfigured,
    required this.lanConfigured,
    this.error,
  });
}

class SyncService {
  final Repo repo;
  final SyncEngine engine;
  SyncService({required this.repo, required this.engine});

  Future<SyncStatusInfo> status() async {
    final db = await repo.database;
    final q = SyncQueueOps(db);
    final pending = await q.countPending();
    final failed = await q.countFailed();
    final s = await db.rawQuery(
        "SELECT COUNT(*) c FROM sync_queue WHERE status = ?",
        [SyncStatus.syncing.name]);
    final syncing = (s.first['c'] as int?) ?? 0;
    final st = await repo.settings();
    final lastCloud = st['lastCloudSync'];
    final lastLan = st['lastLanSync'];
    final lastSync = (lastCloud?.isNotEmpty == true && (lastLan == null || lastCloud!.compareTo(lastLan) > 0))
        ? lastCloud : (lastLan?.isNotEmpty == true ? lastLan : lastCloud);
    final cloudUrl = (st['cloudBackendUrl'] ?? '').trim();
    final cloudConfigured = cloudUrl.isNotEmpty && (st['cloudAutoSync'] ?? '1') != '0';
    final lanConfigured = (st['lanSyncEnabled'] ?? '0') == '1';

    SyncState state;
    if (!cloudConfigured && !lanConfigured && pending == 0 && failed == 0) {
      state = SyncState.offline;
    } else if (failed > 0) {
      state = SyncState.failed;
    } else if (syncing > 0) {
      state = SyncState.syncing;
    } else if (pending > 0) {
      state = SyncState.pending;
    } else {
      state = SyncState.synced;
    }

    return SyncStatusInfo(
      state: state,
      pending: pending,
      failed: failed,
      lastSyncAt: (lastSync?.isNotEmpty == true) ? lastSync : null,
      cloudUrl: cloudConfigured ? cloudUrl : null,
      cloudConfigured: cloudConfigured,
      lanConfigured: lanConfigured,
    );
  }
}
