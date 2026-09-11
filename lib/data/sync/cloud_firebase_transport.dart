// طبقة Firebase Realtime Database (REST) للمزامنة السحابية التزايدية (Production-hardened).
//
// التطويرات عن النسخة السابقة:
//  - سحب تزايدي (incremental pull) باستخدام sync_meta.lastCloudOpId بدل آخر 500 عملية فقط.
//  - إرسال auth=<idToken> إذا كان المستخدم مسجلاً دخوله (يربط بجوجل).
//  - تحقق HTTPS فقط (رفض http).
//  - validation لـ URL.
//  - استخدام startAfter لـ pagination عند تجاوز الدفعات.
//  - لا نعتمد على ترتيب السيرفر فقط؛ نحتفظ cursor محلي.
//  - استماع فوري SSE: قناة مفتوحة تُخطرنا لحظة وصول أي عملية جديدة
//    (المزامنة تصبح شبه فورية بدل انتظار السحب الدوري).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/desktop_net.dart';
import '../repository.dart';
import 'apply_remote.dart';
import 'cloud_join.dart';
import 'conflict_resolver.dart';
import 'device_id.dart';
import 'lan_http_transport.dart';
import 'operation.dart';
import 'sync_engine.dart';

class CloudFirebaseTransport implements SyncTransport {
  final Repo repo;
  final String backendUrl;
  final String workspaceId;
  final Future<Database> Function() _dbProvider;
  final Future<String?> Function() _idTokenProvider;
  static const int kPullPageSize = 500;

  CloudFirebaseTransport({
    required this.repo,
    required Future<Database> Function() dbProvider,
    required this.backendUrl,
    required this.workspaceId,
    Future<String?> Function()? idTokenProvider,
  })  : _dbProvider = dbProvider,
        _idTokenProvider = idTokenProvider ?? (() async => null);

  factory CloudFirebaseTransport.validated({
    required Repo repo,
    required Future<Database> Function() dbProvider,
    required String backendUrl,
    required String workspaceId,
    Future<String?> Function()? idTokenProvider,
  }) {
    final trimmed = backendUrl.trim();
    if (trimmed.isEmpty) throw ArgumentError('backendUrl فارغ');
    final u = Uri.tryParse(trimmed);
    if (u == null || !u.hasScheme || !u.isScheme('https')) {
      throw ArgumentError('رابط Firebase يجب أن يبدأ بـ https://');
    }
    if (!u.host.contains('firebaseio.com') &&
        !u.host.contains('firebasedatabase.app')) {
      // نقبل أيضًا روابط مخصصة ولكن مع تحذير ضمني — نسمح لمرونة التطوير.
    }
    return CloudFirebaseTransport(
      repo: repo,
      dbProvider: dbProvider,
      backendUrl: trimmed,
      workspaceId: workspaceId,
      idTokenProvider: idTokenProvider,
    );
  }

  Future<Database> get _db => _dbProvider();

  @override
  String get targetId => SyncTarget.cloud;

  String get _root =>
      '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';

  String _opPath(String opId) =>
      '$_root/operations/${Uri.encodeComponent(opId)}.json';
  String get _opsPath => '$_root/operations.json';

  Map<String, String> get _authHeaders {
    return {'Content-Type': 'application/json'};
  }

  Future<String?> _authQuery() async {
    final tok = await _idToken();
    if (tok == null) return null;
    return 'auth=${Uri.encodeQueryComponent(tok)}';
  }

  Future<String?> _idToken() async {
    final tok = await _idTokenProvider();
    if (tok == null || tok.isEmpty) return null;
    return tok;
  }

  @override
  Future<void> push(SyncOperation op) async {
    // (دفعة 53) جهاز مطرود لا يدفع شيئاً للسحابة — إيقاف صامت فوري.
    if (_evicted) throw StateError('device-evicted');
    final uri = Uri.parse(_opPath(op.id));
    // ختم وقت الخادم: فيربيس يستبدل {".sv":"timestamp"} بوقت خادمه (ملي
    // ثانية) لحظة الكتابة — يقضي على ثغرة انحراف ساعات الأجهزة التي كانت
    // تُسقط عمليات جهازٍ ساعتُه متأخرة عن مؤشر السحب لدى الآخرين.
    final bodyMap = Map<String, Object?>.from(
        jsonDecode(op.toJson()) as Map)
      ..['server_ts'] = {'.sv': 'timestamp'};
    final body = jsonEncode(bodyMap);
    final auth = await _authQuery();
    final targetUri = auth == null ? uri : uri.replace(query: auth);
    var res = await http
        .put(targetUri, body: body, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if ((res.statusCode == 401 || res.statusCode == 403) && auth != null) {
      // idToken من Google تنتهي صلاحيته بعد ~ساعة؛ إن كانت قواعد القاعدة
      // عامة فإرسال توكن منتهٍ يفشل الطلب بلا داعٍ — نعيد المحاولة بدونه.
      res = await http
          .put(uri, body: body, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw StateError('cloud-auth-failed: ${res.statusCode}');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('cloud-http-${res.statusCode}');
    }
    final db = await _db;
    await db.update(
      'operations',
      {'server_time': DateTime.now().toIso8601String(), 'synced': 1},
      where: 'id = ?',
      whereArgs: [op.id],
    );
    await db.update(
      'devices',
      {'last_sync_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [op.deviceId],
    );
  }

  // ==================== المصافحة النشطة للسجل (دفعة 53) ====================
  // الجهاز يتحقق بنفسه من عضويته في /roster/$deviceId — الطرد يُكتشف حتى
  // لو حُذفت عقدته نهائياً (وليس فقط عند وسمها revoked/expelled).

  /// يُستدعى عند اكتشاف أن هذا الجهاز طُرد/حُذف من سجل المجموعة.
  void Function()? onEvicted;

  bool _evicted = false;
  DateTime? _lastEvictionCheck;

  bool get isEvicted => _evicted;

  /// فحص العضوية الذاتي (مخنوق: مرة كل 20 ثانية كحد أقصى):
  /// - وضع member فقط (المالك والمستقل لا يُطردان ذاتياً).
  /// - عقدة موجودة بحقول نظيفة → سليم + وسم rosterSeenSelf.
  /// - revoked=true أو revoked_at/expelled_at غير فارغة → طرد.
  /// - عقدة null (حُذفت): طرد فقط إن سبق أن رأينا أنفسنا في السجل —
  ///   حارس ضد الإيجابيات الكاذبة (سجل لم يُملأ بعد/انضمام قديم).
  /// - أخطاء الشبكة/رموز غير 200 لا تُحسب طرداً أبداً.
  Future<void> maybeCheckSelfEviction({bool force = false}) async {
    if (_evicted) return;
    final now = DateTime.now();
    if (!force &&
        _lastEvictionCheck != null &&
        now.difference(_lastEvictionCheck!) < const Duration(seconds: 20)) {
      return;
    }
    _lastEvictionCheck = now;
    try {
      final mode = await repo.workspaceMode();
      if (mode != 'member') return;
      final st = await repo.settings();
      // (دفعة 56) حارس إعادة الربط: أثناء انتظار موافقة المدير أو قبل
      // إتمام التهيئة لا نفحص الطرد إطلاقاً — شاهدة قديمة من طردٍ سابق
      // قد تكون ما تزال موجودة لحظة إعادة الربط، وفحصها قبل اكتمال
      // الموافقة (التي تحذفها) يُدخل الجهاز حلقة طرد ذاتي أبدية.
      if ((st['pendingJoin.token'] ?? '').trim().isNotEmpty) return;
      final devId = (st['sync.deviceId'] ?? '').trim();
      if (devId.isEmpty) return;
      // (دفعة 54) الشاهدة الصريحة أولاً: وجود /evictions/$devId = طرد
      // قاطع فوري — لا يحتاج أي حارس (المدير كتبها قصداً).
      try {
        final tomb = await CloudJoin.hasEvictionTombstone(
          backendUrl: backendUrl,
          deviceId: devId,
          workspaceId: workspaceId,
        );
        if (tomb) {
          _fireEvicted();
          return;
        }
      } catch (_) {
        // شبكة — نسقط لفحص الـroster المعتاد.
      }
      final tok = await _idToken();
      final uri = Uri.parse(
              '$_root/roster/${Uri.encodeComponent(devId)}.json')
          .replace(queryParameters: {if (tok != null) 'auth': tok});
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return; // خطأ خادم/صلاحية — لا حكم.
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') {
        // العقدة محذوفة كلياً — طرد إن كنا مسجلين سابقاً.
        if ((st['sync.rosterSeenSelf'] ?? '') == '1') _fireEvicted();
        return;
      }
      final m = jsonDecode(body);
      if (m is! Map) return;
      // رأينا سجلنا — فعّل حارس الحذف للمستقبل.
      if ((st['sync.rosterSeenSelf'] ?? '') != '1') {
        await repo.setSetting('sync.rosterSeenSelf', '1');
      }
      final revoked = m['revoked'] == true ||
          '${m['revoked_at'] ?? ''}'.trim().isNotEmpty;
      final expelled = '${m['expelled_at'] ?? ''}'.trim().isNotEmpty;
      if (revoked || expelled) _fireEvicted();
    } catch (_) {
      // شبكة متقطعة — الفحص القادم يغطي.
    }
  }

  void _fireEvicted() {
    if (_evicted) return;
    _evicted = true;
    try {
      onEvicted?.call();
    } catch (_) {}
  }

  Future<int> pull({ConflictResolver? resolver}) async {
    // (دفعة 53) مصافحة العضوية قبل أي سحب: جهاز مطرود يوقف كل شيء فوراً.
    await maybeCheckSelfEviction();
    if (_evicted) return 0;
    final db = await _db;
    // نستخدم timestamp-based cursor مع overlap للسماح بالوصول المتأخر.
    final lastTsRow = await db.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['lastCloudTs:$workspaceId'],
      limit: 1,
    );
    int lastTsMs = 0;
    if (lastTsRow.isNotEmpty) {
      final v = '${lastTsRow.first['value']}';
      // القيمة المخزّنة قد تكون ISO (الشكل الجديد) أو ميلي ثانية (قواعد قديمة).
      lastTsMs = DateTime.tryParse(v)?.millisecondsSinceEpoch ??
          (int.tryParse(v) ?? 0);
    }
    // overlap بثانيتين لالتقاط العمليات التي كُتبت أثناء سحبنا السابق.
    // المؤشر و startAt كلاهما بتوقيت خادم فيربيس (server_ts) — لا اعتماد
    // على ساعات الهواتف النصية (ISO) إطلاقاً، فجهاز ساعته متأخرة دقائق
    // لن تسقط عملياته من سحب بقية الأجهزة (Clock Drift).
    final startAtMs = lastTsMs > 2000 ? lastTsMs - 2000 : 0;
    final r = resolver ?? ConflictResolver();
    int applied = 0;
    int maxTsMs = lastTsMs;
    final ourId = await ensureDeviceId(repo);
    // رسائل دردشة وصلت في هذه السحبة — تُشعر بعد إغلاق المعاملة.
    final chatOps = <SyncOperation>[];

    bool hasMore = true;
    String? startAfterKey;
    while (hasMore) {
      final params = <String, String>{
        // الترشيح بختم الخادم الرقمي (server_ts) وليس timestamp النصي:
        // فيربيس يكتب server_ts بساعته هو عند الرفع، فالمؤشر محصّن ضد
        // انحراف ساعات الأجهزة كلياً.
        'orderBy': jsonEncode('server_ts'),
        'limitToFirst': '$kPullPageSize',
        if (startAtMs > 0) 'startAt': '$startAtMs',
        if (startAfterKey != null) 'startAfter': jsonEncode(startAfterKey),
      };
      final tok = await _idToken();
      if (tok != null) params['auth'] = tok;
      final uri = Uri.parse(_opsPath).replace(queryParameters: params);
      var res = await http.get(uri).timeout(const Duration(seconds: 15));
      if ((res.statusCode == 401 || res.statusCode == 403) && tok != null) {
        // التوكن منتهي الصلاحية وقاعدة عامة؟ جرّب بدون auth قبل الفشل.
        params.remove('auth');
        final bare = Uri.parse(_opsPath).replace(queryParameters: params);
        res = await http.get(bare).timeout(const Duration(seconds: 15));
      }
      // قواعد RTDB بلا فهرس ".indexOn": "timestamp" → فيربيس يرفض orderBy
      // بخطأ 400 فيفشل السحب للأبد رغم نجاح الدفع (البيانات تصعد ولا تنزل
      // أبداً — أخطر عطل صامت). الحل: جلب كامل بلا orderBy والفرز/الترشيح
      // محلياً. يعمل على القواعد الافتراضية دون أي إعداد من المستخدم.
      var serverFiltered = true;
      if (res.statusCode == 400 &&
          res.body.contains('Index not defined')) {
        serverFiltered = false;
        final bareParams = <String, String>{if (tok != null) 'auth': tok};
        final bareUri = Uri.parse(_opsPath).replace(
            queryParameters: bareParams.isEmpty ? null : bareParams);
        res = await http.get(bareUri).timeout(const Duration(seconds: 30));
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw StateError('cloud-auth-failed');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('cloud-http-${res.statusCode}');
      }
      if (res.body.trim().isEmpty || res.body.trim() == 'null') {
        hasMore = false;
        break;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded.isEmpty) {
        hasMore = false;
        break;
      }
      var entries = decoded.entries.toList();
      // وقت العملية للمؤشر/الترشيح: نفضّل server_ts (ختم خادم فيربيس،
      // محصّن ضد انحراف ساعات الأجهزة) ونعود لـ timestamp للعمليات القديمة.
      int entryMs(Object? v) {
        if (v is! Map) return 0;
        final sv = v['server_ts'];
        if (sv is int && sv > 0) return sv;
        if (sv is num && sv > 0) return sv.toInt();
        return DateTime.tryParse('${v['timestamp'] ?? ''}')
                ?.millisecondsSinceEpoch ??
            0;
      }

      // في وضع الجلب الكامل (بلا فهرس خادم): رشّح محلياً بنفس شرط startAt
      // حتى لا نعيد معالجة تاريخ كامل في كل دورة (idempotent على أي حال).
      if (!serverFiltered && startAtMs > 0) {
        entries = entries.where((e) => entryMs(e.value) >= startAtMs).toList();
      }
      // فرز محلي حسب ختم الخادم (server_ts) ثم opId لضمان الترتيب —
      // ساعة الخادم مصدر الحقيقة الوحيد، لا ساعات الأجهزة.
      entries.sort((a, b) {
        final va = a.value;
        final vb = b.value;
        if (va is! Map || vb is! Map) return 0;
        final c = entryMs(va).compareTo(entryMs(vb));
        return c != 0 ? c : (a.key as String).compareTo(b.key as String);
      });
      String? lastKey;
      await db.transaction((txn) async {
        for (final entry in entries) {
          final v = entry.value;
          if (v is! Map) continue;
          final op = SyncOperation.fromMap(Map<String, Object?>.from(v));
          if (op.workspaceId != workspaceId) continue;
          // المؤشر يتقدم دائماً بـ server_ts (ختم خادم فيربيس الموثوق) —
          // في الحالتين (ترشيح خادمي بـ orderBy=server_ts أو جلب كامل).
          // العمليات القديمة جداً بلا server_ts تسقط لـ timestamp كاحتياط.
          final opMs = entryMs(v);
          if (opMs > maxTsMs) maxTsMs = opMs;
          // idempotent: نفس opId موجود مسبقًا -> تجاهل.
          final idempotentQ = await txn.query(
            'operations',
            where: 'id = ?',
            whereArgs: [op.id],
            limit: 1,
          );
          if (idempotentQ.isNotEmpty) {
            lastKey = entry.key as String;
            continue;
          }
          final ok = await repo.applyRemoteOperation(txn, op, r);
          if (ok) applied++;
          if (ok &&
              op.entityType == EntityKind.message &&
              op.deviceId != ourId) {
            chatOps.add(op);
          }
          lastKey = entry.key as String;
        }
      });
      // إشعار وصول رسائل دردشة جماعية عبر السحابة (نفس سلوك LAN):
      // خارج المعاملة، وبعد نجاح التطبيق فقط.
      for (final op in chatOps) {
        try {
          final senderRows = await db.query('devices',
              where: 'id = ?', whereArgs: [op.deviceId], limit: 1);
          // الاسم الموحد: الافتراضي «مستخدم جديد» حتى يسميه المدير.
          var senderName = senderRows.isNotEmpty
              ? ((senderRows.first['name'] as String?) ?? '')
              : '';
          if (senderName.trim().isEmpty) senderName = kDefaultMemberName;
          var body = '${op.payload['body'] ?? ''}';
          if (body.isEmpty) {
            body = switch ('${op.payload['kind'] ?? 'text'}') {
              'image' => '📷 صورة',
              'video' => '🎬 فيديو',
              'audio' => '🎙️ رسالة صوتية',
              'file' => '📎 ملف',
              _ => '',
            };
          }
          if (body.isNotEmpty) {
            LanSyncService.onChatMessage?.call(senderName, body);
          }
        } catch (_) {}
      }
      chatOps.clear();
      // وضع الجلب الكامل يعيد كل شيء في طلب واحد — لا صفحات تالية.
      hasMore = serverFiltered && entries.length >= kPullPageSize;
      startAfterKey = lastKey;
      // إذا كانت الصفحة تحتوي على عمليات بنفس timestamp نكرر بالصفحة التالية بstartAfter.
    }

    if (maxTsMs > lastTsMs) {
      // المؤشر يُخزَّن كملي ثانية خادم (رقم) — الشكل القياسي الجديد.
      // القارئ أعلاه يقبل الرقم و ISO القديم معاً (توافق خلفي).
      await db.insert(
          'sync_meta',
          {
            'key': 'lastCloudTs:$workspaceId',
            'value': '$maxTsMs',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await repo.setSetting('lastCloudSync', DateTime.now().toLocal().toString());
    return applied;
  }

  // ==================== الاستماع الفوري (SSE) ====================

  HttpClient? _sseClient;
  bool _listening = false;
  int _sseRetrySeconds = 2;

  /// يُستدعى عند وصول إشعار بتغيير في السحابة — يشغّل pull فوراً.
  void Function()? onCloudChanged;

  bool get isListening => _listening;

  /// يفتح قناة SSE على مسار العمليات: فيربيس يرسل حدث `put`/`patch`
  /// لحظة كتابة أي جهاز عملية جديدة، فنستدعي onCloudChanged (الذي يشغّل
  /// pull تزايدياً). القناة تعيد الاتصال تلقائياً بتراجع أسّي عند الانقطاع.
  Future<void> startListening() async {
    if (_listening) return;
    _listening = true;
    _sseRetrySeconds = 2;
    // (دفعة 52) اعتماد مضيف الواجهة الخلفية كموثوق لدى طبقة تشخيص TLS
    // (يُقبل رغم فشل التحقق في شبكات تفتيش TLS — الباقي يُرفض دائماً).
    try {
      DesktopNet.trustedHost = Uri.parse(backendUrl).host;
    } catch (_) {}
    unawaited(_sseLoop());
    // (دفعة 54) قناة ثانية خفيفة على شاهدة الطرد الخاصة بنا —
    // المدير يكتبها فيصلنا الطرد لحظياً حتى لو لم تصل أي عملية.
    unawaited(_evictionSseLoop());
  }

  Future<void> stopListening() async {
    _listening = false;
    try {
      _sseClient?.close(force: true);
    } catch (_) {}
    _sseClient = null;
    try {
      _evictionSseClient?.close(force: true);
    } catch (_) {}
    _evictionSseClient = null;
  }

  // ==================== مستمع شاهدة الطرد (دفعة 54) ====================

  HttpClient? _evictionSseClient;
  int _evictionRetrySeconds = 4;

  /// قناة SSE مخصصة على /evictions/$myDeviceId: أول حدث put قد يحمل
  /// شاهدة موجودة أصلاً (اللقطة الأولية)، وأي put لاحق ببيانات غير null
  /// يعني أن المدير طردنا الآن — الإبطال يُطلق في الحالتين.
  /// وضع غير member يُنهي القناة فوراً (المالك/المستقل لا يُطردان).
  Future<void> _evictionSseLoop() async {
    while (_listening && !_evicted) {
      try {
        final mode = await repo.workspaceMode();
        if (mode != 'member') return;
        final st = await repo.settings();
        // (دفعة 56) لا استماع للطرد أثناء انتظار موافقة إعادة الربط —
        // شاهدة قديمة قد تبقى حتى تحذفها موافقة المدير.
        if ((st['pendingJoin.token'] ?? '').trim().isNotEmpty) {
          await Future<void>.delayed(const Duration(seconds: 10));
          continue;
        }
        final devId = (st['sync.deviceId'] ?? '').trim();
        if (devId.isEmpty) return;
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _evictionSseClient = client;
        final tok = await _idToken();
        final uri = Uri.parse(
                '$_root/evictions/${Uri.encodeComponent(devId)}.json')
            .replace(queryParameters: {if (tok != null) 'auth': tok});
        final req = await client.getUrl(uri);
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Cache-Control', 'no-cache');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw StateError('eviction-sse-http-${resp.statusCode}');
        }
        _evictionRetrySeconds = 4;
        String? eventName;
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_listening || _evicted) break;
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventName == 'put' || eventName == 'patch') {
              // صيغة فيربيس: data: {"path":"/","data":<payload>}
              final raw = line.substring(5).trim();
              try {
                final m = jsonDecode(raw);
                if (m is Map && m['data'] != null) {
                  // شاهدة طرد موجودة/كُتبت الآن — إبطال فوري.
                  _fireEvicted();
                  return;
                }
              } catch (_) {}
            } else if (eventName == 'auth_revoked') {
              break; // أعد الاتصال بتوكن جديد.
            }
          }
        }
      } catch (_) {
        // شبكة — إعادة المحاولة بتراجع.
      } finally {
        try {
          _evictionSseClient?.close(force: true);
        } catch (_) {}
        _evictionSseClient = null;
      }
      if (!_listening || _evicted) break;
      await Future<void>.delayed(Duration(seconds: _evictionRetrySeconds));
      _evictionRetrySeconds = (_evictionRetrySeconds * 2).clamp(4, 180);
    }
  }

  Future<void> _sseLoop() async {
    while (_listening) {
      try {
        // (دفعة 53) مصافحة العضوية عند كل تمهيد للقناة: جهاز مطرود
        // يُجهض البث فوراً ولا يفتح القناة إطلاقاً.
        await maybeCheckSelfEviction(force: true);
        if (_evicted) {
          _listening = false;
          break;
        }
        // (دفعة 52) فحص وصول سريع قبل فتح القناة: استعلام DNS للمضيف —
        // يكشف انقطاع الإنترنت/حجب جدار الحماية فوراً برسالة دقيقة
        // بدل تعليق ثم فشل صامت.
        final host = Uri.parse(backendUrl).host;
        final pre = await DesktopNet.preflight(host);
        if (pre != null) throw SocketException('preflight: $pre');
        // ملاحظة: HttpClient هنا يرث DesktopHttpOverrides العالمية على
        // سطح المكتب (بروكسي بيئة + مهلات + تشخيص شهادات TLS).
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _sseClient = client;
        final tok = await _idToken();
        // نستمع على مؤشر خفيف (limitToLast=1 مرتب بالمفتاح) — يكفي كجرس
        // إنذار، والسحب الفعلي يمر عبر pull التزايدي المعتاد.
        final params = <String, String>{
          'orderBy': jsonEncode(r'$key'),
          'limitToLast': '1',
          if (tok != null) 'auth': tok,
        };
        final uri = Uri.parse(_opsPath).replace(queryParameters: params);
        final req = await client.getUrl(uri);
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Cache-Control', 'no-cache');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw StateError('sse-http-${resp.statusCode}');
        }
        _sseRetrySeconds = 2; // الاتصال نجح — صفّر التراجع.
        DesktopNet.clearError(); // الشبكة سليمة — امسح أي خطأ معروض.
        String? eventName;
        var skippedInitial = false;
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_listening) break;
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventName == 'put' || eventName == 'patch') {
              // أول حدث put هو اللقطة الأولية عند فتح القناة — نتجاهله
              // (السحب الدوري/الافتتاحي يغطيه) ونتفاعل مع ما بعده فقط.
              if (!skippedInitial && eventName == 'put') {
                skippedInitial = true;
              } else {
                try {
                  onCloudChanged?.call();
                } catch (_) {}
              }
            } else if (eventName == 'auth_revoked') {
              break; // أعد الاتصال بتوكن جديد.
            }
          }
        }
      } catch (e) {
        // انقطاع شبكة/خادم — سنعيد المحاولة بعد المهلة، مع تسجيل
        // الخطأ الدقيق (SocketException/HandshakeException/مهلة...)
        // ليُعرض في واجهة المزامنة بدل الفشل الصامت.
        DesktopNet.recordError(e);
      } finally {
        try {
          _sseClient?.close(force: true);
        } catch (_) {}
        _sseClient = null;
      }
      if (!_listening) break;
      await Future<void>.delayed(Duration(seconds: _sseRetrySeconds));
      // تراجع أسّي حتى دقيقتين كحد أقصى.
      _sseRetrySeconds = (_sseRetrySeconds * 2).clamp(2, 120);
    }
  }
}
