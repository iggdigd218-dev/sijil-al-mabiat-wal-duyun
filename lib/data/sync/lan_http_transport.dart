// مزامنة LAN عبر HTTP (Production-hardened):
//  - خادم محلي على port 43053 (قابل للتعديل من الإعدادات).
//  - يقبل فقط الأجهزة المقترنة التي تعرف auth_secret.
//  - تحقق من حجم الـ payload (حد أقصى 1 MB).
//  - تحقق من workspace_id المطابق.
//  - تحقق من is_paired=1 وعدم إلغاء الجهاز (revoked_at فارغ).
//  - التحقق من صحة العملية قبل تطبيقها.
//  - timeout مضبوط، HttpClient مُعاد استخدامه.
//  - لا حزم خارجية — فقط dart:io.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../repository.dart';
import 'apply_remote.dart';
import 'conflict_resolver.dart';
import 'operation.dart';
import 'sync_engine.dart';
import 'sync_queue.dart';
import 'workspace_service.dart';

const int kDefaultLanPort = 43053;
const int kMaxLanPayloadBytes = 1024 * 1024; // 1 MB
const Duration kLanRequestTimeout = Duration(seconds: 5);

class LanDevice {
  final String deviceId;
  final String ipAddress;
  final int port;
  final String name;
  final String? authSecret;
  final DateTime? lastSeenAt;
  const LanDevice({
    required this.deviceId,
    required this.ipAddress,
    required this.port,
    required this.name,
    this.authSecret,
    this.lastSeenAt,
  });
}

class LanPairResult {
  final bool ok;
  final String? ourAuthSecret;
  final String? remoteDeviceId;
  final String? error;
  const LanPairResult({required this.ok, this.ourAuthSecret, this.remoteDeviceId, this.error});
}

class LanSyncService implements SyncTransport {
  final Repo repo;
  final Future<Database> Function() dbProvider;
  final String ourDeviceId;
  final int port;
  HttpServer? _server;
  HttpClient? _client;
  final ConflictResolver _resolver = ConflictResolver();

  LanSyncService({
    required this.repo,
    required this.dbProvider,
    required this.ourDeviceId,
    this.port = kDefaultLanPort,
  });

  @override
  String get targetId => SyncTarget.lanBroadcast;

  // ---------- الخادم المحلي ----------

  Future<void> startServer() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    } catch (_) {
      _server = null;
      return;
    }
    _server!.listen(_handleRequest);
  }

  Future<void> stopServer() async {
    _client?.close(force: true);
    _client = null;
    await _server?.close(force: true);
    _server = null;
  }

  bool get isRunning => _server != null;

  Future<void> _handleRequest(HttpRequest req) async {
    final cors = req.response;
    cors.headers.set('Access-Control-Allow-Origin', '*');
    cors.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    cors.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    if (req.method == 'OPTIONS') {
      await cors.close();
      return;
    }
    try {
      final path = req.uri.path;
      if (path == '/status' && req.method == 'GET') {
        await _handleStatus(cors);
        return;
      }
      if (path == '/pair' && req.method == 'POST') {
        await _handlePairEndpoint(req, cors);
        return;
      }
      if (path == '/ops' && req.method == 'POST') {
        await _handleOps(req, cors);
        return;
      }
      cors.statusCode = HttpStatus.notFound;
      await cors.close();
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(jsonEncode({'ok': false, 'error': 'internal'}));
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleStatus(HttpResponse resp) async {
    try {
      final db = await dbProvider();
      final dev = await db.query('devices', where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      final devName = dev.isNotEmpty ? (dev.first['name'] as String? ?? 'Nexora') : 'Nexora';
      final wsRows = await db.query('workspaces', limit: 1);
      final wsId = wsRows.isNotEmpty ? (wsRows.first['id'] as String) : defaultWorkspaceId;
      resp.headers.contentType = ContentType.json;
      resp.write(jsonEncode({
        'deviceId': ourDeviceId,
        'name': devName,
        'port': port,
        'workspaceId': wsId,
        'version': 'flutter-native',
      }));
    } catch (_) {}
    await resp.close();
  }

  Future<Map<String, Object?>> _readJsonLimited(HttpRequest req) async {
    // حد أقصى للحجم لمنع هجمات الذاكرة.
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > kMaxLanPayloadBytes) {
        throw StateError('payload-too-large');
      }
    }
    if (bytes.isEmpty) return {};
    final text = utf8.decode(bytes, allowMalformed: false);
    final d = jsonDecode(text);
    return d is Map<String, Object?> ? d : {};
  }

  Future<void> _handlePairEndpoint(HttpRequest req, HttpResponse resp) async {
    try {
      final body = await _readJsonLimited(req);
      final ok = await _handlePair(body);
      resp.statusCode = ok.ok ? HttpStatus.ok : HttpStatus.forbidden;
      resp.headers.contentType = ContentType.json;
      resp.write(jsonEncode({
        'ok': ok.ok,
        if (ok.ok) 'authSecret': ok.ourAuthSecret,
        if (!ok.ok) 'error': ok.error,
      }));
    } catch (e) {
      resp.statusCode = HttpStatus.badRequest;
      resp.headers.contentType = ContentType.json;
      resp.write(jsonEncode({'ok': false, 'error': 'invalid'}));
    }
    await resp.close();
  }

  Future<LanPairResult> _handlePair(Map<String, Object?> body) async {
    final tok = (body['token'] as String?) ?? '';
    final devId = (body['deviceId'] as String?) ?? '';
    final ip = (body['ipAddress'] as String?) ?? '';
    final p = body['port'] as int?;
    final name = (body['name'] as String?) ?? 'جهاز';
    final theirSecret = (body['authSecret'] as String?) ?? '';
    if (tok.length < 6 || devId.isEmpty || ip.isEmpty || p == null || theirSecret.isEmpty) {
      return const LanPairResult(ok: false, error: 'bad-request');
    }
    final db = await dbProvider();
    final rec = await db.query('devices',
        where: 'pair_token = ? AND pair_token_exp > ?',
        whereArgs: [tok, DateTime.now().toIso8601String()], limit: 1);
    if (rec.isEmpty) return const LanPairResult(ok: false, error: 'invalid-token');

    final wsId = rec.first['workspace_id'] as String? ?? defaultWorkspaceId;

    // تأكد من وجود سر محلي لنا، وإلا وُلّد واحد.
    final ourDevRows = await db.query('devices', where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
    var ourSecret = (ourDevRows.isNotEmpty ? ourDevRows.first['auth_secret'] as String? : null) ?? '';
    if (ourSecret.isEmpty) {
      ourSecret = generateLanSecret();
      await db.update('devices', {'auth_secret': ourSecret}, where: 'id = ?', whereArgs: [ourDeviceId]);
    }
    final now = DateTime.now().toIso8601String();
    // سجّل الجهاز الجديد مع السر الذي أرسله (سيُستخدم عند الإرسال إليه: هو سيعرف هذا السر كسره الخاص).
    await db.insert('devices', {
      'id': devId,
      'workspace_id': wsId,
      'name': name,
      'platform': 'lan',
      'ip_address': ip,
      'port': p,
      'auth_secret': theirSecret,
      'is_paired': 1,
      'revoked_at': '',
      'last_seen_at': now,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // امسح token بعد الاستخدام (one-time).
    await db.update('devices', {'pair_token': '', 'pair_token_exp': ''},
        where: 'pair_token = ?', whereArgs: [tok]);
    // نُعيد سرّنا للجهاز الآخر كي يخزنه ويُرسله عند الإرسال إلينا.
    return LanPairResult(ok: true, ourAuthSecret: ourSecret, remoteDeviceId: devId);
  }

  Future<void> _handleOps(HttpRequest req, HttpResponse resp) async {
    int applied = 0;
    String? error;
    int statusCode = HttpStatus.ok;
    try {
      // 1) قراءة الـ auth من Header.
      final auth = req.headers.value('Authorization') ?? '';
      final secret = auth.startsWith('Bearer ') ? auth.substring(7) : auth;
      if (secret.isEmpty) {
        statusCode = HttpStatus.unauthorized;
        error = 'auth-required';
        return;
      }
      final body = await _readJsonLimited(req);
      final op = SyncOperation.fromMap(Map<String, Object?>.from(body));

      // 2) تحقق من صلاحيات الجهاز المرسل.
      final db = await dbProvider();
      final senderRows = await db.query('devices',
          where: 'id = ? AND is_paired = 1 AND COALESCE(revoked_at, "") = "" AND auth_secret = ?',
          whereArgs: [op.deviceId, secret], limit: 1);
      if (senderRows.isEmpty) {
        statusCode = HttpStatus.forbidden;
        error = 'device-not-authorized';
        return;
      }
      // 3) تحقق من workspaceId المطابق.
      final wsRows = await db.query('workspaces', limit: 1);
      final localWsId = wsRows.isNotEmpty ? (wsRows.first['id'] as String) : defaultWorkspaceId;
      if (op.workspaceId != localWsId) {
        statusCode = HttpStatus.forbidden;
        error = 'workspace-mismatch';
        return;
      }
      // 4) منع الحلقات: نفس الجهاز.
      if (op.deviceId == ourDeviceId) {
        statusCode = HttpStatus.ok;
        error = null;
        return;
      }
      // 5) تحقق من الحقول الأساسية للعملية (schema validation).
      if (op.entityId.isEmpty || op.id.isEmpty || op.payload.isEmpty) {
        statusCode = HttpStatus.badRequest;
        error = 'invalid-op';
        return;
      }

      await db.transaction((txn) async {
        final ok = await repo.applyRemoteOperation(txn, op, _resolver);
        if (ok) applied++;
        await txn.insert('sync_queue', {
          'operation_id': op.id,
          'status': SyncStatus.synced.name,
          'target': SyncTarget.lanBroadcast,
          'attempts': 0,
          'last_error': '',
          'next_try_at': '',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });
      await repo.setSetting('lastLanSync', DateTime.now().toLocal().toString());
      // تحديث last_seen للمرسل.
      await db.update('devices', {
        'last_seen_at': DateTime.now().toIso8601String(),
        'ip_address': (req.connectionInfo?.remoteAddress.address) ?? senderRows.first['ip_address'],
      }, where: 'id = ?', whereArgs: [op.deviceId]);
    } on StateError catch (e) {
      error = e.message;
      statusCode = HttpStatus.requestEntityTooLarge;
    } catch (e) {
      error = 'internal';
      statusCode = HttpStatus.internalServerError;
    } finally {
      resp.statusCode = statusCode;
      resp.headers.contentType = ContentType.json;
      resp.write(jsonEncode({'ok': error == null, 'applied': applied, 'error': error}));
      await resp.close();
    }
  }

  // ---------- العميل (إرسال للأجهزة المقترنة) ----------

  HttpClient get _httpClient {
    return _client ??= HttpClient()..connectionTimeout = kLanRequestTimeout;
  }

  @override
  Future<void> push(SyncOperation op) async {
    final db = await dbProvider();
    final devices = await db.query('devices',
        where: "is_paired = 1 AND COALESCE(revoked_at, '') = '' AND ip_address <> '' AND id <> ? AND auth_secret <> ''",
        whereArgs: [ourDeviceId]);
    final errors = <String>[];
    for (final d in devices) {
      final ip = d['ip_address'] as String?;
      final p = d['port'] as int?;
      final devId = d['id'] as String;
      final secret = d['auth_secret'] as String? ?? '';
      if (ip == null || ip.isEmpty || p == null || secret.isEmpty) continue;
      try {
        final req = await _httpClient.postUrl(Uri.parse('http://$ip:$p/ops'));
        req.headers.contentType = ContentType.json;
        req.headers.set('Authorization', 'Bearer $secret');
        req.write(op.toJson());
        final resp = await req.close().timeout(const Duration(seconds: 5));
        final body = await resp.timeout(const Duration(seconds: 3)).transform(utf8.decoder).join();
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          String errMsg = 'HTTP ${resp.statusCode}';
          try {
            final m = jsonDecode(body) as Map;
            errMsg = '${m['error'] ?? errMsg}';
          } catch (_) {}
          errors.add('$devId: $errMsg');
          if (resp.statusCode == HttpStatus.forbidden || resp.statusCode == HttpStatus.unauthorized) {
            // الجهاز لم يتعرف علينا — نعلمه كـ revoked? لا، نكتفي بالتسجيل.
          }
        }
        await db.update('devices', {
          'last_seen_at': DateTime.now().toIso8601String(),
        }, where: 'id = ?', whereArgs: [devId]);
      } catch (e) {
        errors.add('$devId: $e');
      }
    }
    if (errors.isNotEmpty) {
      throw StateError(errors.join('; '));
    }
  }

  /// يرسل طلب pairing وإن نجح يسجل الخصم.
  Future<LanPairResult> pairWith(String ip, int port, String token) async {
    try {
      final db = await dbProvider();
      final localDev = await db.query('devices', where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      final name = localDev.isNotEmpty ? (localDev.first['name'] as String? ?? 'Nexora') : 'Nexora';
      // وُلّد سرنا إن لم يكن موجودًا، ثم أرسله للجهاز الآخر ليخزنه كسر لإرساله إلينا.
      var ourSecret = (localDev.isNotEmpty ? localDev.first['auth_secret'] as String? : null) ?? '';
      if (ourSecret.isEmpty) {
        ourSecret = generateLanSecret();
        await db.update('devices', {'auth_secret': ourSecret}, where: 'id = ?', whereArgs: [ourDeviceId]);
      }
      final req = await _httpClient.postUrl(Uri.parse('http://$ip:$port/pair'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'token': token,
        'deviceId': ourDeviceId,
        'ipAddress': await _localIp() ?? '',
        'port': port,
        'name': name,
        'authSecret': ourSecret,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final bodyText = await resp.timeout(const Duration(seconds: 3)).transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        return LanPairResult(ok: false, error: 'HTTP ${resp.statusCode}');
      }
      final m = jsonDecode(bodyText) as Map;
      final ok = m['ok'] == true;
      if (!ok) return LanPairResult(ok: false, error: '${m['error'] ?? 'failed'}');
      final remoteSecret = (m['authSecret'] as String?) ?? '';
      if (remoteSecret.isEmpty) return const LanPairResult(ok: false, error: 'no-secret');
      // سجّل الجهاز الآخر مع سرّه.
      // لاحظ: الجهاز الآخر قد لا يعرف بعد deviceId/name/ip لنا قبل أن نكمل الاقتران،
      // لكنه سجّلنا بالفعل في _handlePair عنده (وولّد لنا سر ourSecret).
      final devId = m['deviceId'] as String? ?? '';
      final now = DateTime.now().toIso8601String();
      if (devId.isNotEmpty) {
        await db.insert('devices', {
          'id': devId,
          'workspace_id': defaultWorkspaceId,
          'name': 'جهاز بعيد',
          'platform': 'lan',
          'ip_address': ip,
          'port': port,
          'auth_secret': remoteSecret,
          'is_paired': 1,
          'revoked_at': '',
          'last_seen_at': now,
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      return LanPairResult(ok: true, remoteDeviceId: devId.isEmpty ? null : devId);
    } catch (e) {
      return LanPairResult(ok: false, error: '$e');
    }
  }

  Future<String?> _localIp() async {
    try {
      for (final iface in await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4)) {
        for (final a in iface.addresses) {
          if (!a.isLoopback && a.type == InternetAddressType.IPv4) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
