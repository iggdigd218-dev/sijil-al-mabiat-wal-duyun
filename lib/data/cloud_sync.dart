// المزامنة السحابية عبر Firebase Realtime Database (REST فقط، بلا SDK/تسجيل دخول).
// الأجهزة التي تحمل نفس "الرمز السحابي" تتشارك آخر نسخة محدّثة.
// منقولة من نسخة الويب (js/cloud.js) إلى التطبيق الأصلي، وتعمل على أندرويد وويندوز.
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'repository.dart';

const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

class CloudConfig {
  final String backendUrl;
  final String code;
  final bool autoSync;
  bool get ready => backendUrl.trim().isNotEmpty;
  const CloudConfig({
    required this.backendUrl,
    required this.code,
    required this.autoSync,
  });
}

class CloudSync {
  static Future<CloudConfig> config(Repo repo) async {
    final st = await repo.settings();
    return CloudConfig(
      backendUrl: (st['cloudBackendUrl'] ?? '').trim(),
      code: (st['cloudCode'] ?? '').trim(),
      autoSync: (st['cloudAutoSync'] ?? '1') != '0',
    );
  }

  static Future<void> setBackendUrl(Repo repo, String url) =>
      repo.setSetting('cloudBackendUrl', url.trim());

  static String _cleanCode(String c) {
    final clean = c.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return clean.length > 8 ? clean.substring(0, 8) : clean;
  }

  static String generateCode([int len = 5]) {
    final rnd = Random.secure();
    var s = '';
    for (var i = 0; i < len; i++) {
      s += _alphabet[rnd.nextInt(_alphabet.length)];
    }
    return s;
  }

  static Future<String> setCode(Repo repo, String code) async {
    final clean = _cleanCode(code);
    await repo.setSetting('cloudCode', clean);
    return clean;
  }

  static Future<String> ensureCode(Repo repo) async {
    final c = await config(repo);
    if (c.code.isNotEmpty) return c.code;
    final fresh = generateCode();
    await repo.setSetting('cloudCode', fresh);
    return fresh;
  }

  static String targetFor(String base, String code) {
    final root = base.replaceAll(RegExp(r'/+$'), '');
    if (RegExp(r'firebaseio\.com|firebasedatabase\.app', caseSensitive: false)
        .hasMatch(root)) {
      return '$root/codes/$code.json';
    }
    return '$root/codes/$code';
  }

  static Future<Map<String, dynamic>?> _requestJson(String target,
      {String method = 'GET', Object? body}) async {
    final uri = Uri.parse(target);
    final headers = {'Content-Type': 'application/json'};
    final res = method == 'PUT'
        ? await http.put(uri, headers: headers, body: jsonEncode(body))
        : await http.get(uri, headers: headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Cloud HTTP ${res.statusCode}');
    }
    final text = res.body.trim();
    if (text.isEmpty || text == 'null') return null;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static String _payloadTs(Map<String, dynamic>? payload) {
    return (payload?['created_at'] as String?) ?? '';
  }

  static Future<Map<String, dynamic>> status(Repo repo) async {
    final c = await config(repo);
    if (!c.ready) return {'ready': false, 'configured': false};
    if (c.code.isEmpty) {
      return {'ready': true, 'configured': true, 'hasCode': false};
    }
    try {
      final rec = await _requestJson(targetFor(c.backendUrl, c.code));
      final payload = rec?['payload'] as Map<String, dynamic>?;
      return {
        'ready': true,
        'configured': true,
        'hasCode': true,
        'code': c.code,
        'exists': payload != null,
        'updatedAt': rec?['updatedAtLocal'] ?? rec?['updatedAt'] ?? '',
        'sizeKb': rec?['sizeKb'] ?? '',
      };
    } catch (e) {
      return {
        'ready': true,
        'configured': true,
        'hasCode': true,
        'code': c.code,
        'error': '$e',
      };
    }
  }

  static Future<Map<String, dynamic>> push(
    Repo repo,
    Map<String, Object?> payload, {
    bool force = false,
  }) async {
    final c = await config(repo);
    if (!c.ready) {
      return {'ok': false, 'error': 'لم يُضبط رابط قاعدة البيانات السحابية بعد.'};
    }
    final code = c.code.isNotEmpty ? c.code : await ensureCode(repo);
    final target = targetFor(c.backendUrl, code);

    Map<String, dynamic>? existing;
    try {
      existing = await _requestJson(target);
    } catch (_) {
      existing = null;
    }
    final localTs = _payloadTs(payload);
    final remotePayload = existing?['payload'] as Map<String, dynamic>?;
    final remoteTs = _payloadTs(remotePayload);
    if (remotePayload != null && remoteTs.compareTo(localTs) > 0 && !force) {
      return {
        'ok': true,
        'skipped': true,
        'remoteIsNewer': true,
        'code': code,
        'date': existing?['updatedAtLocal'] ?? '',
      };
    }

    final now = DateTime.now();
    final kb = (jsonEncode(payload).length / 1024).toStringAsFixed(1);
    final rec = {
      'code': code,
      'app': 'sijil',
      'appVersion': 'flutter-3.8',
      'updatedAt': now.toIso8601String(),
      'updatedAtLocal': now.toLocal().toString(),
      'sizeKb': '$kb KB',
      'payload': payload,
    };
    await _requestJson(target, method: 'PUT', body: rec);
    await repo.setSetting('lastCloudSync', now.toLocal().toString());
    return {
      'ok': true,
      'code': code,
      'date': rec['updatedAtLocal'],
      'sizeKb': rec['sizeKb'],
    };
  }

  static Future<Map<String, dynamic>> pull(Repo repo) async {
    final c = await config(repo);
    if (!c.ready) {
      return {'ok': false, 'error': 'لم يُضبط رابط قاعدة البيانات السحابية بعد.'};
    }
    if (c.code.isEmpty) return {'ok': false, 'error': 'لا يوجد رمز سحابي.'};
    final rec = await _requestJson(targetFor(c.backendUrl, c.code));
    final payload = rec?['payload'] as Map<String, dynamic>?;
    if (payload == null) return {'ok': true, 'exists': false};
    return {
      'ok': true,
      'exists': true,
      'payload': payload,
      'date': rec?['updatedAtLocal'] ?? '',
      'sizeKb': rec?['sizeKb'] ?? '',
    };
  }
}
