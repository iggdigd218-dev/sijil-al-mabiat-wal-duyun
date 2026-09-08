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

import '../../core/models.dart';
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

/// يحوّل استثناء تطبيق عملية واردة إلى نص قصير آمن للإرسال في رد HTTP:
/// سطر واحد، بلا مسارات ملفات أو Stack traces، بحد أقصى 140 حرفًا.
String sanitizeSyncError(Object e) {
  var s = '$e'.split('\n').first.trim();
  // إزالة أسماء الأصناف الشائعة الطويلة للحفاظ على الإيجاز.
  s = s
      .replaceFirst('SqfliteFfiException', 'db')
      .replaceFirst('DatabaseException', 'db')
      .replaceFirst('FormatException:', 'format:')
      .replaceFirst('Bad state:', '');
  s = s.trim();
  if (s.isEmpty) return 'internal';
  return s.length > 140 ? s.substring(0, 140) : s;
}

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
  final Map<String, Object?>? snapshot;
  const LanPairResult({
    required this.ok,
    this.ourAuthSecret,
    this.remoteDeviceId,
    this.error,
    this.snapshot,
  });
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
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
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
    cors.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization',
    );
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
      if (path == '/snapshot' && req.method == 'GET') {
        await _handleSnapshot(req, cors);
        return;
      }
      if (path == '/roster' && req.method == 'GET') {
        await _handleRoster(req, cors);
        return;
      }
      if (path == '/notify' && req.method == 'POST') {
        await _handleNotify(req, cors);
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
      final dev = await db.query(
        'devices',
        where: 'id = ?',
        whereArgs: [ourDeviceId],
        limit: 1,
      );
      final devName = dev.isNotEmpty
          ? (dev.first['name'] as String? ?? 'Nexora')
          : 'Nexora';
      final wsRows = await db.query('workspaces', limit: 1);
      final wsId = wsRows.isNotEmpty
          ? (wsRows.first['id'] as String)
          : defaultWorkspaceId;
      resp.headers.contentType = ContentType.json;
      resp.write(
        jsonEncode({
          'deviceId': ourDeviceId,
          'name': devName,
          'port': port,
          'workspaceId': wsId,
          'version': 'flutter-native',
        }),
      );
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
      // The receiving socket knows the peer address even if interface discovery
      // is unavailable, and avoids trusting an arbitrary advertised host.
      final address = req.connectionInfo?.remoteAddress.address;
      if (address != null && address.isNotEmpty) body['ipAddress'] = address;
      final ok = await _handlePair(body);
      resp.statusCode = ok.ok ? HttpStatus.ok : HttpStatus.forbidden;
      resp.headers.contentType = ContentType.json;
      resp.write(
        jsonEncode({
          'ok': ok.ok,
          if (ok.ok) 'authSecret': ok.ourAuthSecret,
          if (ok.ok) 'deviceId': ourDeviceId,
          if (!ok.ok) 'error': ok.error,
        }),
      );
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
    if (tok.length < 6 ||
        devId.isEmpty ||
        ip.isEmpty ||
        p == null ||
        theirSecret.isEmpty) {
      return const LanPairResult(ok: false, error: 'bad-request');
    }
    final db = await dbProvider();
    final rec = await db.query(
      'devices',
      where: 'pair_token = ? AND pair_token_exp > ?',
      whereArgs: [tok, DateTime.now().toIso8601String()],
      limit: 1,
    );
    if (rec.isEmpty)
      return const LanPairResult(ok: false, error: 'invalid-token');

    final wsId = rec.first['workspace_id'] as String? ?? defaultWorkspaceId;

    // تأكد من وجود سر محلي لنا، وإلا وُلّد واحد.
    final ourDevRows = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [ourDeviceId],
      limit: 1,
    );
    var ourSecret = (ourDevRows.isNotEmpty
            ? ourDevRows.first['auth_secret'] as String?
            : null) ??
        '';
    if (ourSecret.isEmpty) {
      ourSecret = generateLanSecret();
      await db.update(
        'devices',
        {'auth_secret': ourSecret},
        where: 'id = ?',
        whereArgs: [ourDeviceId],
      );
    }
    // هوية المُقرِن (مالك هذا الجهاز / المضيف).
    int? pairedBy;
    try {
      final ourDev = await db.query(
        'devices',
        where: 'id = ?',
        whereArgs: [ourDeviceId],
        limit: 1,
      );
      if (ourDev.isNotEmpty) pairedBy = ourDev.first['user_id'] as int?;
    } catch (_) {}

    final now = DateTime.now().toIso8601String();
    // سجّل الجهاز الجديد كعضو (ليس مالكًا) مع السر المرسل.
    await db.insert(
        'devices',
        {
          'id': devId,
          'workspace_id': wsId,
          'name': name,
          'platform': 'lan',
          'ip_address': ip,
          'port': p,
          'auth_secret': theirSecret,
          'is_paired': 1,
          'is_owner': 0,
          'revoked_at': '',
          'last_seen_at': now,
          'created_at': now,
          'updated_at': now,
          'paired_by': pairedBy,
          // user_id يتركه المدير يحدده من شاشة الأجهزة.
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    // تأكد من أننا نحن أصحاب المساحة (المضيف).
    await db.update(
      'devices',
      {'is_owner': 1},
      where: 'id = ?',
      whereArgs: [ourDeviceId],
    );
    // امسح token بعد الاستخدام (one-time).
    await db.update(
      'devices',
      {'pair_token': '', 'pair_token_exp': ''},
      where: 'pair_token = ?',
      whereArgs: [tok],
    );
    // ضبط الوضع "مُدار" لدى المضيف.
    await db.insert(
        'sync_meta',
        {
          'key': 'workspaceMode',
          'value': 'host',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    // نُعيد سرّنا للجهاز الآخر كي يخزنه ويُرسله عند الإرسال إلينا.
    return LanPairResult(
      ok: true,
      ourAuthSecret: ourSecret,
      remoteDeviceId: devId,
    );
  }

  /// يُرجع لقطة كاملة من جميع الجداول المحلية للعضو الجديد ليستبدل بها بياناته.
  Future<void> _handleSnapshot(HttpRequest req, HttpResponse resp) async {
    // المصادقة بنفس Bearer token (auth_secret) المستخدم في /ops.
    final auth = req.headers.value('Authorization') ?? '';
    final secret = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
    resp.headers.contentType = ContentType.json;
    if (secret.isEmpty) {
      resp.statusCode = HttpStatus.unauthorized;
      resp.write(jsonEncode({'ok': false, 'error': 'auth-required'}));
      await resp.close();
      return;
    }
    try {
      final db = await dbProvider();
      final devRows = await db.query(
        'devices',
        where:
            "auth_secret = ? AND is_paired = 1 AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''",
        whereArgs: [secret],
        limit: 1,
      );
      if (devRows.isEmpty) {
        resp.statusCode = HttpStatus.forbidden;
        resp.write(jsonEncode({'ok': false, 'error': 'unknown-device'}));
        await resp.close();
        return;
      }
      // نجمع كل الجداول التي يجب نسخها.
      final snapshot = <String, Object?>{};
      const tables = [
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'workspaces',
        'devices',
      ];
      for (final t in tables) {
        final rows = await db.query(t);
        snapshot[t] = rows.map((source) {
          final row = Map<String, Object?>.from(source);
          if (t == 'users') {
            row['pin'] = '';
            row['password'] = '';
          }
          if (t == 'devices') {
            // نوزّع أسرار الأجهزة النشطة للعضو المنضم (الطلب موثّق بسرّه):
            // بها يقبل عمليات بقية الأعضاء مباشرة حتى بغياب المدير.
            final active =
                ((row['revoked_at'] as String?) ?? '').isEmpty &&
                    ((row['expelled_at'] as String?) ?? '').isEmpty;
            if (!active) row['auth_secret'] = '';
            row['pair_token'] = '';
            row['pair_token_exp'] = '';
          }
          return row;
        }).toList();
      }
      snapshot['workspaceMode'] = 'member';
      snapshot['hostDeviceId'] = ourDeviceId;
      resp.write(jsonEncode({'ok': true, 'data': snapshot}));
      await resp.close();
    } catch (e) {
      resp.statusCode = HttpStatus.internalServerError;
      resp.write(jsonEncode({'ok': false, 'error': '$e'}));
      await resp.close();
    }
  }

  /// قائمة الأجهزة والأدوار الحالية (للمصالحة الدورية بين الأعضاء والمالك).
  /// تتيح للعضو اكتشاف نقل الملكية إليه أو طرده أو تغيّر أقرانه دون لقطة كاملة.
  Future<void> _handleRoster(HttpRequest req, HttpResponse resp) async {
    final auth = req.headers.value('Authorization') ?? '';
    final secret =
        auth.startsWith('Bearer ') ? auth.substring(7).trim() : auth;
    resp.headers.contentType = ContentType.json;
    if (secret.isEmpty) {
      resp.statusCode = HttpStatus.unauthorized;
      resp.write(jsonEncode({'ok': false, 'error': 'auth-required'}));
      await resp.close();
      return;
    }
    try {
      final db = await dbProvider();
      final dev = await db.query(
        'devices',
        where:
            "auth_secret = ? AND is_paired = 1 AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''",
        whereArgs: [secret],
        limit: 1,
      );
      if (dev.isEmpty) {
        resp.statusCode = HttpStatus.forbidden;
        resp.write(jsonEncode({'ok': false, 'error': 'unknown-device'}));
        await resp.close();
        return;
      }
      final selfId = dev.first['id'] as String;
      final devices = await db.query('devices');
      final roster = devices.map((d) {
        final m = Map<String, Object?>.from(d);
        m['pair_token'] = '';
        m['pair_token_exp'] = '';
        // أسرار المصادقة تُوزَّع لكل جهاز مقترن موثّق (طلب الـ roster نفسه
        // محمي بسر الجهاز): بدونها لا يستطيع عضو التحقق من عمليات عضو آخر
        // فتتعطل مزامنة الأعضاء بغياب المدير. الأجهزة الموقوفة/المطرودة
        // لا سر لها أصلاً (يُمسح عند الإيقاف/الطرد).
        final active = ((d['revoked_at'] as String?) ?? '').isEmpty &&
            ((d['expelled_at'] as String?) ?? '').isEmpty;
        if (!active) m['auth_secret'] = '';
        return m;
      }).toList();
      // أدوار المستخدمين (للمصالحة) دون أسرار.
      final users = (await db.query('users')).map((u) {
        final m = Map<String, Object?>.from(u);
        m['pin'] = '';
        m['password'] = '';
        return m;
      }).toList();
      final modeRows = await db.query('sync_meta',
          where: 'key = ?', whereArgs: ['workspaceMode'], limit: 1);
      resp.write(jsonEncode({
        'ok': true,
        'hostDeviceId': ourDeviceId,
        'selfId': selfId,
        'workspaceMode': modeRows.isEmpty ? 'managed' : modeRows.first['value'],
        'devices': roster,
        'users': users,
      }));
    } catch (e) {
      resp.statusCode = HttpStatus.internalServerError;
      resp.write(jsonEncode({'ok': false, 'error': '$e'}));
    }
    await resp.close();
  }

  /// إشعار فوري من نظير (مثلاً المالك غيّر صلاحية جهاز): يردّ بالموافقة فقط،
  /// والعميل عند استلامه يبادر فورًا بسحب الـ roster ومعالجة طابور العمليات.
  Future<void> _handleNotify(HttpRequest req, HttpResponse resp) async {
    int statusCode = HttpStatus.ok;
    String? error;
    try {
      final auth = req.headers.value('Authorization') ?? '';
      final secret =
          auth.startsWith('Bearer ') ? auth.substring(7).trim() : auth;
      if (secret.isEmpty) {
        statusCode = HttpStatus.unauthorized;
        error = 'auth-required';
        return;
      }
      final db = await dbProvider();
      final dev = await db.query(
        'devices',
        where:
            "auth_secret = ? AND is_paired = 1 AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''",
        whereArgs: [secret],
        limit: 1,
      );
      if (dev.isEmpty) {
        statusCode = HttpStatus.forbidden;
        error = 'unknown-device';
        return;
      }
      // حدّث آخر ظهور للمرسل وعنوانه.
      await db.update(
        'devices',
        {
          'last_seen_at': DateTime.now().toIso8601String(),
          'ip_address': req.connectionInfo?.remoteAddress.address ?? '',
        },
        where: 'id = ?',
        whereArgs: [dev.first['id']],
      );
      onPeerNotify?.call();
    } catch (e) {
      statusCode = HttpStatus.internalServerError;
      error = 'internal';
    } finally {
      resp.statusCode = statusCode;
      resp.headers.contentType = ContentType.json;
      resp.write(jsonEncode({'ok': error == null, 'error': error}));
      await resp.close();
    }
  }

  /// يُستدعى محليًا عند استقبال إشعار فوري من نظير (يضبطه محرك المزامنة
  /// ليسحب الـ roster ويعالج الطابور فورًا دون انتظار الدورية).
  void Function()? onPeerNotify;

  /// وصلت رسالة دردشة جماعية من جهاز آخر (اسم المرسل، نص الرسالة).
  static void Function(String senderName, String body)? onChatMessage;

  /// يبثّ إشعارًا فوريًا لكل الأقران المقترنين بأن شيئًا تغيّر
  /// (صلاحية/جهاز/عملية). استدعاء غير متزامن يتجاهل أخطاء الشبكة بصمت.
  Future<void> broadcastNotify({String reason = 'roster'}) async {
    try {
      final db = await dbProvider();
      final own = await db.query('devices',
          columns: ['auth_secret'],
          where: 'id = ?',
          whereArgs: [ourDeviceId],
          limit: 1);
      final secret =
          own.isEmpty ? '' : (own.first['auth_secret'] as String? ?? '');
      if (secret.isEmpty) return;
      final devices = await db.query(
        'devices',
        where:
            "is_paired = 1 AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' AND ip_address <> '' AND id <> ?",
        whereArgs: [ourDeviceId],
      );
      for (final d in devices) {
        final ip = d['ip_address'] as String?;
        final p = d['port'] as int?;
        if (ip == null || ip.isEmpty || p == null) continue;
        try {
          final req = await _httpClient.postUrl(Uri.parse('http://$ip:$p/notify'))
            ..headers.set('Authorization', 'Bearer $secret');
          req.write(jsonEncode({'reason': reason}));
          await req.close().timeout(const Duration(seconds: 3));
        } catch (_) {
          // تجاهل: القرين غير متصل حاليًا، ستصلح الدورية الأمر لاحقًا.
        }
      }
    } catch (_) {}
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
      // تحقق هل الجهاز مطرود (حتى وإن عرف السر الصحيح).
      final expelledRows = await db.query(
        'devices',
        where:
            "id = ? AND (COALESCE(revoked_at,'') <> '' OR COALESCE(expelled_at,'') <> '')",
        whereArgs: [op.deviceId],
        limit: 1,
      );
      if (expelledRows.isNotEmpty) {
        // 410 Gone يُخبر العضو أنه مطرود ويجب أن يمسح بياناته ويعود مستقلاً.
        statusCode = HttpStatus.gone;
        error = 'device-expelled';
        return;
      }
      final senderRows = await db.query(
        'devices',
        where:
            "id = ? AND is_paired = 1 AND COALESCE(revoked_at, '') = '' AND COALESCE(expelled_at,'') = '' AND auth_secret = ?",
        whereArgs: [op.deviceId, secret],
        limit: 1,
      );
      if (senderRows.isEmpty) {
        statusCode = HttpStatus.forbidden;
        error = 'device-not-authorized';
        return;
      }
      final sender = senderRows.first;
      if ((sender['is_owner'] as int? ?? 0) != 1) {
        final userId = sender['user_id'] as int?;
        final users = userId == null
            ? <Map<String, Object?>>[]
            : await db.query('users',
                where:
                    "id = ? AND active = 1 AND COALESCE(deleted_at, '') = ''",
                whereArgs: [userId],
                limit: 1);
        final user = users.isEmpty ? null : AppUser.fromMap(users.first);
        // رسائل الدردشة الجماعية مسموحة لكل جهاز مقترن حتى بلا صلاحيات —
        // الدردشة قناة تواصل داخل المجموعة (يتواصل بها العضو مع المدير
        // حتى لو لم تُمنح له أي صلاحية بعد).
        final isChat = op.entityType == EntityKind.message ||
            op.entityType == EntityKind.conversation;
        if (!isChat) {
          final permission = switch (op.entityType) {
            EntityKind.user => 'manage_users',
            EntityKind.setting || EntityKind.currency => 'manage_users',
            _ => switch (op.opType) {
                OpKind.create || OpKind.restore => 'add_tx',
                OpKind.update => 'edit_tx',
                OpKind.delete_ => 'delete_tx',
                OpKind.settings => 'manage_users',
              },
          };
          if (user == null || !user.can(permission)) {
            statusCode = HttpStatus.forbidden;
            error = 'user-not-authorized';
            return;
          }
        }
      }
      // 3) تحقق من workspaceId المطابق.
      final wsRows = await db.query('workspaces', limit: 1);
      final localWsId = wsRows.isNotEmpty
          ? (wsRows.first['id'] as String)
          : defaultWorkspaceId;
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

      var appliedThisOp = false;
      await db.transaction((txn) async {
        final ok = await repo.applyRemoteOperation(txn, op, _resolver);
        if (ok) {
          applied++;
          appliedThisOp = true;
        }
        await txn.insert(
            'sync_queue',
            {
              'operation_id': op.id,
              'status': SyncStatus.synced.name,
              'target': SyncTarget.lanBroadcast,
              'attempts': 0,
              'last_error': '',
              'next_try_at': '',
              'created_at': DateTime.now().toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      });
      // إشعار وصول رسالة دردشة جماعية من جهاز آخر (داخلي + خارجي).
      if (appliedThisOp &&
          op.entityType == EntityKind.message &&
          op.deviceId != ourDeviceId) {
        try {
          final senderName =
              (senderRows.first['name'] as String?) ?? 'جهاز في المجموعة';
          final body = '${op.payload['body'] ?? ''}';
          if (body.isNotEmpty) onChatMessage?.call(senderName, body);
        } catch (_) {}
      }
      await repo.setSetting('lastLanSync', DateTime.now().toLocal().toString());
      // تحديث last_seen للمرسل.
      await db.update(
        'devices',
        {
          'last_seen_at': DateTime.now().toIso8601String(),
          'ip_address': (req.connectionInfo?.remoteAddress.address) ??
              senderRows.first['ip_address'],
        },
        where: 'id = ?',
        whereArgs: [op.deviceId],
      );
    } on StateError catch (e) {
      error = e.message;
      statusCode = HttpStatus.requestEntityTooLarge;
    } catch (e) {
      // نُعيد السبب الحقيقي (مُنظّفًا ومُقتضبًا) بدل كلمة 'internal' الغامضة،
      // حتى يظهر لدى المُرسِل سبب الفشل الفعلي (قيد قاعدة بيانات، عمود ناقص…)
      // ويمكن تشخيصه من شاشة العمليات المتزامنة مباشرة.
      error = sanitizeSyncError(e);
      statusCode = HttpStatus.internalServerError;
    } finally {
      resp.statusCode = statusCode;
      resp.headers.contentType = ContentType.json;
      resp.write(
        jsonEncode({'ok': error == null, 'applied': applied, 'error': error}),
      );
      await resp.close();
    }
  }

  // ---------- العميل (إرسال للأجهزة المقترنة) ----------

  HttpClient get _httpClient {
    return _client ??= HttpClient()..connectionTimeout = kLanRequestTimeout;
  }

  /// يسحب قائمة الأجهزة والأدوار من الأقران ويصالح الحالة المحلية:
  /// - يحدّث is_owner لجهازنا (اكتشاف نقل الملكية فورًا).
  /// - يحدّث عناوين/منافذ وأدوار الأجهزة والمستخدمين.
  /// - يرجع true إذا تغيّرت ملكيتنا (لإعادة بناء الواجهة).
  Future<bool> reconcileRoster() async {
    final db = await dbProvider();
    final ownRows = await db.query('devices',
        where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
    if (ownRows.isEmpty) return false;
    final own = ownRows.first;
    final secret = (own['auth_secret'] as String?) ?? '';
    final wasOwner = (own['is_owner'] as int? ?? 0) == 1;
    if (secret.isEmpty) return false;

    final peers = await db.query(
      'devices',
      where:
          "is_paired = 1 AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' AND ip_address <> '' AND id <> ?",
      whereArgs: [ourDeviceId],
    );
    for (final peer in peers) {
      final ip = peer['ip_address'] as String?;
      final p = peer['port'] as int?;
      if (ip == null || ip.isEmpty || p == null) continue;
      try {
        final req = await _httpClient
            .getUrl(Uri.parse('http://$ip:$p/roster'))
            .timeout(const Duration(seconds: 6));
        req.headers.set('Authorization', 'Bearer $secret');
        final resp =
            await req.close().timeout(const Duration(seconds: 6));
        final body = await resp
            .timeout(const Duration(seconds: 4))
            .transform(utf8.decoder)
            .join();
        if (resp.statusCode == HttpStatus.gone) {
          try {
            await repo.resetToStandaloneAfterExpulsion();
          } catch (_) {}
          return true;
        }
        if (resp.statusCode != 200) continue;
        final m = jsonDecode(body) as Map;
        if (m['ok'] != true) continue;
        await _applyRoster(db, Map<String, Object?>.from(m));
        // تكفي مصالحة ناجحة من نظير واحد (المالك).
        break;
      } catch (_) {
        // جرّب القرين التالي.
      }
    }
    final after = await db.query('devices',
        where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
    final nowOwner =
        after.isNotEmpty && ((after.first['is_owner'] as int? ?? 0) == 1);
    return nowOwner != wasOwner;
  }

  /// إشعار العضو بتغيير يخصه أجراه المدير (تغيير اسم الجهاز، ترقية/تخفيض
  /// الصلاحيات...) — (عنوان، نص).
  static void Function(String title, String body)? onMemberNotice;

  Future<void> _applyRoster(Database db, Map<String, Object?> roster) async {
    final devices = (roster['devices'] as List?) ?? const [];
    final users = (roster['users'] as List?) ?? const [];
    final mode = (roster['workspaceMode'] as String?) ?? 'managed';
    // التقط حالتنا قبل التطبيق لكشف تغييرات المدير التي تخصنا.
    String? oldName;
    Object? oldUserId;
    String oldRole = '';
    String oldPerms = '';
    try {
      final me = await db.query('devices',
          where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      if (me.isNotEmpty) {
        oldName = me.first['name'] as String?;
        oldUserId = me.first['user_id'];
        if (oldUserId != null) {
          final u = await db.query('users',
              where: 'id = ?', whereArgs: [oldUserId], limit: 1);
          if (u.isNotEmpty) {
            oldRole = (u.first['role'] as String?) ?? '';
            oldPerms = (u.first['permissions'] as String?) ?? '';
          }
        }
      }
    } catch (_) {}
    await db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();
      // حدّث/أدرج سجلات الأجهزة (مع الحفاظ على سرّنا المحلي).
      for (final raw in devices) {
        final d = Map<String, Object?>.from(raw as Map);
        final id = d['id'] as String?;
        if (id == null) continue;
        final existing = await txn
            .query('devices', where: 'id = ?', whereArgs: [id], limit: 1);
        final isSelf = id == ourDeviceId;
        final map = <String, Object?>{
          'workspace_id': d['workspace_id'] ?? defaultWorkspaceId,
          'name': d['name'] ?? 'جهاز',
          'platform': d['platform'] ?? 'lan',
          'ip_address': d['ip_address'] ?? '',
          'port': d['port'] ?? kDefaultLanPort,
          'is_owner': isSelf
              ? (d['is_owner'] ?? 0)
              : (d['is_owner'] ??
                  (existing.isNotEmpty ? existing.first['is_owner'] : 0)),
          'is_paired': 1,
          'user_id': d['user_id'],
          'revoked_at': d['revoked_at'] ?? '',
          'expelled_at': d['expelled_at'] ?? '',
          'last_seen_at': now,
          'updated_at': now,
        };
        // أسرار الأقران الواردة من المصدر الموثوق: نلتقطها إن كانت لدينا
        // ناقصة — بها يستطيع الأعضاء التحقق من عمليات بعضهم بغياب المدير.
        // سرّنا نحن لا يُكتب أبداً من بيانات واردة.
        final incomingSecret = (d['auth_secret'] as String?) ?? '';
        if (existing.isNotEmpty) {
          final haveSecret =
              ((existing.first['auth_secret'] as String?) ?? '').isNotEmpty;
          if (!isSelf && !haveSecret && incomingSecret.isNotEmpty) {
            map['auth_secret'] = incomingSecret;
          }
          await txn.update('devices', map,
              where: 'id = ?', whereArgs: [id]);
        } else {
          map['id'] = id;
          map['auth_secret'] = isSelf ? '' : incomingSecret;
          map['created_at'] = now;
          await txn.insert('devices', map,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      // أدوار المستخدمين (مزامنة الصلاحيات) دون المساس بـ is_me/كلمات السر.
      for (final raw in users) {
        final u = Map<String, Object?>.from(raw as Map);
        final uid = u['id'];
        if (uid == null) continue;
        final existing = await txn
            .query('users', where: 'id = ?', whereArgs: [uid], limit: 1);
        final map = <String, Object?>{
          'name': u['name'] ?? 'مستخدم',
          'role': u['role'] ?? 'viewer',
          'permissions': u['permissions'] ?? '',
          'active': u['active'] ?? 1,
          'deleted_at': u['deleted_at'] ?? '',
          'workspace_id': u['workspace_id'] ?? defaultWorkspaceId,
          'updated_at': now,
        };
        if (existing.isNotEmpty) {
          await txn.update('users', map,
              where: 'id = ?', whereArgs: [uid]);
        } else {
          map['id'] = uid;
          map['is_me'] = 0;
          map['pin'] = '';
          map['password'] = '';
          map['created_at'] = now;
          await txn.insert('users', map,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await txn.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': mode},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    // بعد التطبيق: قارن حالتنا وأبلغ العضو بأي تغيير أجراه المدير عليه.
    if (onMemberNotice == null) return;
    try {
      final me = await db.query('devices',
          where: 'id = ?', whereArgs: [ourDeviceId], limit: 1);
      if (me.isEmpty) return;
      final newName = me.first['name'] as String?;
      final newUserId = me.first['user_id'];
      if (oldName != null &&
          newName != null &&
          newName.isNotEmpty &&
          newName != oldName) {
        onMemberNotice?.call(
            'تم تغيير اسم جهازك', 'المدير غيّر اسم جهازك إلى «$newName»');
      }
      if (newUserId != null) {
        final u = await db.query('users',
            where: 'id = ?', whereArgs: [newUserId], limit: 1);
        if (u.isNotEmpty) {
          final newRole = (u.first['role'] as String?) ?? '';
          final newPerms = (u.first['permissions'] as String?) ?? '';
          String roleLabel(String r) => switch (r) {
                'admin' || 'manager' => 'مدير النظام',
                'accountant' => 'محاسب',
                'dataentry' => 'موظف إدخال',
                'viewer' => 'عرض فقط',
                _ => r,
              };
          if (oldUserId == null) {
            onMemberNotice?.call('تم تفعيل حسابك',
                'المدير فعّل حسابك بدور «${roleLabel(newRole)}» — يمكنك الآن العمل حسب صلاحياتك');
          } else if (newRole != oldRole && oldRole.isNotEmpty) {
            const rank = {
              'viewer': 0,
              'dataentry': 1,
              'accountant': 2,
              'admin': 3,
              'manager': 3,
            };
            final up = (rank[newRole] ?? 0) > (rank[oldRole] ?? 0);
            onMemberNotice?.call(
                up ? 'تمت ترقية صلاحياتك' : 'تم تخفيض صلاحياتك',
                'المدير غيّر دورك من «${roleLabel(oldRole)}» إلى «${roleLabel(newRole)}»');
          } else if (newPerms != oldPerms && oldUserId == newUserId) {
            onMemberNotice?.call(
                'تم تعديل صلاحياتك', 'المدير حدّث قائمة الصلاحيات الممنوحة لك');
          }
        }
      }
    } catch (_) {}
  }

  /// حاضِر أم غائب؟ يضبطه محرك المزامنة من خدمة الحضور — إن وُجد نستخدمه
  /// لتخطّي الأجهزة الغائبة بدل محاولات فاشلة متراكمة.
  bool Function(String deviceId)? isPeerOnline;

  /// يُستدعى عند تسليم عملية لجهاز بنجاح (لتحديث سجل op_deliveries والإشعار).
  void Function(SyncOperation op, String deviceId, String deviceName)?
      onDelivered;

  Future<void> push(SyncOperation op) async {
    final db = await dbProvider();
    final own = await db.query('devices',
        columns: ['auth_secret'],
        where: 'id = ?',
        whereArgs: [ourDeviceId],
        limit: 1);
    final senderSecret =
        own.isEmpty ? '' : (own.first['auth_secret'] as String? ?? '');
    if (senderSecret.isEmpty) throw StateError('missing-sender-credential');
    final devices = await db.query(
      'devices',
      where:
          "is_paired = 1 AND COALESCE(revoked_at, '') = '' AND ip_address <> '' AND id <> ?",
      whereArgs: [ourDeviceId],
    );
    if (devices.isEmpty) throw StateError('no-paired-peers');
    // الأجهزة التي استلمت هذه العملية فعلاً — لا نعيد الإرسال إليها.
    // (ننشئ الجدول عند غيابه: قواعد قديمة قبل هذه الميزة.)
    await db.execute('CREATE TABLE IF NOT EXISTS op_deliveries ('
        'operation_id TEXT NOT NULL, device_id TEXT NOT NULL, '
        'delivered_at TEXT NOT NULL, PRIMARY KEY (operation_id, device_id))');
    final deliveredRows = await db.query('op_deliveries',
        columns: ['device_id'],
        where: 'operation_id = ?',
        whereArgs: [op.id]);
    final delivered =
        deliveredRows.map((r) => r['device_id'] as String).toSet();
    final errors = <String>[];
    var skippedOffline = 0;
    var reachedAll = true;
    for (final d in devices) {
      final ip = d['ip_address'] as String?;
      final p = d['port'] as int?;
      final devId = d['id'] as String;
      final devName = (d['name'] as String?) ?? 'جهاز';
      if (ip == null || ip.isEmpty || p == null) continue;
      if (delivered.contains(devId)) continue; // سُلّمت له سابقاً.
      // جهاز غائب وفق نظام الحضور: تخطَّ بلا محاولة فاشلة — سيُستأنف
      // الدفع فور عودته (onPeerOnline يستدعي processQueue فوراً).
      if (isPeerOnline != null && !isPeerOnline!(devId)) {
        skippedOffline++;
        reachedAll = false;
        continue;
      }
      try {
        final req = await _httpClient.postUrl(Uri.parse('http://$ip:$p/ops'));
        req.headers.contentType = ContentType.json;
        req.headers.set('Authorization', 'Bearer $senderSecret');
        req.write(op.toJson());
        final resp = await req.close().timeout(const Duration(seconds: 5));
        final body = await resp
            .timeout(const Duration(seconds: 3))
            .transform(utf8.decoder)
            .join();
        if (resp.statusCode == HttpStatus.gone) {
          // المضيف أبلغنا أننا مطرودون → نمسح البيانات محلياً ونعود مستقلين.
          try {
            await repo.resetToStandaloneAfterExpulsion();
          } catch (_) {}
          errors.add('$devId: expelled');
          continue;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          String errMsg = 'HTTP ${resp.statusCode}';
          try {
            final m = jsonDecode(body) as Map;
            errMsg = '${m['error'] ?? errMsg}';
          } catch (_) {}
          errors.add('$devId: $errMsg');
          reachedAll = false;
        } else {
          // تسليم ناجح لهذا الجهاز: سجّله (idempotent) وأبلغ المستمع.
          await db.insert(
            'op_deliveries',
            {
              'operation_id': op.id,
              'device_id': devId,
              'delivered_at': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          try {
            onDelivered?.call(op, devId, devName);
          } catch (_) {}
        }
        await db.update(
          'devices',
          {'last_seen_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [devId],
        );
      } catch (e) {
        errors.add('$devId: $e');
        reachedAll = false;
      }
    }
    if (errors.isNotEmpty) {
      throw StateError(errors.join('; '));
    }
    // كل الأجهزة الحاضرة استلمت، لكن أجهزة غائبة لم تستلم بعد:
    // نعتبر الدفعة "غير مكتملة" (تبقى pending) دون تسجيل محاولة فاشلة صاخبة.
    if (skippedOffline > 0 && !reachedAll) {
      throw StateError('awaiting-offline-peers:$skippedOffline');
    }
  }

  /// يرسل طلب pairing وإن نجح يسجل الخصم.
  Future<LanPairResult> pairWith(
    String ip,
    int port,
    String token, {
    int? ourPort,
  }) async {
    try {
      final db = await dbProvider();
      // العضو المرتبط بمجموعة لا يمكنه إنشاء اقتران/مزامنة خارجها:
      // الانضمام إلى مجموعة أخرى يمر حصراً عبر الطرد ثم إعادة الانضمام.
      final modeRows = await db.query('sync_meta',
          where: 'key = ?', whereArgs: ['workspaceMode'], limit: 1);
      final wsMode =
          modeRows.isEmpty ? 'standalone' : (modeRows.first['value'] ?? '');
      if (wsMode == 'member') {
        return const LanPairResult(
          ok: false,
          error: 'أنت عضو في مجموعة قائمة — لا يمكن الاقتران أو المزامنة '
              'خارج المجموعة من جهاز عضو.',
        );
      }
      final localDev = await db.query(
        'devices',
        where: 'id = ?',
        whereArgs: [ourDeviceId],
        limit: 1,
      );
      final name = localDev.isNotEmpty
          ? (localDev.first['name'] as String? ?? 'Nexora')
          : 'Nexora';
      final localPort = ourPort ?? port;
      var ourSecret = (localDev.isNotEmpty
              ? localDev.first['auth_secret'] as String?
              : null) ??
          '';
      if (ourSecret.isEmpty) {
        ourSecret = generateLanSecret();
        await db.update(
          'devices',
          {'auth_secret': ourSecret},
          where: 'id = ?',
          whereArgs: [ourDeviceId],
        );
      }
      final req = await _httpClient.postUrl(Uri.parse('http://$ip:$port/pair'));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'token': token,
          'deviceId': ourDeviceId,
          'ipAddress': await _localIp() ?? '',
          'port': localPort, // المنفذ الذي نستمع نحن عليه كعضو.
          'name': name,
          'authSecret': ourSecret,
        }),
      );
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final bodyText = await resp
          .timeout(const Duration(seconds: 3))
          .transform(utf8.decoder)
          .join();
      if (resp.statusCode != 200) {
        return LanPairResult(ok: false, error: 'HTTP ${resp.statusCode}');
      }
      final m = jsonDecode(bodyText) as Map;
      final ok = m['ok'] == true;
      if (!ok)
        return LanPairResult(ok: false, error: '${m['error'] ?? 'failed'}');
      final remoteSecret = (m['authSecret'] as String?) ?? '';
      if (remoteSecret.isEmpty)
        return const LanPairResult(ok: false, error: 'no-secret');
      // سجّل الجهاز الآخر مع سرّه.
      // لاحظ: الجهاز الآخر قد لا يعرف بعد deviceId/name/ip لنا قبل أن نكمل الاقتران،
      // لكنه سجّلنا بالفعل في _handlePair عنده (وولّد لنا سر ourSecret).
      final devId = m['deviceId'] as String? ?? '';
      final now = DateTime.now().toIso8601String();
      if (devId.isNotEmpty) {
        await db.insert(
            'devices',
            {
              'id': devId,
              'workspace_id': defaultWorkspaceId,
              'name': 'المضيف',
              'platform': 'lan',
              'ip_address': ip,
              'port': port,
              'auth_secret': remoteSecret,
              'is_paired': 1,
              'is_owner': 1, // المضيف هو المالك.
              'revoked_at': '',
              'last_seen_at': now,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // نجلب اللقطة الكاملة من المضيف ونُعيدها في LanPairResult ليُطبّقها المستدعي.
      Map<String, Object?>? snapshot;
      try {
        final snapReq = await _httpClient.getUrl(
          Uri.parse('http://$ip:$port/snapshot'),
        );
        snapReq.headers.set('Authorization', 'Bearer $ourSecret');
        final snapResp = await snapReq.close().timeout(
              const Duration(seconds: 10),
            );
        final snapBody = await snapResp
            .timeout(const Duration(seconds: 8))
            .transform(utf8.decoder)
            .join();
        final snapJson = jsonDecode(snapBody) as Map;
        if (snapJson['ok'] == true) {
          snapshot = (snapJson['data'] as Map?)?.cast<String, Object?>();
        }
      } catch (_) {}
      return LanPairResult(
        ok: true,
        remoteDeviceId: devId.isEmpty ? null : devId,
        snapshot: snapshot,
      );
    } on SocketException {
      return const LanPairResult(
        ok: false,
        error:
            'تعذّر الوصول إلى الجهاز المضيف.\n'
            'تأكد أن: كلا الجهازين على نفس شبكة الواي فاي، خادم المزامنة يعمل '
            'على الجهاز الآخر، وعنوان IP ورقم المنفذ صحيحان، وأن جدار الحماية '
            'يسمح للتطبيق بالاتصال.',
      );
    } on TimeoutException {
      return const LanPairResult(
        ok: false,
        error: 'انتهت مهلة الاتصال بالجهاز المضيف. تأكد من الشبكة وأن الخادم يعمل.',
      );
    } catch (e) {
      return LanPairResult(ok: false, error: '$e');
    }
  }

  /// يُطبّق لقطة البيانات القادمة من المضيف على الجهاز العضو (يمسح القديم ويستبدله).
  static Future<void> applySnapshot(
    Future<Database> Function() dbProvider,
    String ourDeviceId,
    Map<String, Object?> snap,
  ) async {
    final db = await dbProvider();
    await db.transaction((txn) async {
      final knownDevices =
          await txn.query('devices', columns: ['id', 'auth_secret']);
      final knownSecrets = {
        for (final d in knownDevices) d['id']: d['auth_secret']
      };
      // 1) مسح البيانات المحلية (نُبقي devices/workspaces/sync_meta جزئياً).
      const clearTables = [
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'operations',
        'sync_queue',
      ];
      for (final t in clearTables) {
        await txn.delete(t);
      }
      // نحذف سجلات الأجهزة الأخرى ونُبقي سجلنا وسجل المضيف.
      await txn.delete('devices', where: 'id <> ?', whereArgs: [ourDeviceId]);

      // 2) نسخ الجداول من اللقطة.
      Future<void> insertAll(String table) async {
        final raw = snap[table];
        if (raw is! List) return;
        for (final r in raw) {
          if (r is! Map) continue;
          try {
            final map = <String, Object?>{};
            r.forEach((k, v) {
              if (k is String) map[k] = v as Object?;
            });
            if (table == 'devices') {
              if (map['id'] == ourDeviceId ||
                  (map['auth_secret'] as String? ?? '').isEmpty) {
                // سرّنا لا يُكتب أبداً من لقطة واردة؛ وعند غياب السر في
                // اللقطة نحتفظ بما تعلمناه سابقاً عبر الاقتران.
                map['auth_secret'] = knownSecrets[map['id']] ?? '';
              }
              if (map['id'] == ourDeviceId) {
                // سجلنا كما يعرفه المضيف — لسنا مالكين.
                map['is_owner'] = 0;
              } else if ((map['is_owner'] ?? 0) == 1) {
                // تأكد من أن سجل المضيف يظل is_owner=1 (المالك الشرعي).
                map['is_owner'] = 1;
              }
            }
            if (table == 'users') {
              // العضو لا يملك أي مستخدم محلي كـ "أنا"؛ الهوية تأتي من
              // devices.user_id التي يعيّنها المدير لاحقاً.
              map['is_me'] = 0;
            }
            await txn.insert(
              table,
              map,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } catch (_) {}
        }
      }

      await insertAll('workspaces');
      await insertAll('users');
      await insertAll('devices');
      await insertAll('accounts');
      await insertAll('transactions');
      await insertAll('transaction_items');
      await insertAll('vouchers');
      await insertAll('currencies');
      await insertAll('categories');
      await insertAll('item_categories');
      await insertAll('items');
      await insertAll('stock_moves');
      await insertAll('conversations');
      await insertAll('messages');
      await insertAll('trash');
      await insertAll('activity');

      // 3) جهازنا الآن عضو (ليس مالكًا).
      await txn.update(
        'devices',
        {'is_owner': 0, 'is_paired': 1},
        where: 'id = ?',
        whereArgs: [ourDeviceId],
      );
      // 4) ضبط وضع المساحة على "عضو".
      await txn.insert(
          'sync_meta',
          {
            'key': 'workspaceMode',
            'value': 'member',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<String?> _localIp() async {
    try {
      for (final iface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        for (final a in iface.addresses) {
          if (!a.isLoopback && a.type == InternetAddressType.IPv4)
            return a.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
