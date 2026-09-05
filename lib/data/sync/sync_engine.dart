// محرك المزامنة الخلفية.
//   - معالجة الصفوف PENDING من sync_queue.
//   - استدعاء transports المسجلة (Cloud/LAN).
//   - إعادة المحاولة مع backoff.
//   - سحب العمليات من الـ Cloud تلقائيًا عند التهيئة.
import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../core/database.dart';
import '../repository.dart';
import 'cloud_firebase_transport.dart';
import 'conflict_resolver.dart';
import 'device_id.dart';
import 'lan_http_transport.dart';
import 'operation.dart';
import 'recorder.dart';
import 'sync_queue.dart';
import 'workspace_service.dart';

abstract class SyncTransport {
  String get targetId; // 'cloud' or 'device:xxx'
  Future<void> push(SyncOperation op);
}

class SyncEngine {
  final Repo repo;
  final Future<Database> Function() dbProvider;
  final List<SyncTransport> _transports = [];
  SyncQueueOps? _queue;
  Timer? _timer;
  bool _running = false;
  bool _started = false;
  bool get hasStarted => _started;
  String? _cloudUrl;
  String? _workspaceId;
  CloudFirebaseTransport? _cloudTransport;
  LanSyncService? _lanTransport;
  bool _lanEnabled = false;

  SyncEngine({required this.repo, required this.dbProvider});

  Future<Database> get _db async => dbProvider();

  void registerTransport(SyncTransport t) {
    if (_transports.any((x) => x.targetId == t.targetId)) return;
    _transports.add(t);
  }

  Future<void> _ensureLanTransport() async {
    final st = await repo.settings();
    final enabled = (st['lanSyncEnabled'] ?? '0') == '1';
    final port = int.tryParse(st['lanSyncPort'] ?? '') ?? kDefaultLanPort;
    final db = await _db;
    if (!enabled) {
      await _lanTransport?.stopServer();
      _transports.removeWhere((t) => t.targetId == SyncTarget.lanBroadcast);
      _lanTransport = null;
      _lanEnabled = false;
      return;
    }
    if (_lanEnabled && _lanTransport?.port == port) return;
    if (_lanTransport != null) {
      await _lanTransport!.stopServer();
      _transports.removeWhere((t) => t.targetId == SyncTarget.lanBroadcast);
    }
    final ourId = await ensureDeviceId(repo);
    // تأكد من وجود سجل هذا الجهاز في devices table مع اسم المنصة.
    final ourName = await deviceName(repo);
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('devices', where: 'id = ?', whereArgs: [ourId], limit: 1);
    if (existing.isEmpty) {
      await db.insert('devices', {
        'id': ourId,
        'workspace_id': defaultWorkspaceId,
        'name': ourName,
        'platform': Platform.operatingSystem,
        'port': port,
        'is_paired': 1,
        'auth_secret': generateLanSecret(),
        'revoked_at': '',
        'ip_address': '',
        'created_at': now,
        'updated_at': now,
      });
    }
    _lanTransport = LanSyncService(
      repo: repo,
      dbProvider: dbProvider,
      ourDeviceId: ourId,
      port: port,
    );
    await _lanTransport!.startServer();
    registerTransport(_lanTransport!);
    _lanEnabled = true;
  }

  Future<void> reconfigureAll() async {
    try { await reconfigureCloud(); } catch (_) {}
    try { await _ensureLanTransport(); } catch (_) {}
  }

  /// يُعاد تهيئة الـ Cloud transport بعد تغيير الإعدادات.
  Future<void> reconfigureCloud() async {
    try {
      _cloudUrl = null;
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      _cloudTransport = null;
      await _ensureCloudTransport();
      if (_cloudTransport != null) {
        try { await _cloudTransport!.pull(resolver: ConflictResolver()); } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _ensureCloudTransport() async {
    final st = await repo.settings();
    final url = (st['cloudBackendUrl'] ?? '').trim();
    final autoSync = (st['cloudAutoSync'] ?? '1') != '0';
    if (!autoSync || url.isEmpty) {
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      _cloudTransport = null;
      _cloudUrl = null;
      return;
    }
    if (url == _cloudUrl && _cloudTransport != null) return;
    final db = await _db;
    // Workspace الحالي.
    final wsRow = await db.query('workspaces', limit: 1);
    final wsId = wsRow.isNotEmpty ? (wsRow.first['id'] as String) : defaultWorkspaceId;
    _workspaceId = wsId;
    _cloudTransport = CloudFirebaseTransport.validated(
      repo: repo,
      dbProvider: dbProvider,
      backendUrl: url,
      workspaceId: wsId,
      idTokenProvider: () async {
        try {
          final d = await _db;
          final r = await d.query('google_auth', where: 'id = 1', limit: 1);
          if (r.isEmpty) return null;
          return r.first['id_token'] as String?;
        } catch (_) {
          return null;
        }
      },
    );
    registerTransport(_cloudTransport!);
    _cloudUrl = url;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    // ربط callback لتحفيز push فوري بعد تسجيل أي عملية جديدة.
    SyncRecorder.onOperationRecorded = notifyNewOperation;
    // أي فشل في تهيئة المزامنة (سواء سحابة أو شبكة محلية) لا يجب أن يمنع
    // التطبيق من الإقلاع أو تعطيل الحفظ المحلي — محلي أولًا دائماً.
    try { await _ensureCloudTransport(); } catch (_) {}
    try { await _ensureLanTransport(); } catch (_) {}
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => processQueue());
    Future(() async {
      try {
        await _ensureCloudTransport();
        if (_cloudTransport != null) {
          await _cloudTransport!.pull(resolver: ConflictResolver());
        }
      } catch (_) {}
      await processQueue();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  /// يُستدعى من UI عند طلب "مزامنة الآن".
  Future<void> forceSyncNow() => processQueue();

  /// جدولة push فورية (لا تنتظر دورة الـ Timer) — لتسريع Near-Real-Time.
  Timer? _immediate;
  void notifyNewOperation() {
    if (!_started) return;
    _immediate?.cancel();
    // Debounce بسيط: 200ms لتجميع العمليات السريعة.
    _immediate = Timer(const Duration(milliseconds: 200), () {
      processQueue();
    });
  }

  Future<SyncSummary> summary() async {
    final q = _queue ?? SyncQueueOps(await _db);
    final pending = await q.countPending();
    final failed = await q.countFailed();
    return SyncSummary(pending: pending, failed: failed);
  }

  Future<void> processQueue() async {
    if (_running) return;
    _running = true;
    try {
      final db = await _db;
      final q = _queue ?? SyncQueueOps(db);
      for (final t in _transports) {
        final rows = await q.pickPending(limit: 20, target: t.targetId);
        for (final r in rows) {
          final qid = r['id'] as int;
          final opId = r['operation_id'] as String;
          await q.markSyncing(qid);
          try {
            final opRows = await db.query('operations',
                where: 'id = ?', whereArgs: [opId], limit: 1);
            if (opRows.isEmpty) {
              await q.markSynced(qid);
              continue;
            }
            final op = SyncOperation.fromMap(opRows.first);
            await t.push(op);
            await q.markSynced(qid);
          } catch (e) {
            await q.markFailed(qid, e);
          }
        }
      }
    } finally {
      _running = false;
    }
  }
}

class SyncSummary {
  final int pending;
  final int failed;
  const SyncSummary({required this.pending, required this.failed});
}
