// خدمة Firebase RTDB عبر REST — نفس قاعدة بيانات تطبيق «مدير الحسابات».
// لا تحتاج SDK: قراءة/كتابة JSON مباشرة + وقت الخادم بختم {".sv":"timestamp"}.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// مدة الخطة المتاحة للاختيار.
enum PlanDuration {
  month('شهر واحد (30 يوماً)', Duration(days: 30)),
  quarter('3 أشهر (90 يوماً)', Duration(days: 90)),
  year('سنة كاملة (365 يوماً)', Duration(days: 365)),
  lifetime('تفعيل دائم (Lifetime)', Duration(days: 365 * 100));

  final String label;
  final Duration span;
  const PlanDuration(this.label, this.span);
}

/// نتيجة تفعيل ناجحة — للعرض في الرسالة الخضراء.
class ActivationResult {
  final String workspaceId;
  final String planType;
  final int maxDevices;
  final int expiresAtMs;
  final bool lifetime;
  const ActivationResult({
    required this.workspaceId,
    required this.planType,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.lifetime,
  });
}

/// سجل مشترك للعرض في القائمة.
class SubscriberEntry {
  final String workspaceId;
  final String planType;
  final String status;
  final int maxDevices;
  final int expiresAtMs;
  final int activatedAtMs;
  final String deviceRef; // المعرف/البصمة التي أُدخلت وقت التفعيل.
  const SubscriberEntry({
    required this.workspaceId,
    required this.planType,
    required this.status,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.activatedAtMs,
    required this.deviceRef,
  });
}

class Rtdb {
  Rtdb._();
  static final Rtdb instance = Rtdb._();

  /// عميل HTTP موحد: يعيد استخدام اتصال TCP/TLS نفسه عبر كل الطلبات
  /// (keep-alive) بدل فتح اتصال جديد لكل طلب — أسرع بمرات على الجوال.
  final http.Client _client = http.Client();

  String baseUrl = '';
  String authToken = ''; // اختياري: legacy secret أو ID token.

  static const _kUrl = 'rtdbUrl';
  static const _kAuth = 'rtdbAuth';

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    baseUrl = sp.getString(_kUrl) ?? '';
    authToken = sp.getString(_kAuth) ?? '';
  }

  Future<void> save(String url, String auth) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    authToken = auth.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, baseUrl);
    await sp.setString(_kAuth, authToken);
  }

  bool get configured => baseUrl.isNotEmpty;

  Uri _u(String path, [Map<String, String>? q]) {
    final qp = <String, String>{...?q};
    if (authToken.isNotEmpty) qp['auth'] = authToken;
    return Uri.parse('$baseUrl/$path.json')
        .replace(queryParameters: qp.isEmpty ? null : qp);
  }

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final r = await _client.get(_u(path, q)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception('قراءة $path فشلت (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<void> _patch(String path, Map<String, dynamic> body) async {
    final r = await _client
        .patch(_u(path), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception('كتابة $path فشلت (${r.statusCode}): ${r.body}');
    }
  }

  Future<void> _put(String path, Object body) async {
    final r = await _client
        .put(_u(path), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception('كتابة $path فشلت (${r.statusCode}): ${r.body}');
    }
  }

  /// وقت خادم فيربيس الحقيقي — نكتب {".sv":"timestamp"} ونقرأ الناتج.
  /// كل الحسابات الزمنية بساعة الخادم حصراً، لا ساعة الهاتف.
  Future<int> serverNowMs() async {
    await _put('server_clock', {'.sv': 'timestamp'});
    final v = await _get('server_clock');
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw Exception('تعذّر قراءة ساعة الخادم');
  }

  /// تحويل المدخل إلى معرف مساحة عمل — يقبل ثلاثة أشكال تلقائياً:
  ///  1) بصمة التفعيل (32 خانة hex من رسالة واتساب) ⇒ فهرس /trials/<fp>.
  ///  2) معرف الجهاز (DEVICE-XXXXXXXX…) ⇒ بحث في roster كل المساحات.
  ///  3) معرف مساحة العمل مباشرة ⇒ تحقق من وجود العقدة.
  Future<String> resolveWorkspaceId(String input) async {
    final id = input.trim();
    if (id.isEmpty) throw Exception('أدخل معرف الجهاز أو مساحة العمل أولاً');

    // (1) بصمة تفعيل 32-hex.
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      final t = await _get('trials/${Uri.encodeComponent(id)}');
      if (t is Map && '${t['workspace_id'] ?? ''}'.isNotEmpty) {
        return '${t['workspace_id']}';
      }
      throw Exception('لم يُعثر على مساحة عمل مرتبطة بهذه البصمة.\n'
          'تأكد أن العميل فتح التطبيق مرة واحدة على الأقل بعد التثبيت.');
    }

    // (2) معرف جهاز DEVICE-… ⇒ نفتش سجل التفعيلات ثم بصمات /trials ثم
    //     roster المساحات عن هذا الجهاز.
    if (RegExp(r'^DEVICE-[A-Z2-9]{6,}', caseSensitive: false).hasMatch(id)) {
      final devId = id.toUpperCase();
      // فهرس التجارب يحمل workspace_id — أرخص مسح.
      final trials = await _get('trials');
      if (trials is Map) {
        for (final v in trials.values) {
          if (v is Map && '${v['device_id'] ?? ''}'.toUpperCase() == devId) {
            final ws = '${v['workspace_id'] ?? ''}';
            if (ws.isNotEmpty) return ws;
          }
        }
      }
      // مسح roster لكل مساحة (قراءة مفاتيح سطحية ثم roster المطابق).
      final keys = await _get('workspaces', {'shallow': 'true'});
      if (keys is Map) {
        for (final ws in keys.keys) {
          final roster =
              await _get('workspaces/${Uri.encodeComponent('$ws')}/roster');
          if (roster is Map &&
              roster.keys.any((k) => '$k'.toUpperCase() == devId)) {
            return '$ws';
          }
        }
      }
      throw Exception('لم يُعثر على جهاز بهذا المعرف في أي مساحة عمل.\n'
          'جرّب لصق «بصمة التفعيل» من رسالة العميل بدلاً منه.');
    }

    // (3) معرف مساحة مباشر — نتحقق من وجود عقدة الاشتراك أو المساحة.
    final sub = await _get('workspaces/${Uri.encodeComponent(id)}/subscription');
    if (sub != null) return id;
    final ws = await _get('workspaces/${Uri.encodeComponent(id)}',
        {'shallow': 'true'});
    if (ws != null) return id;
    throw Exception('لا توجد مساحة عمل بهذا المعرف في قاعدة البيانات.');
  }

  /// التفعيل/الترقية: تحديث عقدة الاشتراك في المكان (PATCH يحفظ الحقول
  /// الأخرى مثل created_at وdevice_fingerprint) وفتح كل المزايا.
  Future<ActivationResult> activate({
    required String rawInput,
    required String planType, // individual | enterprise
    required PlanDuration duration,
    required int maxDevices,
    bool extend = false, // تمديد: يضيف المدة فوق expires_at الحالي إن كان أبعد.
  }) async {
    final ws = await resolveWorkspaceId(rawInput);
    final now = await serverNowMs();
    final lifetime = duration == PlanDuration.lifetime;

    int base = now;
    if (extend) {
      final cur = await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
      if (cur is Map) {
        final e = cur['expires_at'];
        final curExp = e is num ? e.toInt() : 0;
        if (curExp > now) base = curExp; // التمديد يبني على المتبقي.
      }
    }
    final expires = base + duration.span.inMilliseconds;

    await _patch('workspaces/${Uri.encodeComponent(ws)}/subscription', {
      'status': 'active',
      'is_active': true,
      'plan_type': planType,
      'max_devices': planType == 'enterprise' ? maxDevices : 1,
      'expires_at': expires,
      'activated_at': now,
      'activated_by': 'license_admin',
      'features': {
        'can_use_categories': true,
        'can_send_notifications': true,
        'can_cloud_backup': true,
        'can_restore_data': true,
        'can_advanced_search': true,
        'multi_device_sync': true,
        'role_permissions': true,
        'audit_log': true,
      },
    });

    // مزامنة فهرس /trials (مصدر العدادات المجمعة): التفعيل يقلب حالة
    // المساحة فيه أيضاً حتى تعكس بطاقة «مشتركون مدفوعون» الحقيقة فوراً.
    try {
      final cur =
          await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
      final fp = cur is Map ? '${cur['device_fingerprint'] ?? ''}' : '';
      if (fp.isNotEmpty) {
        await _patch('trials/${Uri.encodeComponent(fp)}', {
          'status': 'active',
          'expires_at': expires,
          'workspace_id': ws,
        });
      }
    } catch (_) {} // الفهرس تحسيني — فشله لا يفسد التفعيل.

    // سجل إداري للمشتركين — يغذي شاشة «سجل المشتركين».
    await _put('admin/activations/$now', {
      'workspace_id': ws,
      'device_ref': rawInput.trim(),
      'plan_type': planType,
      'max_devices': planType == 'enterprise' ? maxDevices : 1,
      'expires_at': expires,
      'activated_at': now,
      'lifetime': lifetime,
    });

    return ActivationResult(
      workspaceId: ws,
      planType: planType,
      maxDevices: planType == 'enterprise' ? maxDevices : 1,
      expiresAtMs: expires,
      lifetime: lifetime,
    );
  }

  /// آخر الاشتراكات المفعلة (من السجل الإداري) مع الحالة الحية لكل مساحة.
  Future<List<SubscriberEntry>> recentSubscribers({int limit = 30}) async {
    final raw = await _get('admin/activations', {
      'orderBy': '"\$key"',
      'limitToLast': '$limit',
    });
    if (raw is! Map) return const [];
    final out = <SubscriberEntry>[];
    for (final e in raw.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final ws = '${v['workspace_id'] ?? ''}';
      // الحالة الحية من عقدة الاشتراك نفسها (قد تكون مُدِّدت لاحقاً).
      String status = 'active';
      int expires = (v['expires_at'] is num) ? (v['expires_at'] as num).toInt() : 0;
      int maxDev = (v['max_devices'] is num) ? (v['max_devices'] as num).toInt() : 1;
      String plan = '${v['plan_type'] ?? 'individual'}';
      try {
        final live =
            await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
        if (live is Map) {
          status = '${live['status'] ?? status}';
          if (live['expires_at'] is num) {
            expires = (live['expires_at'] as num).toInt();
          }
          if (live['max_devices'] is num) {
            maxDev = (live['max_devices'] as num).toInt();
          }
          plan = '${live['plan_type'] ?? plan}';
        }
      } catch (_) {}
      out.add(SubscriberEntry(
        workspaceId: ws,
        planType: plan,
        status: status,
        maxDevices: maxDev,
        expiresAtMs: expires,
        activatedAtMs:
            (v['activated_at'] is num) ? (v['activated_at'] as num).toInt() : 0,
        deviceRef: '${v['device_ref'] ?? ''}',
      ));
    }
    out.sort((a, b) => b.activatedAtMs.compareTo(a.activatedAtMs));
    return out;
  }
}

/// إحصائيات لوحة المدير — تُقرأ حياً من قاعدة البيانات.
class AdminMetrics {
  final int totalWorkspaces; // إجمالي مساحات العمل المسجلة.
  final int activePaid; // مشتركون مدفوعون فعّالون.
  final int activeTrials; // في الفترة التجريبية (سارية).
  final int expired; // منتهية (تجربة أو اشتراك) = الفئة المجانية.
  const AdminMetrics({
    required this.totalWorkspaces,
    required this.activePaid,
    required this.activeTrials,
    required this.expired,
  });
}

extension RtdbMetrics on Rtdb {
  /// جمع العدادات بلا اختناق: كان الشكل القديم يطلق طلب HTTP منفصلاً
  /// لكل مساحة (N+1). الآن قراءة مجمعة واحدة لفهرس /trials (يحمل
  /// status/expires_at لكل مساحة مفعّلة) + مفاتيح المساحات السطحية —
  /// طلبان اثنان مهما بلغ عدد العملاء، عبر عميل keep-alive موحد.
  Future<AdminMetrics> metrics() async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) {
      return const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0);
    }
    final now = await serverNowMs();
    int paid = 0, trials = 0, expired = 0;

    // القراءة المجمعة: فهرس التجارب يحمل حالة كل مساحة مفعّلة.
    final trialIdx = await _get('trials');
    final byWs = <String, Map>{};
    if (trialIdx is Map) {
      for (final v in trialIdx.values) {
        if (v is Map) {
          final ws = '${v['workspace_id'] ?? ''}';
          if (ws.isNotEmpty) byWs[ws] = v;
        }
      }
    }
    // مساحات غير مفهرسة في /trials (نادرة — قديمة جداً): قراءة مفردة
    // كاحتياط، بحد أقصى 25 حتى لا نعود للاختناق.
    final missing =
        keys.keys.map((k) => '$k').where((w) => !byWs.containsKey(w)).toList();
    for (final ws in missing.take(25)) {
      try {
        final sub =
            await _get('workspaces/${Uri.encodeComponent(ws)}/subscription');
        if (sub is Map) byWs[ws] = sub;
      } catch (_) {}
    }

    for (final ws in keys.keys) {
      final sub = byWs['$ws'];
      if (sub == null) continue; // مساحة بلا عقدة اشتراك بعد.
      final status = '${sub['status'] ?? ''}';
      final e = sub['expires_at'];
      final exp = e is num ? e.toInt() : 0;
      final alive = exp > now;
      if (status == 'active' && alive) {
        paid++;
      } else if (status == 'trial' && alive) {
        trials++;
      } else {
        expired++;
      }
    }
    return AdminMetrics(
      totalWorkspaces: keys.length,
      activePaid: paid,
      activeTrials: trials,
      expired: expired,
    );
  }
}
