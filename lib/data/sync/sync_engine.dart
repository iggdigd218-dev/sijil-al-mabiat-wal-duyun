// محرك المزامنة الخلفية.
//   - معالجة الصفوف PENDING من sync_queue.
//   - استدعاء transports المسجلة (Cloud/LAN).
//   - إعادة المحاولة مع backoff.
//   - سحب العمليات من الـ Cloud تلقائيًا عند التهيئة.
import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../repository.dart';
import 'cloud_firebase_transport.dart';
import 'cloud_join.dart';
import 'conflict_resolver.dart';
import 'device_id.dart';
import 'lan_http_transport.dart';
import 'operation.dart';
import 'presence_service.dart';
import 'recorder.dart';
import 'sync_activity.dart';
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
  Timer? _maintenanceTimer;
  Timer? _rosterTimer;
  Timer? _cloudPullTimer;
  bool _cloudPulling = false;
  int _generation = 0;
  bool _running = false;
  bool _started = false;
  bool get hasStarted => _started;

  /// خدمة الحضور: مناداة كل 3 ثوانٍ + استماع دائم عبر خادم LAN.
  PresenceService? _presence;
  PresenceService? get presence => _presence;

  /// يُستدعى عند اكتمال مزامنة عملية مهمة إلى جهاز (لإشعار المستخدم).
  /// (وصف العملية، اسم الجهاز الهدف، نوع الكيان مثل 'tx'، معرّفه المحلي)
  /// نوع الكيان ومعرّفه يسمحان بفتح السجل المقصود عند الضغط على الإشعار.
  static void Function(
    String opDescription,
    String deviceName,
    String entityType,
    String entityId,
  )? onOpDelivered;

  /// يُستدعى عند عودة جهاز للاتصال (اسمه) لإظهار إشعار "الجهاز متصل".
  static void Function(String deviceName)? onPeerJoined;

  /// يُستدعى عند اكتمال مزامنة كل العمليات المعلقة مع جهاز معيّن (اسمه).
  static void Function(String deviceName)? onDeviceSyncComplete;

  /// أجهزة استلمت عمليات مؤخراً — تُفحص بعد مهلة قصيرة لإشعار «اكتملت
  /// المزامنة مع (الجهاز)» عندما يفرغ الطابور.
  final Set<String> _recentDelivered = {};
  Timer? _completeTimer;

  /// يُستدعى أي نشاط مزامنة (وصول عملية/تغيّر صلاحيات) لتنبيه الواجهة للتحديث.
  static void Function()? onSyncActivity = SyncActivityBus.instance.ping;
  String? _cloudUrl;
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
    final existing = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [ourId],
      limit: 1,
    );
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
    _wireLanNotify(_lanTransport!);
    _wireLanDelivery(_lanTransport!);
    await _lanTransport!.startServer();
    registerTransport(_lanTransport!);
    _lanEnabled = true;
  }

  /// يربط ناقل LAN بنظام الحضور (تخطي الغائبين) وبإشعار التسليم الناجح،
  /// ويشغّل خدمة الحضور (مناداة كل 3 ثوانٍ + مزامنة فورية عند عودة قرين).
  void _wireLanDelivery(LanSyncService svc) {
    if (_presence == null || _presence!.ourDeviceId != svc.ourDeviceId) {
      _presence?.dispose();
      _presence =
          PresenceService(dbProvider: dbProvider, ourDeviceId: svc.ourDeviceId)
            ..onPeerOnline = (id, name) {
              // جهاز عاد للاتصال: دفع فوري لكل المعلّق + إشعار.
              try {
                onPeerJoined?.call(name);
              } catch (_) {}
              notifyNewOperation();
            }
            ..start();
    }
    svc.isPeerOnline = (id) => _presence?.isOnline(id) ?? true;
    svc.onDelivered = (op, deviceId, deviceName) {
      // إشعار "تمت مزامنة العملية" للعمليات المهمة فقط (مالية/مخزون/سندات).
      const important = {'tx', 'stockMove', 'voucher', 'account', 'item'};
      if (important.contains(op.entityType.name)) {
        try {
          onOpDelivered?.call(
              _describeOp(op), deviceName, op.entityType.name, op.entityId);
        } catch (_) {}
      }
      try {
        onSyncActivity?.call();
      } catch (_) {}
      // اكتمال المزامنة مع جهاز: بعد آخر تسليم بثانيتين، إن لم يبق شيء
      // معلقاً لهدف LAN نُشعر «اكتملت المزامنة مع (اسم الجهاز)».
      _recentDelivered.add(deviceName);
      _completeTimer?.cancel();
      _completeTimer = Timer(const Duration(seconds: 2), () async {
        final names = List<String>.of(_recentDelivered);
        _recentDelivered.clear();
        if (names.isEmpty || onDeviceSyncComplete == null) return;
        try {
          final db = await _db;
          final left = await db.rawQuery(
            "SELECT COUNT(*) c FROM sync_queue "
            "WHERE target = 'lan' AND status IN ('pending','syncing','failed')",
          );
          if (((left.first['c'] as int?) ?? 0) == 0) {
            for (final n in names.toSet()) {
              onDeviceSyncComplete?.call(n);
            }
          }
        } catch (_) {}
      });
    };
  }

  static String _describeOp(SyncOperation op) {
    final entity = switch (op.entityType.name) {
      'tx' => 'عملية حسابية',
      'account' => 'حساب',
      'item' => 'صنف',
      'stockMove' => 'حركة مخزون',
      'voucher' => 'سند',
      _ => op.entityType.name,
    };
    final action = switch (op.opType.name) {
      'create' => 'إضافة',
      'update' => 'تعديل',
      'delete_' => 'حذف',
      'restore' => 'استعادة',
      _ => op.opType.name,
    };
    return '$action $entity';
  }

  /// يربط إشعار الأقران الفوري: عند وصول إشعار من نظير نسحب الـ roster ونعالج
  /// الطابور فورًا (فرض الصلاحيات/العمليات خلال ثوانٍ لا انتظار الدورية).
  void _wireLanNotify(LanSyncService svc) {
    svc.onPeerNotify = () {
      try {
        onSyncActivity?.call();
      } catch (_) {}
      Future(() async {
        try {
          final changed = await svc.reconcileRoster();
          if (changed == true) await processQueue();
        } catch (_) {}
        try {
          await processQueue();
        } catch (_) {}
      });
    };
  }

  Future<void> reconfigureAll() async {
    try {
      await reconfigureCloud();
    } catch (_) {}
    try {
      await _ensureLanTransport();
    } catch (_) {}
  }

  /// يضمن تشغيل خادم LAN على [port] ويُعيد ما إذا كان يستمع فعلًا.
  /// تُستخدم قبل إنشاء رمز الاقتران حتى لا يُعلَن منفذ لا يستمع عليه خادم.
  Future<bool> ensureLanHost(int port) async {
    try {
      await repo.setSetting('lanSyncEnabled', '1');
      await repo.setSetting('lanSyncPort', '$port');
      if (_lanEnabled && _lanTransport?.isRunning == true &&
          _lanTransport?.port == port) {
        return true;
      }
      await _lanTransport?.stopServer();
      _transports.removeWhere((t) => t.targetId == SyncTarget.lanBroadcast);
      final ourId = await ensureDeviceId(repo);
      final svc = LanSyncService(
        repo: repo,
        dbProvider: dbProvider,
        ourDeviceId: ourId,
        port: port,
      );
      _wireLanNotify(svc);
      _wireLanDelivery(svc);
      await svc.startServer();
      if (!svc.isRunning) return false;
      _lanTransport = svc;
      registerTransport(svc);
      _lanEnabled = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// يُعاد تهيئة الـ Cloud transport بعد تغيير الإعدادات.
  Future<void> reconfigureCloud() async {
    try {
      _cloudUrl = null;
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      await _cloudTransport?.stopListening();
      _cloudTransport = null;
      await _ensureCloudTransport();
      if (_cloudTransport != null) {
        try {
          await _cloudTransport!.pull(resolver: ConflictResolver());
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _ensureCloudTransport() async {
    final st = await repo.settings();
    final url = (st['cloudBackendUrl'] ?? '').trim();
    final autoSync = (st['cloudAutoSync'] ?? '1') != '0';
    if (!autoSync || url.isEmpty) {
      _transports.removeWhere((t) => t.targetId == SyncTarget.cloud);
      unawaited(_cloudTransport?.stopListening() ?? Future.value());
      _cloudTransport = null;
      _cloudUrl = null;
      // تنظيف: صفوف cloud القديمة العالقة بلا خادم سحابي مهيأ — كانت تبقى
      // «بانتظار الإرسال» للأبد وتظهر كمزامنات معلقة. نُعلمها synced.
      try {
        final db = await _db;
        await db.update(
          'sync_queue',
          {
            'status': 'synced',
            'last_error': '',
            'next_try_at': '',
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: "target = ? AND status IN ('pending','syncing','failed')",
          whereArgs: [SyncTarget.cloud],
        );
      } catch (_) {}
      return;
    }
    if (url == _cloudUrl && _cloudTransport != null) return;
    final db = await _db;
    // Workspace الحالي.
    final wsRow = await db.query('workspaces', limit: 1);
    final wsId =
        wsRow.isNotEmpty ? (wsRow.first['id'] as String) : defaultWorkspaceId;
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
    // استماع فوري SSE: أي عملية يكتبها جهاز آخر في السحابة تصلنا لحظياً
    // (السحب الدوري كل 45 ثانية يبقى شبكة أمان لو انقطعت القناة).
    _cloudTransport!.onCloudChanged = () {
      Future(() async {
        try {
          final applied =
              await _cloudTransport?.pull(resolver: ConflictResolver()) ?? 0;
          if (applied > 0) {
            try {
              onSyncActivity?.call();
            } catch (_) {}
          }
        } catch (_) {}
      });
    };
    unawaited(_cloudTransport!.startListening());
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final generation = ++_generation;
    _queue ??= SyncQueueOps(await _db);
    await _queue!.recoverInterrupted();
    // إنقاذ المزامنات السابقة العالقة: أي عملية محلية لم تصل لكل الأجهزة
    // (لا صف lan لها في الطابور أو صفها علق قبل الإصلاحات) يُعاد إدراجها.
    try {
      await _backfillMissedLanOps();
    } catch (_) {}
    if (!_started || generation != _generation) return;
    // ربط callback لتحفيز push فوري بعد تسجيل أي عملية جديدة.
    SyncRecorder.onOperationRecorded = notifyNewOperation;
    // أي فشل في تهيئة المزامنة (سواء سحابة أو شبكة محلية) لا يجب أن يمنع
    // التطبيق من الإقلاع أو تعطيل الحفظ المحلي — محلي أولًا دائماً.
    try {
      await _ensureCloudTransport();
    } catch (_) {}
    try {
      await _ensureLanTransport();
    } catch (_) {}
    if (!_started || generation != _generation) {
      await _lanTransport?.stopServer();
      return;
    }
    _timer ??= Timer.periodic(
      const Duration(seconds: 8),
      (_) => processQueue(),
    );

    Future(() async {
      if (!_started || generation != _generation) return;
      try {
        await _ensureCloudTransport();
        if (_cloudTransport != null) {
          try {
            await _cloudTransport!.pull(resolver: ConflictResolver());
          } catch (_) {}
        }
      } catch (_) {}
      await _checkExpulsionAndAutoPurge();
      await processQueue();
    });
    // تفقد دوري كل 6 ساعات: هل طرأ طرد لنا، أو هناك أجهزة خاملة لنطرَدها تلقائياً.
    _maintenanceTimer ??= Timer.periodic(
      const Duration(hours: 6),
      (_) => _checkExpulsionAndAutoPurge(),
    );
    // مصالحة دورية سريعة لقائمة الأجهزة/الملكية: تكتشف نقل الملكية إلينا أو
    // تغيّر الأقران/الأدوار خلال ثوانٍ دون الحاجة للقطة كاملة.
    _rosterTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => _reconcileRoster(),
    );
    // سحب سحابي دوري: بدون هذا كان السحب يحدث مرة واحدة فقط عند الإقلاع،
    // فلا تصل عمليات الأجهزة الأخرى عبر السحابة إلا بعد إعادة تشغيل التطبيق.
    _cloudPullTimer ??= Timer.periodic(
      const Duration(seconds: 45),
      (_) => _periodicCloudPull(),
    );
  }

  Future<void> _periodicCloudPull() async {
    if (_cloudPulling || !_started) return;
    if (_cloudTransport == null) return;
    _cloudPulling = true;
    try {
      final applied = await _cloudTransport!.pull(resolver: ConflictResolver());
      if (applied > 0) {
        try {
          onSyncActivity?.call();
        } catch (_) {}
      }
      // سجل الأجهزة السحابي: يرى المدير أجهزة الأعضاء البعيدة (المنضمة عبر
      // السحابة) ويعيّن لها مستخدمين، وتصل التعيينات/الحظر/الطرد للأعضاء.
      try {
        final t = _cloudTransport!;
        final changed = await CloudJoin.syncRoster(
          repo,
          await _db,
          backendUrl: t.backendUrl,
          workspaceId: t.workspaceId,
        );
        if (changed) {
          try {
            onSyncActivity?.call();
          } catch (_) {}
        }
      } catch (_) {}
    } catch (_) {
      // شبكة غائبة/خادم بعيد — المحاولة القادمة بعد الدورة التالية.
    } finally {
      _cloudPulling = false;
    }
  }

  /// إنقاذ العمليات السابقة (ما قبل الإصلاحات): عمليات محلية سُجّلت أيام
  /// كانت مزامنة LAN معطلة أو علقت في الطابور — نعيد إدراج هدف lan لها
  /// حتى تُدفع الآن لكل الأجهزة. آمنة تماماً: الاستقبال idempotent
  /// (نفس operation id لا يُطبق مرتين)، وop_deliveries يمنع التكرار للجهاز
  /// الذي استلم فعلاً.
  Future<void> _backfillMissedLanOps() async {
    final db = await _db;
    final st = await repo.settings();
    if ((st['lanSyncEnabled'] ?? '0') != '1') return;
    final ourId = st['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return;
    // لا معنى للإنقاذ بلا أقران.
    final peers = await db.rawQuery(
      "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
      "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' "
      "AND id <> ?",
      [ourId],
    );
    if (((peers.first['c'] as int?) ?? 0) == 0) return;
    final now = DateTime.now().toIso8601String();
    // كل عملية محلية بلا صف lan في الطابور — أدرجه pending.
    await db.rawInsert('''
      INSERT OR IGNORE INTO sync_queue
        (operation_id, status, target, attempts, last_error, next_try_at,
         created_at, updated_at)
      SELECT o.id, 'pending', 'lan', 0, '', '', ?, ?
      FROM operations o
      WHERE o.device_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM sync_queue q
          WHERE q.operation_id = o.id AND q.target = 'lan'
        )
    ''', [now, now, ourId]);
    // صفوف lan التي عُلّمت synced قديماً لكن لم تُسلَّم فعلياً لكل الأجهزة
    // (لا سجلات كافية في op_deliveries) — نعيدها pending لتُستكمل.
    await db.rawUpdate('''
      UPDATE sync_queue SET status = 'pending', next_try_at = '',
                            attempts = 0, updated_at = ?
      WHERE target = 'lan' AND status = 'synced'
        AND operation_id IN (
          SELECT o.id FROM operations o
          WHERE o.device_id = ?
            AND (SELECT COUNT(*) FROM op_deliveries d
                 WHERE d.operation_id = o.id) <
                (SELECT COUNT(*) FROM devices v
                 WHERE v.is_paired = 1 AND COALESCE(v.revoked_at,'') = ''
                   AND COALESCE(v.expelled_at,'') = '' AND v.id <> ?)
        )
    ''', [now, ourId, ourId]);
  }

  Future<void> _reconcileRoster() async {
    try {
      if (!_started) return;
      await _ensureLanTransport();
      final changed = await _lanTransport?.reconcileRoster();
      if (changed == true) {
        // تغيرت ملكيتنا → أعد معالجة الطابور لتطبيق أي عمليات معلّقة.
        await processQueue();
      }
    } catch (_) {}
  }

  Future<void> _checkExpulsionAndAutoPurge() async {
    try {
      if (await repo.isWorkspaceOwner()) {
        await repo.autoExpireStaleDevices();
        return;
      }
      if (await repo.amIExpelled()) {
        await repo.resetToStandaloneAfterExpulsion();
      }
    } catch (_) {}
  }

  void stop() {
    _started = false;
    _generation++;
    _completeTimer?.cancel();
    _completeTimer = null;
    _recentDelivered.clear();
    _timer?.cancel();
    _maintenanceTimer?.cancel();
    _rosterTimer?.cancel();
    _cloudPullTimer?.cancel();
    _cloudPullTimer = null;
    unawaited(_cloudTransport?.stopListening() ?? Future.value());
    _immediate?.cancel();
    _presence?.dispose();
    _presence = null;
    _timer = null;
    _maintenanceTimer = null;
    _rosterTimer = null;
    _immediate = null;
    if (SyncRecorder.onOperationRecorded == notifyNewOperation) {
      SyncRecorder.onOperationRecorded = null;
    }
    final lan = _lanTransport;
    _lanTransport = null;
    _lanEnabled = false;
    _transports.removeWhere((t) => t.targetId == SyncTarget.lanBroadcast);
    if (lan != null) unawaited(lan.stopServer());
  }

  /// User action also resumes rows that exhausted their automatic retry budget.
  Future<void> forceSyncNow() async {
    final q = _queue ??= SyncQueueOps(await _db);
    await q.retryFailed();
    await processQueue();
    // نبّه الأقران فورًا ليسحبوا الطابور/الصلاحيات المعلّقة.
    await _lanTransport?.broadcastNotify(reason: 'force');
  }

  /// يُستدعى بعد تغيير صلاحية/جهاز (منح صلاحية لجهاز) لبثّ التغيير فورًا
  /// إلى كل الأقران ودفع أي عمليات معلّقة — استجابة خلال ثوانٍ (<10 ثوانٍ).
  Future<void> broadcastRosterChange() async {
    try {
      await _lanTransport?.broadcastNotify(reason: 'roster');
    } catch (_) {}
    notifyNewOperation();
  }

  /// جدولة push فورية (لا تنتظر دورة الـ Timer) — لتسريع Near-Real-Time.
  Timer? _immediate;
  void notifyNewOperation() {
    if (!_started) return;
    _immediate?.cancel();
    // Debounce قصير جدًا (80ms) لتجميع العمليات السريعة مع بقاء المزامنة فورية.
    _immediate = Timer(const Duration(milliseconds: 80), () {
      processQueue();
    });
  }

  Future<SyncSummary> summary() async {
    final q = _queue ??= SyncQueueOps(await _db);
    final pending = await q.countPending();
    final failed = await q.countFailed();
    return SyncSummary(pending: pending, failed: failed);
  }

  Future<void> processQueue() async {
    if (_running) return;
    _running = true;
    try {
      final db = await _db;
      final q = _queue ??= SyncQueueOps(db);
      for (final t in List<SyncTransport>.of(_transports)) {
        List<Map<String, Object?>> rows;
        try {
          rows = await q
              .pickPending(limit: 20, target: t.targetId)
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          continue;
        }
        for (final r in rows) {
          final qid = r['id'] as int;
          final opId = r['operation_id'] as String;
          try {
            await q.markSyncing(qid).timeout(const Duration(seconds: 5));
          } catch (_) {
            continue; // Do not send without a durable queue state.
          }
          String? entityTable;
          String? entityId;
          try {
            final opRows = await db
                .query(
                  'operations',
                  where: 'id = ?',
                  whereArgs: [opId],
                  limit: 1,
                )
                .timeout(const Duration(seconds: 5));
            if (opRows.isEmpty) {
              try {
                await q.markSynced(qid).timeout(const Duration(seconds: 3));
              } catch (_) {}
              continue;
            }
            final op = SyncOperation.fromMap(opRows.first);
            entityTable = switch (op.entityType) {
              EntityKind.tx => 'transactions',
              EntityKind.account => 'accounts',
              EntityKind.item => 'items',
              EntityKind.itemCategory => 'item_categories',
              EntityKind.stockMove => 'stock_moves',
              EntityKind.voucher => 'vouchers',
              EntityKind.user => 'users',
              EntityKind.currency => 'currencies',
              EntityKind.setting => 'settings',
              EntityKind.category => 'categories',
              EntityKind.conversation => 'conversations',
              EntityKind.message => 'messages',
            };
            entityId = op.entityId;
            if (entityTable == 'transactions') {
              try {
                await db
                    .update(
                      'transactions',
                      {'sync_state': 'syncing'},
                      where: 'id = ?',
                      whereArgs: [entityId],
                    )
                    .timeout(const Duration(seconds: 3));
              } catch (_) {}
            }
            // مهلة 20 ثانية لكل عملية دفع حتى لا تعلق قائمة الانتظار كلها.
            await t.push(op).timeout(const Duration(seconds: 20));
            try {
              await q.markSynced(qid).timeout(const Duration(seconds: 3));
            } catch (_) {}
            if (entityTable == 'transactions') {
              try {
                await db
                    .update(
                      'transactions',
                      {'sync_state': 'synced'},
                      where: 'id = ?',
                      whereArgs: [entityId],
                    )
                    .timeout(const Duration(seconds: 3));
              } catch (_) {}
            }
          } catch (e) {
            try {
              await q.markFailed(qid, e).timeout(const Duration(seconds: 3));
            } catch (_) {}
            if (entityTable == 'transactions' && entityId != null) {
              try {
                await db
                    .update(
                      'transactions',
                      {'sync_state': 'failed'},
                      where: 'id = ?',
                      whereArgs: [entityId],
                    )
                    .timeout(const Duration(seconds: 3));
              } catch (_) {}
            }
          }
        }
      }
    } finally {
      _running = false;
      try {
        onSyncActivity?.call();
      } catch (_) {}
    }
  }
}

class SyncSummary {
  final int pending;
  final int failed;
  const SyncSummary({required this.pending, required this.failed});
}
