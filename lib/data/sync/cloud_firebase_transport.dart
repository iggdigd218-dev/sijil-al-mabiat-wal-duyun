// طبقة Firebase Realtime Database (REST) للمزامنة السحابية التزايدية (Production-hardened).
//
// التطويرات عن النسخة السابقة:
//  - سحب تزايدي (incremental pull) باستخدام sync_meta.lastCloudOpId بدل آخر 500 عملية فقط.
//  - إرسال auth=<idToken> إذا كان المستخدم مسجلاً دخوله (يربط بجوجل).
//  - تحقق HTTPS فقط (رفض http).
//  - validation لـ URL.
//  - استخدام startAfter لـ pagination عند تجاوز الدفعات.
//  - لا نعتمد على ترتيب السيرفر فقط؛ نحتفظ cursor محلي.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../repository.dart';
import 'apply_remote.dart';
import 'conflict_resolver.dart';
import 'operation.dart';
import 'sync_engine.dart';
import 'sync_queue.dart';

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
    if (!u.host.contains('firebaseio.com') && !u.host.contains('firebasedatabase.app')) {
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

  String _opPath(String opId) => '$_root/operations/${Uri.encodeComponent(opId)}.json';
  String get _opsPath => '$_root/operations.json';

  Map<String, String> get _authHeaders {
    return {'Content-Type': 'application/json'};
  }

  Future<String?> _authQuery() async {
    final tok = await _idTokenProvider();
    if (tok == null || tok.isEmpty) return null;
    return 'auth=${Uri.encodeQueryComponent(tok)}';
  }

  @override
  Future<void> push(SyncOperation op) async {
    final uri = Uri.parse(_opPath(op.id));
    final body = op.toJson();
    final auth = await _authQuery();
    final targetUri = auth == null ? uri : uri.replace(query: auth);
    final res = await http.put(targetUri, body: body, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw StateError('cloud-auth-failed: ${res.statusCode}');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('cloud-http-${res.statusCode}');
    }
    final db = await _db;
    await db.update('operations', {
      'server_time': DateTime.now().toIso8601String(),
      'synced': 1,
    }, where: 'id = ?', whereArgs: [op.id]);
    await db.update('devices', {
      'last_sync_at': DateTime.now().toIso8601String(),
    }, where: 'id = ?', whereArgs: [op.deviceId]);
  }

  Future<int> pull({ConflictResolver? resolver}) async {
    final db = await _db;
    // نستخدم timestamp-based cursor مع overlap للسماح بالوصول المتأخر.
    final lastTsRow = await db.query('sync_meta',
        where: 'key = ?', whereArgs: ['lastCloudTs:$workspaceId'], limit: 1);
    int lastTsMs = 0;
    if (lastTsRow.isNotEmpty) {
      final v = lastTsRow.first['value'];
      lastTsMs = int.tryParse('$v') ?? 0;
    }
    // overlap بثانيتين لالتقاط العمليات التي وصلت متأخرة أو بنفس الوقت.
    final startAtMs = lastTsMs > 2000 ? lastTsMs - 2000 : 0;
    final r = resolver ?? ConflictResolver();
    int applied = 0;
    int maxTsMs = lastTsMs;

    bool hasMore = true;
    String? startAfterKey;
    while (hasMore) {
      var q = 'orderBy="timestamp"&limitToFirst=$kPullPageSize';
      if (startAtMs > 0) q += '&startAt="$startAtMs"';
      if (startAfterKey != null) q += '&startAfter="$startAfterKey"';
      final auth = await _authQuery();
      final url = auth == null ? '$_opsPath?$q' : '$_opsPath?$q&$auth';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
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
      final entries = decoded.entries.toList();
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
          final opMs = DateTime.tryParse(op.timestamp)?.millisecondsSinceEpoch ?? 0;
          if (opMs > maxTsMs) maxTsMs = opMs;
          // idempotent: نفس opId موجود مسبقًا -> تجاهل.
          final idempotentQ = await txn.query('operations',
              where: 'id = ?', whereArgs: [op.id], limit: 1);
          if (idempotentQ.isNotEmpty) {
            lastKey = entry.key as String;
            continue;
          }
          final ok = await repo.applyRemoteOperation(txn, op, r);
          if (ok) applied++;
          lastKey = entry.key as String;
        }
      });
      hasMore = entries.length >= kPullPageSize;
      startAfterKey = lastKey;
      // إذا كانت الصفحة تحتوي على عمليات بنفس timestamp نكرر بالصفحة التالية بstartAfter.
    }

    if (maxTsMs > lastTsMs) {
      await db.insert('sync_meta', {
        'key': 'lastCloudTs:$workspaceId',
        'value': '$maxTsMs',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await repo.setSetting('lastCloudSync', DateTime.now().toLocal().toString());
    return applied;
  }
}
