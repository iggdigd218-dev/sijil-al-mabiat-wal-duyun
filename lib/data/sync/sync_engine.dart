// محرك المزامنة الخلفية.
//   - معالجة الصفوف PENDING من sync_queue.
//   - استدعاء transports المسجلة (Cloud/LAN).
//   - إعادة المحاولة مع backoff.
//   - سحب العمليات من الـ Cloud تلقائيًا عند التهيئة.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/token_cipher.dart';
import '../repository.dart';
import 'cloud_firebase_transport.dart';
import 'cloud_join.dart';
import 'conflict_resolver.dart';
import 'operation.dart';
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

  /// «نافذة الخطر»: تُستدعى عندما يكتشف المحرك حالة تباين خطيرة —
  /// عمليات عالقة طويلاً مع فشل متكرر، أو انقطاع مديد عن كل الأقران.
  /// الوسيط رسالة عربية توضح المشكلة. null = زالت الحالة (أمان).
  static void Function(String? message)? onSyncDanger;

  /// (دفعة 53) الطرد التلقائي: تُستدعى مرة واحدة عندما يكتشف الجهاز أن
  /// المدير حذفه/حظره/طرده من سجل المجموعة السحابي. الواجهة تعيد التوجيه
  /// لشاشة الترحيب مع رسالة «تم إلغاء ارتباط هذا الجهاز من قبل مدير المؤسسة».
  static void Function()? onDeviceEvicted;

  /// حارس ضد ازدواج معالجة الطرد (SSE + pull قد يكتشفانه معاً).
  bool _evictionHandled = false;

  /// آخر رسالة خطر مبثوثة (لتجنب التكرار) — '' تعني لا خطر.
  String _lastDangerMsg = '';
  DateTime? _oldestStuckSince;

  /// أجهزة استلمت عمليات مؤخراً — تُفحص بعد مهلة قصيرة لإشعار «اكتملت
  /// المزامنة مع (الجهاز)» عندما يفرغ الطابور.
  final Set<String> _recentDelivered = {};
  Timer? _completeTimer;

  /// يُستدعى أي نشاط مزامنة (وصول عملية/تغيّر صلاحيات) لتنبيه الواجهة للتحديث.
  static void Function()? onSyncActivity = SyncActivityBus.instance.ping;
  String? _cloudUrl;
  CloudFirebaseTransport? _cloudTransport;

  SyncEngine({required this.repo, required this.dbProvider});

  Future<Database> get _db async => dbProvider();

  void registerTransport(SyncTransport t) {
    if (_transports.any((x) => x.targetId == t.targetId)) return;
    _transports.add(t);
  }

  /// يربط ناقل LAN بنظام الحضور (تخطي الغائبين) وبإشعار التسليم الناجح،
  /// ويشغّل خدمة الحضور (مناداة كل 3 ثوانٍ + مزامنة فورية عند عودة قرين).
  /// اللقب الموحد للجهاز بحسب دور مستخدمه: «المدير (اسم الجهاز)»،
  /// «الكاشير (…)»، «مدخل البيانات (…)»، «الشريك / الوكيل (…)».
  /// يُستخدم في كل تنبيهات المزامنة وحالات الأقران.
  Future<String> roleDisplayNameOf(
      String deviceId, String fallbackName) async {
    var name = fallbackName.trim();
    var role = '';
    var isOwner = false;
    try {
      final db = await _db;
      final rows = await db.rawQuery('''
        SELECT d.name, d.is_owner, COALESCE(u.role, '') AS role
        FROM devices d LEFT JOIN users u ON u.id = d.user_id
        WHERE d.id = ? LIMIT 1
      ''', [deviceId]);
      if (rows.isNotEmpty) {
        final r = rows.first;
        final dbName = (r['name'] as String?)?.trim() ?? '';
        if (dbName.isNotEmpty) name = dbName;
        role = (r['role'] as String?) ?? '';
        isOwner = ((r['is_owner'] as int?) ?? 0) == 1;
      }
    } catch (_) {}
    if (name.isEmpty) name = 'جهاز';
    final label = isOwner
        ? 'المدير'
        : switch (role) {
            'admin' || 'manager' => 'المدير',
            'agent' => 'الشريك / الوكيل',
            'accountant' => 'الكاشير',
            'dataentry' => 'مدخل البيانات',
            _ => '',
          };
    return label.isEmpty ? name : '$label ($name)';
  }

  /// حارس تباين السجلات («نافذة الخطر»): يفحص دورياً وجود عمليات مالية
  /// عالقة منذ فترة طويلة (فشل متكرر أو انقطاع مديد عن كل الأقران).
  /// عند اكتشاف الحالة يبثّ رسالة عربية عالية الأولوية تتكرر حتى تزول،
  /// وعند زوالها يبثّ null لإخفاء التنبيه.
  Future<void> _checkDangerState() async {
    if (onSyncDanger == null) return;
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'standalone') {
        _clearDanger();
        return;
      }
      final db = await _db;
      // حساب دقيق للتباين: عمليات مميّزة (operation_id) لا صفوف طابور خام —
      // الصف الواحد قد يتكرر لهدفين (lan + cloud) فيتضاعف العدد زوراً،
      // وتُستبعد الكيانات الصامتة (رسائل الدردشة) لأنها ليست خطراً مالياً.
      final rows = await db.rawQuery(
        "SELECT COUNT(DISTINCT q.operation_id) c, MIN(q.created_at) oldest, "
        "MAX(q.attempts) att "
        "FROM sync_queue q JOIN operations o ON o.id = q.operation_id "
        "WHERE q.status IN ('pending','failed','syncing') "
        "AND o.entity_type NOT IN ${SyncQueueOps.silentEntities}",
      );
      final stuck = (rows.first['c'] as int?) ?? 0;
      if (stuck == 0) {
        _clearDanger();
        return;
      }
      final oldest = DateTime.tryParse('${rows.first['oldest'] ?? ''}');
      final attempts = (rows.first['att'] as int?) ?? 0;
      // تتبّع حي لأقدم عالقة من قاعدة البيانات مباشرة: لو نجح دفع الصفوف
      // القديمة وبقيت صفوف حديثة فقط، يهبط العمر تحت العتبة ويُخفى البانر —
      // التخزين المؤقت القديم (??=) كان يُبقي الخطر ظاهراً زوراً.
      _oldestStuckSince = oldest ?? _oldestStuckSince ?? DateTime.now();
      final stuckFor = DateTime.now().difference(_oldestStuckSince!);
      // عتبة الخطر: عالقة ≥ 10 دقائق مع محاولات متكررة، أو ≥ 30 دقيقة مطلقاً.
      final danger = (stuckFor >= const Duration(minutes: 10) &&
              attempts >= 5) ||
          stuckFor >= const Duration(minutes: 30);
      if (!danger) {
        // دون العتبة (عولج القديم): أخفِ البانر إن كان ظاهراً.
        if (_lastDangerMsg.isNotEmpty) _clearDanger();
        return;
      }
      // هل المدير (المالك) غير متصل؟ نخصص الرسالة.
      var ownerOffline = false;
      try {
        final own = await db.query('devices',
            columns: ['id'],
            where: "is_owner = 1 AND is_paired = 1 "
                "AND COALESCE(revoked_at,'') = ''",
            limit: 1);
        // (دفعة 58) لا مسبار LAN بعد الآن — نستدل بغياب مزامنة حديثة:
        // آخر last_sync_at للمالك أقدم من 5 دقائق = غير متصل غالباً.
        if (own.isNotEmpty) {
          final r = await db.query('devices',
              columns: ['last_sync_at'],
              where: 'id = ?',
              whereArgs: [own.first['id']],
              limit: 1);
          final ls = DateTime.tryParse('${r.isEmpty ? '' : r.first['last_sync_at'] ?? ''}');
          ownerOffline = ls == null ||
              DateTime.now().difference(ls) > const Duration(minutes: 5);
        }
      } catch (_) {}
      final mins = stuckFor.inMinutes;
      final msg = ownerOffline
          ? 'تنبيه خطير: تعذّر مطابقة الحركات المالية مع جهاز المدير منذ '
              '$mins دقيقة ($stuck عملية معلقة). يرجى فحص الاتصال لتفادي '
              'تباين الأرصدة بين الأجهزة.'
          : 'تنبيه خطير: $stuck عملية مالية لم تصل بقية الأجهزة منذ '
              '$mins دقيقة رغم إعادة المحاولة. يرجى فحص اتصال الشبكة أو '
              'السحابة لتفادي تباين الأرصدة.';
      if (msg != _lastDangerMsg) {
        _lastDangerMsg = msg;
      }
      // نبثّ في كل دورة فحص (تكرار مقصود عبر الشاشات حتى تُحل).
      try {
        onSyncDanger?.call(msg);
      } catch (_) {}
    } catch (_) {}
  }

  /// للاختبارات: تشغيل فحص الخطر مباشرة بلا انتظار المؤقّت الدوري.
  @visibleForTesting
  Future<void> debugCheckDangerState() => _checkDangerState();

  /// فحص فوري عام لواجهة المستخدم (زر «إعادة المحاولة» في بانر الخطر):
  /// يعيد تقييم الحالة حالاً — نجاح يبثّ null، وبقاء الخطر يبثّ الرسالة.
  Future<void> recheckDangerNow() => _checkDangerState();

  void _clearDanger() {
    _oldestStuckSince = null;
    if (_lastDangerMsg.isNotEmpty) {
      _lastDangerMsg = '';
      try {
        onSyncDanger?.call(null);
      } catch (_) {}
    }
  }

  /// (دفعة 58) إعادة تهيئة شاملة = السحابة فقط — لا طبقة LAN بعد اليوم.
  Future<void> reconfigureAll() async {
    try {
      await reconfigureCloud();
    } catch (_) {}
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
          final stored = r.first['id_token'] as String?;
          if (stored == null || stored.isEmpty) return null;
          // مخزّن معمّى (enc1:) أو نص صريح قديم — reveal يتعامل مع الحالتين.
          final tok = await TokenCipher.reveal(stored);
          return tok.isEmpty ? null : tok;
        } catch (_) {
          return null;
        }
      },
    );
    registerTransport(_cloudTransport!);
    _cloudUrl = url;
    // (دفعة 53) مصافحة العضوية النشطة: الناقل يفحص /roster/$deviceId
    // قبل كل سحب وعند تمهيد SSE — اكتشاف الطرد يمر بالمعالج المركزي.
    _cloudTransport!.onEvicted = () {
      unawaited(handleSelfEviction());
    };
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
    _evictionHandled = false;
    // (دفعة 53) ربط خطاف الطرد المركزي: أي مسار يكتشف الطرد
    // (syncRoster/مصافحة roster في الناقل) يمر من handleSelfEviction.
    CloudJoin.onSelfEvicted = handleSelfEviction;
    final generation = ++_generation;
    _queue ??= SyncQueueOps(await _db);
    await _queue!.recoverInterrupted();
    // إنقاذ سحابي: عمليات سُجّلت قبل تهيئة السحابة (لا صف cloud لها) —
    // تُدرج الآن لتصعد للسحابة فتصل الأجهزة المرتبطة سحابياً.
    try {
      await _backfillMissedCloudOps();
    } catch (_) {}
    // (دفعة 58) هجرة تنظيف: أي صفوف lan تاريخية متبقية من إصدارات ما قبل
    // اجتثاث LAN تُغلق نهائياً حتى لا تسد الطابور أو تُظهر بانر الخطأ.
    try {
      final db0 = await _db;
      await db0.update(
        'sync_queue',
        {
          'status': 'synced',
          'last_error': '',
          'next_try_at': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: "target = 'lan' AND status IN ('pending','syncing','failed')",
      );
      await _queue!.resumeBackoff();
    } catch (_) {}
    if (!_started || generation != _generation) return;
    // ربط callback لتحفيز push فوري بعد تسجيل أي عملية جديدة.
    SyncRecorder.onOperationRecorded = notifyNewOperation;
    // أي فشل في تهيئة المزامنة (سواء سحابة أو شبكة محلية) لا يجب أن يمنع
    // التطبيق من الإقلاع أو تعطيل الحفظ المحلي — محلي أولًا دائماً.
    try {
      await _ensureCloudTransport();
    } catch (_) {}
    if (!_started || generation != _generation) return;
    _timer ??= Timer.periodic(
      const Duration(seconds: 8),
      (_) async {
        await processQueue();
        await _checkDangerState();
      },
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
      (_) async {
        await _checkExpulsionAndAutoPurge();
        try {
          await _pruneOperationPayloads();
        } catch (_) {}
        // (دفعة 58) رسائل الدردشة تُحذف نهائياً بعد 24 ساعة (محلي).
        try {
          await repo.purgeExpiredChatMessages();
        } catch (_) {}
      },
    );
    // تقليم فوري عند الإقلاع (خلفية، لا يعطل الواجهة) + جلب المرفقات
    // الناقصة من الأقران (عمليات وصلت بالمزامنة بلا ملفاتها).
    Future(() async {
      try {
        await _pruneOperationPayloads();
      } catch (_) {}
      // (دفعة 58) تنظيف الدردشة المنتهية عمرها فور الإقلاع أيضاً.
      try {
        await repo.purgeExpiredChatMessages();
      } catch (_) {}
    });
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


  /// إنقاذ سحابي: كل عملية محلية لم يُدرج لها هدف cloud (سُجّلت قبل ضبط
  /// السحابة أو أثناء تعطيلها) تُدرج pending الآن. idempotent بالكامل:
  /// الدفع للسحابة PUT على نفس opId، والصف لا يتكرر (INSERT OR IGNORE).
  Future<void> _backfillMissedCloudOps() async {
    final db = await _db;
    final st = await repo.settings();
    final cloudOn = (st['cloudBackendUrl'] ?? '').trim().isNotEmpty &&
        (st['cloudAutoSync'] ?? '1') != '0';
    if (!cloudOn) return;
    final ourId = st['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    await db.rawInsert('''
      INSERT OR IGNORE INTO sync_queue
        (operation_id, status, target, attempts, last_error, next_try_at,
         created_at, updated_at)
      SELECT o.id, 'pending', 'cloud', 0, '', '', ?, ?
      FROM operations o
      WHERE o.device_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM sync_queue q
          WHERE q.operation_id = o.id AND q.target = 'cloud'
        )
    ''', [now, now, ourId]);
  }

  /// صيانة تخزين جدول العمليات (تعمل عند الإقلاع وكل 6 ساعات):
  /// 1) تجريد حمولات base64 الضخمة (مرفقات الدردشة) من العمليات التي
  ///    وصلت لكل الأجهزة — الملف محفوظ على القرص، ولا حاجة لنسخة ثانية
  ///    داخل SQLite تتضخم وتُبطئ كل قراءة.
  /// 2) حذف عمليات الدردشة القديمة (أقدم من 14 يوماً) المستلمة من الجميع
  ///    والمرفوعة للسحابة — الرسائل نفسها باقية في جدول messages.
  /// مدخل للاختبارات فقط — يشغّل صيانة تخزين العمليات مباشرة.
  @visibleForTesting
  Future<void> pruneOperationPayloadsForTesting() =>
      _pruneOperationPayloads();

  Future<void> _pruneOperationPayloads() async {
    final db = await _db;
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return;
    // (دفعة 58) المعيار السحابي الوحيد: synced=1 = العملية على السحابة
    // ويستطيع أي قرين سحبها — لا op_deliveries بعد اليوم.
    // (1) تجريد base64: عملياتنا المرفوعة للسحابة وحمولتها تتضمن file_b64.
    final fat = await db.rawQuery('''
      SELECT id, payload FROM operations
      WHERE payload LIKE '%"file_b64"%' AND synced = 1
      LIMIT 200
    ''');
    for (final r in fat) {
      try {
        final decoded =
            jsonDecode((r['payload'] as String?) ?? '{}') as Map;
        final slim = Map<String, Object?>.from(decoded)
          ..remove('file_b64')
          ..['file_pruned'] = 1;
        await db.update('operations', {'payload': jsonEncode(slim)},
            where: 'id = ?', whereArgs: [r['id']]);
      } catch (_) {}
    }
    // (2) حذف عمليات الرسائل القديمة كلياً بعد فترة الاحتفاظ.
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 14))
        .toIso8601String();
    try {
      await db.rawDelete('''
        DELETE FROM operations
        WHERE entity_type = 'message' AND synced = 1 AND timestamp < ?
      ''', [cutoff]);
    } catch (_) {}
    // (3) تقليم عام (Compaction): العمليات المتجاوَزة — synced، مسلَّمة لكل
    // الأقران النشطين، أقدم من 14 يوماً، وليست أحدث نسخة لكيانها.
    // الإبقاء على أحدث نسخة لكل كيان يحفظ اتساق تسلسل الإصدارات
    // (nextVersion يقرأ MAX(version)) ويُبقي حاجز idempotency ضد إعادة
    // تطبيق نسخ قديمة تصل من سحب سحابي كامل.
    try {
      await db.transaction((txn) async {
        await txn.rawDelete('''
          DELETE FROM operations
          WHERE synced = 1 AND timestamp < ?
            AND entity_type <> 'message'
            AND EXISTS (
              SELECT 1 FROM operations n
              WHERE n.entity_type = operations.entity_type
                AND n.entity_id = operations.entity_id
                AND n.version > operations.version
            )
            AND NOT EXISTS (
              SELECT 1 FROM sync_queue q
              WHERE q.operation_id = operations.id
                AND q.status IN ('pending', 'syncing')
            )
        ''', [cutoff]);
        // صفوف الطابور التاريخية (synced) الأقدم من فترة الاحتفاظ.
        await txn.rawDelete(
          "DELETE FROM sync_queue WHERE status = 'synced' AND updated_at < ?",
          [cutoff],
        );
      });
    } catch (_) {}
  }

  Future<void> _reconcileRoster() async {
    try {
      if (!_started) return;
      // (دفعة 58) المصالحة سحابية حصرياً: سحب فوري يلتقط أي تغيّر في
      // السجل/الملكية المدفوع من المدير، ثم معالجة الطابور.
      final t = _cloudTransport;
      if (t != null) {
        await t.pull(resolver: ConflictResolver());
        await processQueue();
      }
    } catch (_) {}
  }

  Future<void> _checkExpulsionAndAutoPurge() async {
    try {
      if (await repo.isWorkspaceOwner()) {
        await repo.autoExpireStaleDevices();
        // (دفعة 57) صيانة سحابية للمدير في نفس الدورة:
        //  1) تقليم شواهد الطرد المنتهية (TTL 7 أيام) — لا ركام أبدياً.
        //  2) ضغط سجل العمليات السحابي (أقدم من 30 يوماً ومغطاة باللقطة).
        try {
          final st = await repo.settings();
          final url = (st['cloudBackendUrl'] ?? '').trim();
          if (url.isNotEmpty) {
            final ws = _cloudTransport?.workspaceId ?? 'default';
            try {
              await CloudJoin.pruneExpiredEvictions(
                  backendUrl: url, workspaceId: ws);
            } catch (_) {}
            try {
              await compactCloudOperations(backendUrl: url, workspaceId: ws);
            } catch (_) {}
            // (دفعة 58) عمليات الدردشة الأقدم من 24 ساعة تُطهَّر سحابياً.
            try {
              await CloudJoin.purgeOldChatOperations(
                  backendUrl: url, workspaceId: ws);
            } catch (_) {}
            // 3) زوال اللقطة: دعوة منتهية بلا أخرى حية → حذف joinSnapshot.
            try {
              await CloudJoin.purgeStaleInviteArtifacts(
                  backendUrl: url, workspaceId: ws);
            } catch (_) {}
          }
        } catch (_) {}
        return;
      }
      if (await repo.amIExpelled()) {
        await handleSelfEviction();
        return;
      }
      // (دفعة 54) فحص شاهدة الطرد الصريحة عند الإقلاع وكل دورة صيانة —
      // يغطي حالة إقلاع الجهاز بعد أن طُرد وهو مطفأ (قبل فتح قنوات SSE).
      if (await repo.workspaceMode() == 'member') {
        final st = await repo.settings();
        final url = (st['cloudBackendUrl'] ?? '').trim();
        final devId = (st['sync.deviceId'] ?? '').trim();
        if (url.isNotEmpty && devId.isNotEmpty) {
          try {
            final tomb = await CloudJoin.hasEvictionTombstone(
              backendUrl: url,
              deviceId: devId,
              workspaceId: _cloudTransport?.workspaceId ?? 'default',
            );
            if (tomb) await handleSelfEviction();
          } catch (_) {
            // شبكة — المصافحة داخل الناقل تغطي لاحقاً.
          }
        }
      }
    } catch (_) {}
  }

  /// (دفعة 53) المعالجة المركزية للطرد الذاتي — تُنفَّذ مرة واحدة فقط:
  ///  1) إيقاف فوري لقناة SSE وكل الدفع الصادر (المحرك بأكمله).
  ///  2) وسم صف جهازنا المحلي revoked_at (قبل المسح — أثر تدقيقي فوري).
  ///  3) تفريغ طابور المزامنة ومفاتيح جلسة المجموعة
  ///     (cloudBackendUrl/cloudCode/pendingJoin.*).
  ///  4) العودة لوضع standalone بقاعدة نظيفة (resetToStandalone).
  ///  5) بث onDeviceEvicted للواجهة → شاشة الترحيب + الرسالة الصريحة.
  Future<void> handleSelfEviction() async {
    if (_evictionHandled) return;
    _evictionHandled = true;
    // 1) أوقف المحرك كاملاً: SSE + مؤقتات الدفع والسحب.
    try {
      stop();
    } catch (_) {}
    // 2) وسم الصف المحلي revoked_at الآن (توثيق لحظة الاكتشاف).
    try {
      final db = await _db;
      final st = await repo.settings();
      final devId = (st['sync.deviceId'] ?? '').trim();
      if (devId.isNotEmpty) {
        await db.update(
          'devices',
          {'revoked_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [devId],
        );
      }
      // 3) تفريغ الطابور + مفاتيح الجلسة فوراً (قبل إعادة الضبط الشاملة).
      await db.delete('sync_queue');
      await db.delete('settings',
          where: "key IN (?, ?) OR key LIKE 'pendingJoin.%'",
          whereArgs: ['cloudBackendUrl', 'cloudCode']);
    } catch (_) {}
    // 4) إعادة الضبط الكاملة لوضع standalone (قاعدة نظيفة + هوية جديدة).
    try {
      await repo.resetToStandaloneAfterExpulsion();
    } catch (_) {}
    // 5) بث الحدث للواجهة.
    try {
      onDeviceEvicted?.call();
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
    _timer = null;
    _maintenanceTimer = null;
    _rosterTimer = null;
    _immediate = null;
    if (SyncRecorder.onOperationRecorded == notifyNewOperation) {
      SyncRecorder.onOperationRecorded = null;
    }
  }

  /// User action also resumes rows that exhausted their automatic retry budget.
  Future<void> forceSyncNow() async {
    final q = _queue ??= SyncQueueOps(await _db);
    await q.retryFailed();
    await processQueue();
    // إعادة تقييم «نافذة الخطر» فوراً: إن نجح الدفع يُبث null فيختفي
    // البانر في نفس اللحظة دون انتظار الدورة (8 ثوانٍ).
    await _checkDangerState();
  }

  /// زر «إعادة المحاولة والمزامنة فوراً» في بانر الخطر: نفس forceSyncNow
  /// باسم صريح — يصفّر backoff ويعيد المحاولة ويدفع كل المعلّق حالاً
  /// ثم يعيد فحص الخطر ليُخفى البانر تلقائياً عند النجاح.
  Future<void> triggerImmediateSync() => forceSyncNow();

  /// يُستدعى بعد تغيير صلاحية/جهاز (منح صلاحية لجهاز) لبثّ التغيير فورًا
  /// إلى كل الأقران ودفع أي عمليات معلّقة — استجابة خلال ثوانٍ (<10 ثوانٍ).
  /// (دفعة 54 — جهة المدير) بث الطرد النشط لجهاز مستهدف:
  ///  1) شاهدة صريحة في /evictions/$deviceId بختم وقت الخادم —
  ///     تصل المستهدف عبر قناته المخصصة لحظياً.
  ///  2) حذف عقدته من /roster نهائياً (محفّز الدفاع الثاني).
  /// يُستدعى بعد expelDevice/revokeDevice المحليتين مباشرة.
  /// (دفعة 57) قياس سحابي حي لواجهة الإعدادات — بديل عرض ip:port القديم:
  /// حالة قناة SSE، كمون السحابة (رحلة GET خفيفة)، اسم مساحة العمل،
  /// وعدد العمليات المنتظرة في طابور الدفع السحابي.
  Future<Map<String, Object?>> cloudTelemetry() async {
    final t = _cloudTransport;
    final db = await _db;
    var pending = 0;
    try {
      final r = await db.rawQuery(
          "SELECT COUNT(*) c FROM sync_queue WHERE target = 'cloud' "
          "AND status IN ('pending','syncing','failed')");
      pending = (r.first['c'] as int?) ?? 0;
    } catch (_) {}
    String wsName = '';
    try {
      final w = await db.query('workspaces', limit: 1);
      if (w.isNotEmpty) {
        wsName = '${w.first['name'] ?? w.first['id'] ?? ''}';
      }
    } catch (_) {}
    int latencyMs = -1;
    try {
      final st = await repo.settings();
      final url = (st['cloudBackendUrl'] ?? '').trim();
      if (url.isNotEmpty) {
        final ws = t?.workspaceId ?? 'default';
        final sw = Stopwatch()..start();
        final res = await http
            .get(Uri.parse(
                '${url.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}/roster.json?shallow=true'))
            .timeout(const Duration(seconds: 8));
        sw.stop();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          latencyMs = sw.elapsedMilliseconds;
        }
      }
    } catch (_) {}
    return {
      'sse': t?.isListening ?? false,
      'evicted': t?.isEvicted ?? false,
      'workspace': wsName,
      'pending': pending,
      'latency_ms': latencyMs,
    };
  }

  /// (دفعة 57 — للمدير فقط) ضغط سجل العمليات السحابي:
  /// يحذف من /workspaces/$ws/operations كل عملية:
  ///   • أقدم من 30 يوماً (بختم خادم فيربيس server_ts)، و
  ///   • مغطاة بلقطة موثّقة (server_ts ≤ snapshotThroughTs المسجلة عند
  ///     آخر createInvite) — المنضمون الجدد يرتوون من اللقطة فلا يحتاجون
  ///     إعادة تشغيل التاريخ القديم.
  /// بدون علامة لقطة مسجلة لا يُحذف شيء (أمان مطلق). يعيد عدد المحذوف.
  Future<int> compactCloudOperations({
    required String backendUrl,
    String workspaceId = 'default',
    Duration olderThan = const Duration(days: 30),
  }) async {
    if (!await repo.isWorkspaceOwner()) return 0;
    final db = await _db;
    final row = await db.query('sync_meta',
        where: 'key = ?',
        whereArgs: ['snapshotThroughTs:$workspaceId'],
        limit: 1);
    final snapTs =
        row.isEmpty ? 0 : (int.tryParse('${row.first['value']}') ?? 0);
    if (snapTs <= 0) return 0; // لا لقطة موثّقة → لا ضغط.
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    // الحد الآمن: الأقدم من (30 يوماً) والمغطى باللقطة معاً.
    final limitTs = snapTs < cutoff ? snapTs : cutoff;
    if (limitTs <= 0) return 0;
    return CloudJoin.compactOperations(
      backendUrl: backendUrl,
      workspaceId: workspaceId,
      throughTsMs: limitTs,
    );
  }

  /// (دفعة 56) «حذف نهائي من السجل»: محو جهاز مطرود محلياً وسحابياً —
  /// devices + مستخدم الظل اليتيم محلياً، وroster/evictions/joinRequest
  /// سحابياً. البطاقة تختفي نهائياً من كل الشاشات.
  Future<void> purgeDeviceRecordEverywhere(String targetDeviceId) async {
    // المحلي أولاً (يرمي عند خرق الشروط: جهاز نشط/مالك) ثم السحابي
    // بأفضل جهد — غياب الشبكة لا يمنع اختفاء البطاقة.
    await repo.purgeDeviceRecord(targetDeviceId);
    try {
      final st = await repo.settings();
      final url = (st['cloudBackendUrl'] ?? '').trim();
      if (url.isNotEmpty) {
        await CloudJoin.purgeDeviceRecordFromCloud(
          backendUrl: url,
          deviceId: targetDeviceId,
          workspaceId: _cloudTransport?.workspaceId ?? 'default',
        );
      }
    } catch (_) {}
    try {
      await broadcastRosterChange();
    } catch (_) {}
  }

  Future<void> broadcastEviction(String targetDeviceId,
      {String reason = 'revoked_by_manager'}) async {
    try {
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = (st['cloudBackendUrl'] ?? '').trim();
      if (url.isEmpty) return;
      final t = _cloudTransport;
      await CloudJoin.purgePeerFromCloud(
        repo,
        backendUrl: url,
        deviceId: targetDeviceId,
        workspaceId: t?.workspaceId ?? 'default',
        reason: reason,
      );
    } catch (_) {
      // الشبكة غائبة — المصافحة الدورية لدى المستهدف تلتقط الطرد لاحقاً
      // عبر roster (الذي سيصله وسم الطرد مع أول مزامنة سجل).
    }
  }

  /// (دفعة 54 — جهة المدير) إعادة السماح لجهاز محظور: حذف شاهدة طرده
  /// من السحابة حتى لا يُقصي الجهازُ المستعاد نفسَه عند فحصه القادم.
  Future<void> clearEvictionBroadcast(String targetDeviceId) async {
    try {
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = (st['cloudBackendUrl'] ?? '').trim();
      if (url.isEmpty) return;
      await CloudJoin.clearEvictionTombstone(
        backendUrl: url,
        deviceId: targetDeviceId,
        workspaceId: _cloudTransport?.workspaceId ?? 'default',
      );
    } catch (_) {}
  }

  Future<void> broadcastRosterChange() async {
    // توحيد الهوية: ادفع سجل الأجهزة فوراً للسحابة أيضاً حتى يظهر الاسم
    // الجديد على كل الأجهزة المرتبطة سحابياً دون انتظار الدورة (45 ثانية).
    try {
      final t = _cloudTransport;
      if (t != null) {
        await CloudJoin.syncRoster(
          repo,
          await _db,
          backendUrl: t.backendUrl,
          workspaceId: t.workspaceId,
        );
      }
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
      // السحابة أولاً: عند نجاح رفع العملية للسحابة تُعلَّم synced=1،
      // فيعتبرها هدف LAN (في نفس الدورة) مُسلَّمة عبر السحابة للأجهزة
      // غير القابلة للوصول محلياً — بدل بقائها awaiting-offline-peers.
      final ordered = List<SyncTransport>.of(_transports)
        ..sort((a, b) {
          if (a.targetId == b.targetId) return 0;
          if (a.targetId == SyncTarget.cloud) return -1;
          if (b.targetId == SyncTarget.cloud) return 1;
          return 0;
        });
      for (final t in ordered) {
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
      // بانر الخطر ظاهر؟ أعد الفحص فور انتهاء الدورة: نجاح الدفع يبثّ
      // null فيختفي البانر لحظياً — لا انتظار لدورة المؤقّت التالية.
      if (_lastDangerMsg.isNotEmpty) {
        try {
          await _checkDangerState();
        } catch (_) {}
      }
    }
  }
}

class SyncSummary {
  final int pending;
  final int failed;
  const SyncSummary({required this.pending, required this.failed});
}
