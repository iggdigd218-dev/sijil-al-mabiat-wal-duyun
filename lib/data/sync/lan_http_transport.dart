// مزامنة LAN عبر HTTP:
//  - خادم محلي يستمع على port 43053 يستقبل العمليات من الأجهزة الأخرى على نفس الشبكة.
//  - عميل يرسل العمليات المعلقة لأجهزة مقترنة معروفة.
// لا نستخدم أي حزم خارجية — فقط dart:io.
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

const int kDefaultLanPort = 43053;

class LanDevice {
  final String deviceId;
  final String ipAddress;
  final int port;
  final String name;
  final DateTime? lastSeenAt;
  const LanDevice({
    required this.deviceId,
    required this.ipAddress,
    required this.port,
    required this.name,
    this.lastSeenAt,
  });
}

class LanSyncService implements SyncTransport {
  final Repo repo;
  final Future<Database> Function() dbProvider;
  final String ourDeviceId;
  final int port;
  HttpServer? _server;
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
      // المنفذ محجوز أو صلاحيات غير كافية — نتجاهل بهدوء.
      _server = null;
      return;
    }
    _server!.listen(_handleRequest);
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  bool get isRunning => _server != null;

  Future<void> _handleRequest(HttpRequest req) async {
    final cors = req.response;
    cors.headers.set('Access-Control-Allow-Origin', '*');
    cors.headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    cors.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      await cors.close();
      return;
    }
    try {
      final path = req.uri.path;
      if (path == '/status' && req.method == 'GET') {
        final db = await dbProvider();
        final dev = await db.query('devices',
            where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
        final devName = dev.isNotEmpty ? (dev.first['name'] as String? ?? 'Nexora') : 'Nexora';
        cors.headers.contentType = ContentType.json;
        cors.write(jsonEncode({
          'deviceId': ourDeviceId,
          'name': devName,
          'port': port,
          'version': 'flutter-native',
        }));
        await cors.close();
        return;
      }
      if (path == '/pair' && req.method == 'POST') {
        final body = await _readJson(req);
        final ok = await _handlePair(body);
        cors.statusCode = ok ? HttpStatus.ok : HttpStatus.badRequest;
        cors.headers.contentType = ContentType.json;
        cors.write(jsonEncode({'ok': ok}));
        await cors.close();
        return;
      }
      if (path == '/ops' && req.method == 'POST') {
        final body = await _readJson(req);
        int applied = 0;
        String? error;
        try {
          final op = SyncOperation.fromMap(Map<String, Object?>.from(body as Map));
          final db = await dbProvider();
          await db.transaction((txn) async {
            // منع الحلقات: تجاهل العمليات الصادرة من هذا الجهاز.
            if (op.deviceId == ourDeviceId) return;
            final ok = await repo.applyRemoteOperation(txn, op, _resolver);
            if (ok) applied++;
            // صف واحد لكل جهاز مرسل أيضًا.
            final qid = await txn.insert('sync_queue', {
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
        } catch (e) {
          error = '$e';
        }
        cors.statusCode = error == null ? HttpStatus.ok : HttpStatus.badRequest;
        cors.headers.contentType = ContentType.json;
        cors.write(jsonEncode({'ok': error == null, 'applied': applied, 'error': error}));
        await cors.close();
        return;
      }
      cors.statusCode = HttpStatus.notFound;
      await cors.close();
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write('$e');
      await req.response.close();
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.isEmpty) return {};
    final d = jsonDecode(text);
    return d is Map<String, Object?> ? d : {};
  }

  Future<bool> _handlePair(Map<String, Object?> body) async {
    final tok = body['token'] as String?;
    final devId = body['deviceId'] as String?;
    final ip = body['ipAddress'] as String?;
    final p = body['port'] as int?;
    final name = body['name'] as String?;
    if (tok == null || tok.length < 6) return false;
    if (devId == null || ip == null || p == null) return false;
    final db = await dbProvider();
    // تحقق من token (صالح لمدة 5 دقائق).
    final rec = await db.query('devices',
        where: 'pair_token = ? AND pair_token_exp > ?',
        whereArgs: [tok, DateTime.now().toIso8601String()], limit: 1);
    if (rec.isEmpty) return false;
    // سجّل الجهاز الجديد.
    final now = DateTime.now().toIso8601String();
    await db.insert('devices', {
      'id': devId,
      'workspace_id': rec.first['workspace_id'] as String? ?? 'default',
      'name': name ?? 'جهاز',
      'platform': 'lan',
      'ip_address': ip,
      'port': p,
      'is_paired': 1,
      'last_seen_at': now,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // امسح token بعد الاستخدام.
    await db.update('devices', {'pair_token': '', 'pair_token_exp': ''},
        where: 'pair_token = ?', whereArgs: [tok]);
    return true;
  }

  // ---------- العميل (إرسال للأجهزة المقترنة) ----------

  @override
  Future<void> push(SyncOperation op) async {
    final db = await dbProvider();
    final devices = await db.query('devices',
        where: "is_paired = 1 AND ip_address <> '' AND id <> ?",
        whereArgs: [ourDeviceId]);
    List<String> errors = [];
    for (final d in devices) {
      final ip = d['ip_address'] as String?;
      final p = d['port'] as int?;
      final devId = d['id'] as String;
      if (ip == null || ip.isEmpty || p == null) continue;
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);
        final url = Uri.parse('http://$ip:$p/ops');
        final req = await client.postUrl(url);
        req.headers.contentType = ContentType.json;
        req.write(op.toJson());
        final resp = await req.close().timeout(const Duration(seconds: 5));
        await resp.drain();
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          errors.add('$devId: HTTP ${resp.statusCode}');
        }
        client.close(force: true);
        // تحديث last_seen للجهاز عند نجاح الإرسال.
        await db.update('devices', {
          'last_seen_at': DateTime.now().toIso8601String(),
        }, where: 'id = ?', whereArgs: [devId]);
      } catch (e) {
        errors.add('$devId: $e');
      }
    }
    if (errors.isNotEmpty) {
      throw StateError('LAN errors: ${errors.join(', ')}');
    }
  }

  Future<bool> pairWith(String ip, int port, String token) async {
    try {
      final db = await dbProvider();
      final localDev = await db.query('devices',
          where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      final name = localDev.isNotEmpty ? (localDev.first['name'] as String? ?? 'Nexora') : 'Nexora';
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final url = Uri.parse('http://$ip:$port/pair');
      final req = await client.postUrl(url);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'token': token,
        'deviceId': ourDeviceId,
        'ipAddress': await _localIp(),
        'port': port,
        'name': name,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await utf8.decoder.bind(resp).join();
      client.close(force: true);
      final ok = resp.statusCode == 200 &&
          ((jsonDecode(body) as Map?)?['ok'] == true);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// يحدد عنوان IP المحلي (أول IPv4 غير loopback).
  Future<String?> _localIp() async {
    try {
      for (final iface in await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4)) {
        for (final a in iface.addresses) {
          if (!a.isLoopback && a.type == InternetAddressType.IPv4) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
