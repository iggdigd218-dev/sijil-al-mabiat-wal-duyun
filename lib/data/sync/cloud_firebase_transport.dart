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

import '../repository.dart';
import 'apply_remote.dart';
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
    final uri = Uri.parse(_opPath(op.id));
    final body = op.toJson();
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

  Future<int> pull({ConflictResolver? resolver}) async {
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
    // overlap بثانيتين لالتقاط العمليات التي وصلت متأخرة أو بنفس الوقت.
    final startAtMs = lastTsMs > 2000 ? lastTsMs - 2000 : 0;
    // مهم: عمود timestamp مخزّن كنص ISO في Firebase، لذلك يجب أن يكون
    // startAt نصًا ISO أيضًا وإلا لن يطابق أي عملية (مقارنة نصية).
    final startAtIso =
        DateTime.fromMillisecondsSinceEpoch(startAtMs).toIso8601String();
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
        'orderBy': jsonEncode('timestamp'),
        'limitToFirst': '$kPullPageSize',
        if (startAtMs > 0) 'startAt': jsonEncode(startAtIso),
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
      // في وضع الجلب الكامل (بلا فهرس خادم): رشّح محلياً بنفس شرط startAt
      // حتى لا نعيد معالجة تاريخ كامل في كل دورة (idempotent على أي حال).
      if (!serverFiltered && startAtMs > 0) {
        entries = entries.where((e) {
          final v = e.value;
          if (v is! Map) return false;
          final ts = DateTime.tryParse('${v['timestamp'] ?? ''}')
                  ?.millisecondsSinceEpoch ??
              0;
          return ts >= startAtMs;
        }).toList();
      }
      // فرز محلي حسب timestamp ثم opId لضمان الترتيب.
      entries.sort((a, b) {
        final va = a.value;
        final vb = b.value;
        if (va is! Map || vb is! Map) return 0;
        final ta = (va['timestamp'] as String? ?? '');
        final tb = (vb['timestamp'] as String? ?? '');
        final c = ta.compareTo(tb);
        return c != 0 ? c : (a.key as String).compareTo(b.key as String);
      });
      String? lastKey;
      await db.transaction((txn) async {
        for (final entry in entries) {
          final v = entry.value;
          if (v is! Map) continue;
          final op = SyncOperation.fromMap(Map<String, Object?>.from(v));
          if (op.workspaceId != workspaceId) continue;
          // parse timestamp لمللي ثانية.
          final opMs =
              DateTime.tryParse(op.timestamp)?.millisecondsSinceEpoch ?? 0;
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
          final senderName = senderRows.isNotEmpty
              ? ((senderRows.first['name'] as String?) ?? 'جهاز في المجموعة')
              : 'جهاز في المجموعة';
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
      await db.insert(
          'sync_meta',
          {
            'key': 'lastCloudTs:$workspaceId',
            'value':
                DateTime.fromMillisecondsSinceEpoch(maxTsMs).toIso8601String(),
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
    unawaited(_sseLoop());
  }

  Future<void> stopListening() async {
    _listening = false;
    try {
      _sseClient?.close(force: true);
    } catch (_) {}
    _sseClient = null;
  }

  Future<void> _sseLoop() async {
    while (_listening) {
      try {
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
      } catch (_) {
        // انقطاع شبكة/خادم — سنعيد المحاولة بعد المهلة.
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
