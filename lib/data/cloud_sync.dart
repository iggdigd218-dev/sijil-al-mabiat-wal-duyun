// المزامنة السحابية عبر Firebase Realtime Database (REST فقط، بلا SDK/تسجيل دخول).
// الأجهزة التي تحمل نفس "الرمز السحابي" تتشارك آخر نسخة محدّثة.
// منقولة من نسخة الويب (js/cloud.js) إلى التطبيق الأصلي، وتعمل على أندرويد وويندوز.
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/app_version.dart';
import 'repository.dart';
import 'sync/subscription_guard.dart';
import '../core/cloud_config.dart';

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
      backendUrl: effectiveBackendUrl(st['cloudBackendUrl']),
      code: (st['cloudCode'] ?? '').trim(),
      autoSync: kCloudAutoSyncAlways, // مثبتة دائماً (المعمارية الصامتة).
    );
  }

  static Future<void> setBackendUrl(Repo repo, String url) async {
    final t = url.trim();
    // رابط غير https يفشل النقل الفعلي (CloudFirebaseTransport يرفضه) —
    // نرفضه هنا مبكراً بدل حفظه ثم فشل صامت لاحقاً.
    if (t.isNotEmpty) {
      final u = Uri.tryParse(t);
      if (u == null || !u.hasScheme || !u.isScheme('https')) {
        throw ArgumentError('رابط قاعدة البيانات يجب أن يبدأ بـ https://');
      }
    }
    await repo.setSetting('cloudBackendUrl', t);
    // 🔒 أول ضبط لرابط سحابي = بدء الفترة التجريبية (خلفي، لا يعطل الحفظ).
    if (t.isNotEmpty) {
      try {
        final db = await repo.database;
        final wsRows = await db.query('workspaces', limit: 1);
        final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
        await SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: t, workspaceId: ws);
      } catch (_) {
        // شبكة غائبة الآن — check() سيفعّلها عند أول فحص ناجح.
      }
    }
  }

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
    if (RegExp(
      r'firebaseio\.com|firebasedatabase\.app',
      caseSensitive: false,
    ).hasMatch(root)) {
      return '$root/codes/$code.json';
    }
    return '$root/codes/$code';
  }

  static Future<Map<String, dynamic>?> _requestJson(
    String target, {
    String method = 'GET',
    Object? body,
  }) async {
    final uri = Uri.parse(target);
    final headers = {'Content-Type': 'application/json'};
    // مهلات صريحة: النسخ الكاملة قد تكون كبيرة (رفع أبطأ من القراءة)،
    // وغياب المهلة كان يترك الواجهة معلّقة للأبد عند شبكة سيئة.
    final res = method == 'PUT'
        ? await http
            .put(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 60))
        : await http.get(uri, headers: headers).timeout(
            const Duration(seconds: 30));
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
      return {
        'ok': false,
        'error': 'لم يُضبط رابط قاعدة البيانات السحابية بعد.',
      };
    }
    // 🔒 (التجربة) انتهاء الفترة يوقف النسخ الاحتياطي السحابي.
    try {
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      final blocked = await SubscriptionGuard.isBlocked(repo,
          backendUrl: c.backendUrl, workspaceId: ws);
      if (blocked) {
        return {
          'ok': false,
          'trialExpired': true,
          'error': '⏳ انتهت الفترة التجريبية — النسخ السحابي متوقف. '
              'فعّل اشتراكك لاستئناف النسخ الاحتياطي.',
        };
      }
    } catch (_) {}
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
      'appVersion': '$kAppVersion+$kAppBuild',
      'updatedAt': now.toIso8601String(),
      'updatedAtLocal': now.toLocal().toString(),
      'sizeKb': '$kb KB',
      'payload': payload,
    };
    try {
      await _requestJson(target, method: 'PUT', body: rec);
    } catch (e) {
      return {'ok': false, 'error': 'فشل الرفع إلى السحابة: $e'};
    }
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
      return {
        'ok': false,
        'error': 'لم يُضبط رابط قاعدة البيانات السحابية بعد.',
      };
    }
    if (c.code.isEmpty) return {'ok': false, 'error': 'لا يوجد رمز سحابي.'};
    Map<String, dynamic>? rec;
    try {
      rec = await _requestJson(targetFor(c.backendUrl, c.code));
    } catch (e) {
      return {'ok': false, 'error': 'تعذّر الاتصال بالسحابة: $e'};
    }
    final payload = rec?['payload'];
    if (payload == null) return {'ok': true, 'exists': false};
    // تحقق صارم: يجب أن تكون الحمولة خريطة فيها بيانات مفهومة.
    if (payload is! Map) {
      return {'ok': false, 'error': 'محتوى النسخة السحابية غير صالح.'};
    }
    final map = Map<String, Object?>.from(payload);
    final data = map['data'];
    final hasTables = data is Map && data.isNotEmpty;
    if (!hasTables) {
      return {
        'ok': false,
        'error': 'النسخة السحابية فارغة أو تالفة، لم يُمسّ شيء.',
      };
    }
    return {
      'ok': true,
      'exists': true,
      'payload': map,
      'date': rec?['updatedAtLocal'] ?? '',
      'sizeKb': rec?['sizeKb'] ?? '',
    };
  }

  // ==================== النسخ السحابي الصامت (المعمارية الصامتة) ====================
  //
  // بلا رابط ولا رمز من المستخدم: النسخة الكاملة تُرفع تلقائياً إلى مسار
  // مساحة العمل الحالية على القاعدة الرسمية المضمّنة:
  //   /workspaces/{WS_ID}/backup.json
  // تُستدعى من دورة صيانة محرك المزامنة مرة كل 24 ساعة كحد أقصى.

  static const silentBackupInterval = Duration(hours: 24);

  /// هل حان موعد النسخة الصامتة التالية؟
  static Future<bool> silentBackupDue(Repo repo) async {
    final st = await repo.settings();
    final last = DateTime.tryParse(st['lastSilentBackupAt'] ?? '');
    if (last == null) return true;
    return DateTime.now().difference(last) >= silentBackupInterval;
  }

  /// يرفع نسخة كاملة صامتة لمسار مساحة العمل — أفضل جهد: أي فشل يُبتلع
  /// (شبكة غائبة/اشتراك منتهٍ) وتُعاد المحاولة في الدورة القادمة.
  static Future<bool> silentWorkspaceBackup(Repo repo) async {
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return false;
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      // 🔒 انتهاء الفترة التجريبية يوقف النسخ الصامت أيضاً.
      final blocked = await SubscriptionGuard.isBlocked(repo,
          backendUrl: url, workspaceId: ws);
      if (blocked) return false;
      final payload = await repo.exportAll(withImages: false);
      final now = DateTime.now();
      final rec = {
        'app': 'sijil',
        'appVersion': '$kAppVersion+$kAppBuild',
        'workspaceId': ws,
        'updatedAt': now.toIso8601String(),
        'updatedAtLocal': now.toLocal().toString(),
        'sizeKb':
            '${(jsonEncode(payload).length / 1024).toStringAsFixed(1)} KB',
        'payload': payload,
      };
      final root = url.replaceAll(RegExp(r'/+$'), '');
      await _requestJson(
        '$root/workspaces/${Uri.encodeComponent(ws)}/backup.json',
        method: 'PUT',
        body: rec,
      );
      await repo.setSetting('lastSilentBackupAt', now.toIso8601String());
      await repo.setSetting('lastCloudSync', now.toLocal().toString());
      return true;
    } catch (_) {
      return false;
    }
  }
}
