// خدمة توليد والتحقق من رموز الاقتران المؤقتة للـ QR.
// الرمز صالح 5 دقائق، يُستخدم مرة واحدة، ولا يحتوي أسرارًا طويلة الأمد.
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'device_id.dart';

const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String _generateToken([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _chars[rnd.nextInt(_chars.length)]).join();
}

class PairingInfo {
  final String token;
  final String qrContent; // nexora://pair?...
  final DateTime expiresAt;
  const PairingInfo({required this.token, required this.qrContent, required this.expiresAt});
}

class QrPairingService {
  final Database db;
  final String ourDeviceId;
  final String? ourName;
  QrPairingService({required this.db, required this.ourDeviceId, this.ourName});

  /// يُنشئ رمز اقتران جديد مؤقت ويُسجله في devices.
  Future<PairingInfo> createPairingToken({
    required String workspaceId,
    required int port,
    String? ipAddress,
  }) async {
    final token = _generateToken();
    final expires = DateTime.now().add(const Duration(minutes: 5));
    final now = DateTime.now().toIso8601String();
    await db.update('devices',
      {'pair_token': '', 'pair_token_exp': ''},
      where: 'id = ? AND pair_token <> ?', whereArgs: [ourDeviceId, '']);
    await db.update('devices', {
      'pair_token': token,
      'pair_token_exp': expires.toIso8601String(),
      'port': port,
      if (ipAddress != null) 'ip_address': ipAddress,
      'updated_at': now,
    }, where: 'id = ?', whereArgs: [ourDeviceId]);

    // QR content: nexora://pair?ws=<workspace>&ip=<ip>&port=<port>&tok=<token>
    final params = <String, String>{
      'ws': workspaceId,
      if (ipAddress != null) 'ip': ipAddress,
      'port': '$port',
      'tok': token,
    };
    final qr = Uri(scheme: 'nexora', host: 'pair', queryParameters: params).toString();
    return PairingInfo(token: token, qrContent: qr, expiresAt: expires);
  }

  static Map<String, String>? parseQr(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'nexora' || uri.host != 'pair') return null;
      return {
        'ws': uri.queryParameters['ws'] ?? '',
        'ip': uri.queryParameters['ip'] ?? '',
        'port': uri.queryParameters['port'] ?? '43053',
        'tok': uri.queryParameters['tok'] ?? '',
      };
    } catch (_) { return null; }
  }
}
