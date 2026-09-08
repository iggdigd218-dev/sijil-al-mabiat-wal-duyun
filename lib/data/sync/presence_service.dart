// نظام الحضور الفوري (مناداة مستمرة + استماع دائم):
//
//  - كل جهاز "ينادي" أقرانه المقترنين كل 3 ثوانٍ عبر GET /status الخفيف
//    (طلب واحد صغير لا يحمل بيانات) فيعرف فور اتصال أو انقطاع أي جهاز.
//  - المستقبل "يستمع" طوال الوقت عبر خادم LAN القائم أصلاً؛ وصول أي مناداة
//    يعني أن المُنادي حاضر (تحديث last_seen_at في الاتجاهين).
//  - عند اكتشاف عودة جهاز من الغياب: مزامنة فورية تلقائية خلال أقل من ثانية
//    (onPeerOnline) — لا انتظار للدورة الدورية.
//  - عند غياب جهاز: تُجمَّد محاولات الإرسال إليه (لا محاولات فاشلة متراكمة)
//    حتى يعود فيُستأنف الدفع فوراً.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// حالة حضور جهاز واحد.
class PeerPresence {
  final String deviceId;
  final String name;
  final bool online;
  final DateTime? lastSeen;
  const PeerPresence({
    required this.deviceId,
    required this.name,
    required this.online,
    this.lastSeen,
  });
}

class PresenceService {
  final Future<Database> Function() dbProvider;
  final String ourDeviceId;

  /// يُستدعى فور اكتشاف عودة جهاز للاتصال (اسم الجهاز، معرفه).
  void Function(String deviceId, String name)? onPeerOnline;

  /// يُستدعى فور اكتشاف انقطاع جهاز.
  void Function(String deviceId, String name)? onPeerOffline;

  /// بث حالة الحضور للواجهة (يتغذى منه مؤشر الأجهزة المتصلة).
  final StreamController<List<PeerPresence>> _controller =
      StreamController<List<PeerPresence>>.broadcast();
  Stream<List<PeerPresence>> get stream => _controller.stream;

  final Map<String, bool> _lastKnown = {}; // deviceId -> online
  List<PeerPresence> _current = const [];
  List<PeerPresence> get current => _current;

  Timer? _pinger;
  bool _probing = false;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  PresenceService({required this.dbProvider, required this.ourDeviceId});

  /// عدد الأجهزة المقترنة (غير المطرودة) باستثنائنا.
  Future<int> peerCount() async {
    final db = await dbProvider();
    final r = await db.rawQuery(
      "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
      "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' "
      "AND id <> ?",
      [ourDeviceId],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  void start() {
    _pinger ??= Timer.periodic(const Duration(seconds: 3), (_) => _probeAll());
    // مناداة أولى فورية.
    _probeAll();
  }

  void stop() {
    _pinger?.cancel();
    _pinger = null;
    _client.close(force: true);
  }

  /// مناداة كل الأقران دفعة واحدة (متوازية) وتحديث حالة الحضور.
  Future<void> _probeAll() async {
    if (_probing) return; // لا تتراكم الدورات إذا تأخرت الشبكة.
    _probing = true;
    try {
      final db = await dbProvider();
      final peers = await db.query(
        'devices',
        columns: ['id', 'name', 'ip_address', 'port', 'last_seen_at'],
        where: "is_paired = 1 AND COALESCE(revoked_at,'') = '' "
            "AND COALESCE(expelled_at,'') = '' AND id <> ? AND ip_address <> ''",
        whereArgs: [ourDeviceId],
      );
      final results = await Future.wait(peers.map((p) async {
        final id = p['id'] as String;
        var name = (p['name'] as String?) ?? 'جهاز';
        final probed = await _ping(
          (p['ip_address'] as String?) ?? '',
          (p['port'] as int?) ?? 0,
        );
        final online = probed != null;
        // القرين يعلن اسمه في /status: التقط أي تغيير اسم فوراً
        // (المستخدم أعاد تسمية جهازه) وحدّث سجلنا المحلي.
        final remoteName = probed?.trim() ?? '';
        if (online && remoteName.isNotEmpty && remoteName != name) {
          name = remoteName;
          try {
            await db.update('devices', {'name': remoteName},
                where: 'id = ?', whereArgs: [id]);
          } catch (_) {}
        }
        return (id, name, online, p['last_seen_at'] as String?);
      }));

      final now = DateTime.now().toIso8601String();
      final list = <PeerPresence>[];
      for (final (id, name, online, lastSeenIso) in results) {
        final was = _lastKnown[id];
        _lastKnown[id] = online;
        if (online) {
          await db.update('devices', {'last_seen_at': now},
              where: 'id = ?', whereArgs: [id]);
        }
        list.add(PeerPresence(
          deviceId: id,
          name: name,
          online: online,
          lastSeen: DateTime.tryParse(online ? now : (lastSeenIso ?? '')),
        ));
        // انتقالات الحالة: إشعار فوري عند العودة أو الانقطاع.
        if (was != null && was != online) {
          if (online) {
            try {
              onPeerOnline?.call(id, name);
            } catch (_) {}
          } else {
            try {
              onPeerOffline?.call(id, name);
            } catch (_) {}
          }
        } else if (was == null && online) {
          // أول رصد للجهاز وهو متصل — اعتبره "عاد للاتصال" لدفع المعلّق.
          try {
            onPeerOnline?.call(id, name);
          } catch (_) {}
        }
      }
      _current = list;
      if (!_controller.isClosed) _controller.add(list);
    } catch (_) {
      // الحضور خدمة مساندة: لا يُسمح لها بإسقاط أي شيء.
    } finally {
      _probing = false;
    }
  }

  /// هل الجهاز متصل الآن (وفق آخر مناداة)؟
  bool isOnline(String deviceId) => _lastKnown[deviceId] == true;

  /// مناداة واحدة خفيفة: GET /status بمهلة قصيرة.
  /// تُعيد اسم الجهاز المعلَن إذا كان متصلاً، وnull إذا كان غائباً.
  Future<String?> _ping(String ip, int port) async {
    if (ip.isEmpty || port <= 0) return null;
    try {
      final req = await _client
          .getUrl(Uri.parse('http://$ip:$port/status'))
          .timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != HttpStatus.ok) return null;
      try {
        final m = jsonDecode(body) as Map;
        return (m['name'] as String?) ?? '';
      } catch (_) {
        return ''; // متصل لكن بلا اسم مقروء.
      }
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }
}

/// ملخص نصي لعدد المتصلين: "2/4 متصل".
String presenceSummary(List<PeerPresence> peers) {
  if (peers.isEmpty) return 'لا أجهزة مقترنة';
  final online = peers.where((p) => p.online).length;
  return '$online/${peers.length} متصل';
}

/// ترميز الحالة إلى JSON (للاختبارات وتشخيص الشاشات).
String presenceToJson(List<PeerPresence> peers) => jsonEncode([
      for (final p in peers)
        {
          'deviceId': p.deviceId,
          'name': p.name,
          'online': p.online,
          'lastSeen': p.lastSeen?.toIso8601String(),
        }
    ]);
