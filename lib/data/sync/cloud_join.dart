// الانضمام إلى المجموعة عبر السحابة (بدون شبكة محلية) + سجل الأجهزة السحابي.
//
// الفكرة:
//  - المدير ينشئ «دعوة سحابية»: يرفع لقطة كاملة من بيانات المجموعة إلى
//    {base}/workspaces/{ws}/joinSnapshot ورمز دعوة مؤقت (24 ساعة، يُستخدم مرة
//    واحدة) إلى {base}/workspaces/{ws}/invites/{TOKEN}.
//  - الجهاز الجديد يُدخل الرابط + رمز الدعوة (أو يمسح QR): تُحذف جميع بياناته
//    المحلية بالكامل داخل معاملة واحدة وتُستبدل بنسخة المجموعة، ثم يصبح عضواً
//    ويتزامن تلقائياً عبر نفس رابط السحابة الذي يستخدمه المدير.
//  - سجل الأجهزة السحابي (roster): كل جهاز يرفع سجله (بلا أسرار) إلى
//    {base}/workspaces/{ws}/roster/{deviceId}؛ المدير يرفع سجلات كل الأجهزة
//    (هو المرجع في التعيين/الحظر/الطرد). عند كل سحب سحابي تُدمج السجلات
//    بالأحدث (updated_at) فيرى المدير جهاز العضو البعيد ويعيّن له مستخدماً
//    وصلاحيات، ويصل التعيين/الطرد للعضو خلال دورة سحب واحدة.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/models.dart';
import '../repository.dart';
import 'device_id.dart';
import 'snapshot_apply.dart';
import 'subscription_guard.dart';
import '../../core/cloud_config.dart';

const _tokenChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String _newToken([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _tokenChars[rnd.nextInt(_tokenChars.length)])
      .join();
}

/// رمز PIN رقمي من 6 خانات — لأجهزة سطح المكتب بلا كاميرا.
String newPairPin() {
  final rnd = Random.secure();
  return List.generate(6, (_) => '${rnd.nextInt(10)}').join();
}

/// بيانات دعوة انضمام سحابية جاهزة للعرض/المشاركة.
class CloudInviteInfo {
  final String backendUrl;
  final String workspaceId;
  final String token;
  final String cloudCode;
  final DateTime expiresAt;

  /// PIN بشري من 6 أرقام يظهر تحت QR — لأجهزة سطح المكتب بلا كاميرا.
  final String pin;
  const CloudInviteInfo({
    required this.backendUrl,
    required this.workspaceId,
    required this.token,
    required this.cloudCode,
    required this.expiresAt,
    this.pin = '',
  });

  /// محتوى QR: nexora://cloudjoin?url=...&ws=...&tok=...&code=...
  String get qrContent => Uri(
        scheme: 'nexora',
        host: 'cloudjoin',
        queryParameters: {
          'url': backendUrl,
          'ws': workspaceId,
          'tok': token,
          if (cloudCode.isNotEmpty) 'code': cloudCode,
        },
      ).toString();

  static Map<String, String>? parseQr(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'nexora' || uri.host != 'cloudjoin') return null;
      return {
        'url': uri.queryParameters['url'] ?? '',
        'ws': uri.queryParameters['ws'] ?? 'default',
        'tok': uri.queryParameters['tok'] ?? '',
        'code': uri.queryParameters['code'] ?? '',
      };
    } catch (_) {
      return null;
    }
  }
}

/// (دفعة 57) مراقب SSE لطلبات الانضمام — يستبدل استطلاع الـ 5 ثوانٍ:
/// قناة بث حيّة على /workspaces/$ws/joinRequests.json تُنبّه المدير
/// لحظياً (صفر كمون) عند وصول طلب اقتران جديد. أول حدث put يحمل
/// اللقطة الحالية فيلتقط الطلبات المعلقة سلفاً أيضاً. إعادة اتصال
/// بتراجع أسّي 4→180 ثانية عند انقطاع الشبكة.
///
/// (تكملة) [nodePath] يعمّم القناة: العضو المنتظر يراقب عقدته
/// 'joinRequests/&lt;deviceId&gt;' فيلتقط قرار المدير (approve/reject)
/// لحظة كتابته بدل انتظار دورة الاستطلاع.
class JoinRequestWatcher {
  final String backendUrl;
  final String workspaceId;
  final String nodePath;
  final void Function() onRequestsChanged;

  JoinRequestWatcher({
    required this.backendUrl,
    this.workspaceId = 'default',
    this.nodePath = 'joinRequests',
    required this.onRequestsChanged,
  });

  bool _running = false;
  HttpClient? _client;
  int _retrySeconds = 4;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  Future<void> _loop() async {
    final root =
        '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';
    while (_running) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _client = client;
        final req = await client.getUrl(Uri.parse('$root/$nodePath.json'));
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Cache-Control', 'no-cache');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw StateError('join-sse-http-${resp.statusCode}');
        }
        _retrySeconds = 4;
        String? eventName;
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_running) break;
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventName == 'put' || eventName == 'patch') {
              final raw = line.substring(5).trim();
              try {
                final m = jsonDecode(raw);
                if (m is Map && m['data'] != null) {
                  onRequestsChanged();
                }
              } catch (_) {}
            } else if (eventName == 'auth_revoked') {
              break; // أعد الاتصال.
            }
          }
        }
      } catch (_) {
        // شبكة — تراجع ثم إعادة محاولة.
      } finally {
        try {
          _client?.close(force: true);
        } catch (_) {}
        _client = null;
      }
      if (!_running) break;
      await Future<void>.delayed(Duration(seconds: _retrySeconds));
      _retrySeconds = (_retrySeconds * 2).clamp(4, 180);
    }
  }
}

class CloudJoinException implements Exception {
  final String message;
  const CloudJoinException(this.message);
  @override
  String toString() => message;
}

class CloudJoin {
  /// (دفعة 53) خطاف الطرد الذاتي: يضبطه SyncEngine عند الإقلاع ليتولى
  /// المعالجة المركزية (إيقاف SSE/الدفع + تنظيف الجلسة + بث للواجهة)
  /// بدل الاكتفاء بإعادة الضبط الصامتة.
  static Future<void> Function()? onSelfEvicted;

  /// 🔒 (التجربة) يرمي CloudJoinException إذا انتهت الفترة التجريبية —
  /// حارس ربط الأجهزة الجديدة (دعوة/موافقة).
  static Future<void> _ensureSubscriptionAllows(Repo repo) async {
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return;
      final db = await repo.database;
      final wsRows = await db.query('workspaces', limit: 1);
      final ws = wsRows.isNotEmpty ? '${wsRows.first['id']}' : 'default';
      final blocked = await SubscriptionGuard.isBlocked(repo,
          backendUrl: url, workspaceId: ws);
      if (blocked) {
        throw const CloudJoinException(
            '⏳ انتهت الفترة التجريبية — ربط الأجهزة الجديدة متوقف. '
            'فعّل اشتراكك لاستئناف كل المزايا السحابية.');
      }
    } on CloudJoinException {
      rethrow;
    } catch (_) {
      // تعذر الفحص (شبكة) — لا نمنع؛ بوابة المزامنة الدورية تحسم لاحقاً.
    }
  }

  /// (باقة المؤسسات) عدد الأجهزة المتصلة حالياً بالمجموعة: مقترنة وغير
  /// مطرودة/ملغاة — يُعرض في عدّاد المقاعد ويُفحص قبل أي ربط جديد.
  static Future<int> connectedDevicesCount(Repo repo) async {
    final db = await repo.database;
    final rows = await db.rawQuery(
        "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
        "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''");
    return (rows.first['c'] as int?) ?? 0;
  }

  /// (باقة المؤسسات) بوابة المقاعد: ربط جهاز جديد يتجاوز max_devices
  /// يُرفض برسالة المدير الواضحة. الجهاز المنضم مجدداً (سجله قائم) لا
  /// يستهلك مقعداً جديداً. فشل قراءة العقدة سحابياً = سماح (fail-open،
  /// بوابة المزامنة الدورية تحسم لاحقاً).
  static Future<void> _ensureSeatAvailable(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String joiningDeviceId,
  }) async {
    int maxDevices;
    Map<String, dynamic>? rosterCloud;
    try {
      final rec = await _getJson(
          '${_root(backendUrl, workspaceId)}/subscription.json');
      if (rec == null) return; // لا عقدة اشتراك بعد — لا حد مفروضاً.
      final v = rec['max_devices'];
      maxDevices = v is num ? v.toInt() : 0;
      if (maxDevices <= 0) return; // غير محدد = بلا حد.
      // (احتساب ذري) roster السحابي هو المصدر المشترك اللحظي بين كل
      // الأجهزة — الجدول المحلي قد يتخلف عن موافقات جرت على جهاز آخر
      // للتو، فكان يرفض/يقبل خطأً. نقرأه في نفس لحظة القرار.
      final r = await _getJson('${_root(backendUrl, workspaceId)}/roster.json');
      if (r != null) rosterCloud = Map<String, dynamic>.from(r);
    } catch (_) {
      return; // شبكة متعثرة — لا نعطل الموافقة؛ البوابات الدورية تحسم.
    }
    // إعادة انضمام جهاز قائم (له مقعد في roster أو محلياً) لا تستهلك
    // مقعداً جديداً — تجديد لسجله القديم.
    bool activeRow(Map d) =>
        '${d['revoked_at'] ?? ''}'.isEmpty &&
        '${d['expelled_at'] ?? ''}'.isEmpty;
    if (rosterCloud != null) {
      final mine = rosterCloud[joiningDeviceId];
      if (mine is Map && activeRow(mine)) return;
    }
    final db = await repo.database;
    final existing = await db.query('devices',
        where: "id = ? AND is_paired = 1 AND COALESCE(revoked_at,'') = '' "
            "AND COALESCE(expelled_at,'') = ''",
        whereArgs: [joiningDeviceId],
        limit: 1);
    if (existing.isNotEmpty) return;
    // العدد الفعلي: الأكبر بين roster السحابي والمحلي (أيهما أحدث) —
    // لا يُرفض جهاز ضمن الحصة، ولا يُقبل جهاز فوقها بسباق تحديث.
    int current = await connectedDevicesCount(repo);
    if (rosterCloud != null) {
      final cloudCount = rosterCloud.values
          .whereType<Map>()
          .where(activeRow)
          .length;
      if (cloudCount > current) current = cloudCount;
    }
    if (current >= maxDevices) {
      throw CloudJoinException(
          '🪑 تم استنفاد عدد الأجهزة المسموح بها لهذه الباقة '
          '($current/$maxDevices). يرجى ترقية الاشتراك لإضافة أجهزة جديدة.');
    }
  }

  static String _root(String base, String ws) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';

  // ============ (الاسترداد السيادي) سجل منشئ المساحة الدائم ============

  /// يسجل creator_device_id لمساحة العمل مرة واحدة فقط — إن كانت العقدة
  /// موجودة لا تُلمس أبداً (غير قابلة للتغيير)، مهما تنقّلت الملكية.
  static Future<void> registerCreatorIfAbsent(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
  }) async {
    final path = '${_root(backendUrl, workspaceId)}/creator.json';
    final existing = await _getJson(path);
    if (existing != null &&
        '${existing['creator_device_id'] ?? ''}'.isNotEmpty) {
      return; // مسجل مسبقاً — لا يتغير أبداً.
    }
    await _putJson(path, {
      'creator_device_id': deviceId,
      'registered_at': DateTime.now().toIso8601String(),
      'immutable': true,
    }, timeout: const Duration(seconds: 20));
    // نسخة محلية للعرض السريع دون شبكة.
    try {
      await repo.setSetting('creatorDeviceId', deviceId);
    } catch (_) {}
  }

  /// يجلب معرف جهاز منشئ المساحة من السحابة (أو '' إن لم يسجل بعد).
  static Future<String> fetchCreatorDeviceId({
    required String backendUrl,
    required String workspaceId,
  }) async {
    final rec =
        await _getJson('${_root(backendUrl, workspaceId)}/creator.json');
    return '${rec?['creator_device_id'] ?? ''}';
  }

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudJoinException('تعذّر الاتصال بالسحابة (HTTP ${res.statusCode})');
    }
    final t = res.body.trim();
    if (t.isEmpty || t == 'null') return null;
    final d = jsonDecode(t);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  static Future<void> _putJson(String url, Object body,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final res = await http
        .put(Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudJoinException('فشل الرفع إلى السحابة (HTTP ${res.statusCode})');
    }
  }

  static Future<void> _delete(String url) async {
    try {
      await http.delete(Uri.parse(url)).timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  /// حذف حتمي: يفشل بصوت عالٍ إن لم يتأكد الحذف من الخادم (يُعاد المحاولة
  /// مرة واحدة). يُستخدم لإبطال توكن الدعوة — تركه حياً ثغرة أمنية.
  static Future<void> _deleteStrict(String url) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await http
            .delete(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        // فيربيس يرد 200 على حذف مسار (حتى غير الموجود) — أي 2xx يكفي.
        if (res.statusCode >= 200 && res.statusCode < 300) return;
      } catch (_) {
        // خطأ شبكة — جرّب مرة أخيرة.
      }
    }
    throw const CloudJoinException(
        'تعذّر إبطال رمز الدعوة على السحابة — أُلغي الانضمام حفاظاً على الأمان. '
        'تحقق من الاتصال وأعد المحاولة بدعوة جديدة.');
  }

  static void _validateHttps(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || !u.isScheme('https')) {
      throw const CloudJoinException(
          'رابط قاعدة البيانات يجب أن يبدأ بـ https://');
    }
  }

  /// سجل جهاز بصيغة آمنة للرفع (بلا أسرار ولا رموز اقتران).
  static Map<String, Object?> _safeDeviceRow(Map<String, Object?> d) {
    final m = Map<String, Object?>.from(d);
    m['auth_secret'] = '';
    m['pair_token'] = '';
    m['pair_token_exp'] = '';
    // (دفعة 58) أعمدة LAN أُسقطت من المخطط — صفوف roster من إصدارات
    // أقدم قد تحملها فتفشل الإدراج/التحديث.
    m.remove('ip_address');
    m.remove('port');
    return m;
  }

  // ==================== إنشاء الدعوة (المدير) ====================

  /// يرفع لقطة كاملة + رمز دعوة صالح 24 ساعة، ويعيد بيانات الدعوة للعرض.
  static Future<CloudInviteInfo> createInvite(Repo repo) async {
    // الملكية الفعلية (is_owner) هي الحكم — لا وضع sync_meta وحده:
    // خلل سابق كان ينسخ workspaceMode من جهاز عضو أثناء المصالحة فيقلب
    // جهاز المدير إلى «member» زوراً. إن كنا المالك فعلاً نصلح الوضع ذاتياً.
    final owner = await repo.isWorkspaceOwner();
    if (!owner) {
      throw const CloudJoinException(
          'إنشاء دعوة سحابية متاح لجهاز المدير (المالك) فقط.');
    }
    // 🔒 (التجربة) انتهاء الفترة يمنع ربط أجهزة جديدة.
    await _ensureSubscriptionAllows(repo);
    // (الخطط المزدوجة) فتح كود ربط لجهاز ثانٍ = تحول تلقائي لمسار
    // المؤسسات بمقاعده — دون المساس بالعداد الزمني للتجربة.
    try {
      final st0 = await repo.settings();
      final url0 = effectiveBackendUrl(st0['cloudBackendUrl']);
      if (url0.isNotEmpty) {
        final db0 = await repo.database;
        final wsRows0 = await db0.query('workspaces', limit: 1);
        final ws0 =
            wsRows0.isNotEmpty ? '${wsRows0.first['id']}' : 'default';
        await SubscriptionGuard.promoteToEnterprise(repo,
            backendUrl: url0, workspaceId: ws0);
        // 🪑 حد المقاعد: لا معنى لدعوة جديدة والمقاعد مستنفدة — نرفض
        // مبكراً برسالة المدير بدل فشل متأخر عند موافقة العضو.
        await _ensureSeatAvailable(repo,
            backendUrl: url0,
            workspaceId: ws0,
            joiningDeviceId: '__new__');
      }
    } on CloudJoinException {
      rethrow;
    } catch (_) {}
    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      final db0 = await repo.database;
      await db0.insert(
          'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final st = await repo.settings();
    final url = effectiveBackendUrl(st['cloudBackendUrl']);
    if (url.isEmpty) {
      throw const CloudJoinException(
          'اضبط رابط قاعدة البيانات السحابية أولاً من الإعدادات ← المزامنة السحابية.');
    }
    _validateHttps(url);

    final db = await repo.database;
    final wsRows = await db.query('workspaces', limit: 1);
    final ws = wsRows.isNotEmpty ? (wsRows.first['id'] as String) : 'default';
    final ourId = await ensureDeviceId(repo);

    // لقطة بنفس بنية لقطة الاقتران المحلي (تُطبَّق بنفس الدالة عند العضو).
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
          // عبر السحابة لا نوزّع أسرار الأجهزة إطلاقاً — المصادقة السحابية
          // لا تحتاجها، والدعوة نفسها هي إثبات الانضمام.
          row['auth_secret'] = '';
          row['pair_token'] = '';
          row['pair_token_exp'] = '';
        }
        return row;
      }).toList();
    }
    snapshot['workspaceMode'] = 'member';
    snapshot['hostDeviceId'] = ourId;
    // إعدادات المؤسسة (اسم/عنوان/تذييل السند...) تُنقل مع اللقطة لتحل
    // محل إعدادات الجهاز المنضم القديمة — «حذف كامل» يشمل هويته السابقة.
    try {
      final orgRows = await db.query('settings',
          where:
              "key IN ('businessName','businessNameEn','address','phone','whatsapp','email','managerName','voucherFooter','defaultVoucherNotes')");
      snapshot['orgSettings'] = {
        for (final r in orgRows) '${r['key']}': r['value']
      };
    } catch (_) {}

    final now = DateTime.now();
    final root = _root(url, ws);
    await _putJson('$root/joinSnapshot.json', {
      'createdAt': now.toIso8601String(),
      'hostDeviceId': ourId,
      // (دفعة 57) علامة الضغط: كل عمليات السحابة الأقدم من هذه اللحظة
      // أصبحت مادةً مجسّدة داخل هذه اللقطة — روتين الضغط الدوري يحذفها
      // بأمان (المنضمون الجدد يرتوون من اللقطة لا من إعادة تشغيل السجل).
      'compacted_through_ts': now.millisecondsSinceEpoch,
      'data': snapshot,
    });
    // نسجّل العلامة محلياً أيضاً ليعتمدها روتين الضغط.
    try {
      final db2 = await repo.database;
      await db2.insert(
          'sync_meta',
          {
            'key': 'snapshotThroughTs:$ws',
            'value': '${now.millisecondsSinceEpoch}',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}

    // (الاسترداد السيادي) تسجيل منشئ المساحة مرة واحدة وإلى الأبد:
    // creator_device_id يُكتب فقط إن لم يوجد — لا يتغير مع نقل الملكية
    // أبداً، وهو صمام الأمان الأخير لاسترداد المجموعة. المجموعات القائمة
    // قبل هذه الميزة تُسجَّل بأثر رجعي: المالك الحالي وقت أول دعوة جديدة.
    try {
      await registerCreatorIfAbsent(repo,
          backendUrl: url, workspaceId: ws, deviceId: ourId);
    } catch (_) {}

    final token = _newToken();
    final pin = newPairPin();
    // TTL دقيق: 15 دقيقة لمسار الموافقة التفاعلي (كانت 24 ساعة — نافذة
    // أوسع من اللازم أمنياً بعد اعتماد موافقة المدير الصريحة).
    final expires = now.add(const Duration(minutes: 15));
    await _putJson('$root/invites/$token.json', {
      'createdAt': now.toIso8601String(),
      'expiresAt': expires.toIso8601String(),
      'ws': ws,
      'pin': pin,
    }, timeout: const Duration(seconds: 20));

    // رفع سجل الأجهزة أيضاً حتى تكون الحالة السحابية كاملة قبل انضمام العضو.
    try {
      final devices = await db.query('devices');
      for (final d in devices) {
        await _putJson('$root/roster/${Uri.encodeComponent('${d['id']}')}.json',
            _safeDeviceRow(d),
            timeout: const Duration(seconds: 20));
      }
    } catch (_) {}

    return CloudInviteInfo(
      backendUrl: url,
      workspaceId: ws,
      token: token,
      cloudCode: (st['cloudCode'] ?? '').trim(),
      expiresAt: expires,
      pin: pin,
    );
  }

  // ==================== الانضمام (الجهاز الجديد) ====================

  /// ينضم إلى المجموعة عبر السحابة:
  /// يتحقق من الدعوة ← يجلب اللقطة ← يحذف كل البيانات المحلية ويستبدلها
  /// بنسخة المجموعة (معاملة واحدة) ← يضبط إعدادات السحابة بنفس رابط المدير
  /// ← يسجل جهازه في سجل الأجهزة السحابي.
  static Future<void> join(
    Repo repo, {
    required String backendUrl,
    required String token,
    String workspaceId = 'default',
    String cloudCode = '',
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final tok = token.trim().toUpperCase();
    if (tok.isEmpty) {
      throw const CloudJoinException('أدخل رمز الدعوة.');
    }
    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      throw const CloudJoinException(
          'هذا الجهاز عضو في مجموعة قائمة بالفعل — لا يمكن الانضمام لمجموعة أخرى.');
    }

    final root = _root(url, workspaceId);
    final invite = await _getJson('$root/invites/$tok.json');
    if (invite == null) {
      throw const CloudJoinException(
          'رمز الدعوة غير صحيح أو انتهت صلاحيته أو استُخدم من قبل.');
    }
    final exp = DateTime.tryParse('${invite['expiresAt'] ?? ''}');
    if (exp == null || DateTime.now().isAfter(exp)) {
      await _delete('$root/invites/$tok.json');
      throw const CloudJoinException(
          'انتهت صلاحية رمز الدعوة — اطلب من المدير إنشاء دعوة جديدة.');
    }
    // إبطال فوري وحتمي (استخدام لمرة واحدة): تُحذف الدعوة الآن — قبل تطبيق
    // اللقطة — حتى لا يستطيع أي جهاز آخر (أو إعادة تشغيل لنفس الرابط)
    // استعمال الرمز نفسه أثناء أو بعد الانضمام. الحذف شرط للمتابعة:
    // إن تعذّر إبطال الدعوة يُلغى الانضمام كله (لا نترك رمزاً حياً قابلاً
    // لإعادة الاستخدام). فشل الانضمام يتطلب دعوة جديدة من المدير —
    // أرخص أمنياً من دعوة مفتوحة.
    await _deleteStrict('$root/invites/$tok.json');

    final snapRec = await _getJson('$root/joinSnapshot.json');
    final snapData = snapRec?['data'];
    if (snapData is! Map) {
      throw const CloudJoinException(
          'لا توجد نسخة بيانات للمجموعة في السحابة — اطلب من المدير إنشاء دعوة جديدة.');
    }
    final snap = Map<String, Object?>.from(snapData);

    final db = await repo.database;
    final ourId = await ensureDeviceId(repo);
    // نلتقط سجل جهازنا قبل الاستبدال: إعادة إدراج workspaces بنمط REPLACE
    // قد تحذف سجلنا عبر قيد ON DELETE CASCADE، فنعيد إنشاءه بعد اللقطة.
    final ourRowBefore = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    // حذف كامل البيانات المحلية واستبدالها بنسخة المجموعة (معاملة واحدة):
    // نفس منطق الانضمام المحلي بالضبط — الجهاز يبدأ نظيفاً ببيانات المجموعة.
    await SnapshotApply.applySnapshot(() async => db, ourId, snap);

    // ضمان وجود سجل جهازنا كعضو بعد الاستبدال (يظهر لدى المدير عبر roster).
    final ourRowAfter = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    if (ourRowAfter.isEmpty) {
      final wsRows2 = await db.query('workspaces', limit: 1);
      final ws2 =
          wsRows2.isNotEmpty ? (wsRows2.first['id'] as String) : workspaceId;
      final nowIso = DateTime.now().toIso8601String();
      final before = ourRowBefore.isNotEmpty
          ? Map<String, Object?>.from(ourRowBefore.first)
          : <String, Object?>{};
      await db.insert(
          'devices',
          {
            'id': ourId,
            'workspace_id': ws2,
            'name': before['name'] ?? kDefaultMemberName,
            'platform': before['platform'] ?? '',
            'auth_secret': before['auth_secret'] ?? '',
            'is_paired': 1,
            'is_owner': 0,
            'revoked_at': '',
            'expelled_at': '',
            'last_seen_at': nowIso,
            'created_at': '${before['created_at'] ?? nowIso}',
            'updated_at': nowIso,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    // إعدادات السحابة بنفس رابط المدير حتى تعمل المزامنة الفورية مباشرة.
    await repo.setSetting('cloudBackendUrl', url);
    await repo.setSetting('cloudAutoSync', '1');
    // (الاسترداد السيادي) كاش سجل المنشئ الدائم محلياً: تتحقق منه
    // apply_remote عند وصول عملية creator_recovery.
    try {
      final creator = await fetchCreatorDeviceId(
          backendUrl: url, workspaceId: workspaceId);
      if (creator.isNotEmpty) {
        await repo.setSetting('creatorDeviceId', creator);
      }
    } catch (_) {}
    if (cloudCode.trim().isNotEmpty) {
      await repo.setSetting('cloudCode', cloudCode.trim().toUpperCase());
    }
    // صفّر كل مؤشرات المزامنة (سحابة/roster/LAN) حتى يُعاد تشغيل كامل
    // تاريخ العمليات فوق اللقطة (idempotent) — الترطيب النظيف يبدأ من
    // إصدار اللقطة بالضبط قبل الاستماع للعمليات الجديدة.
    await db.delete('sync_meta',
        where: "key LIKE 'lastCloudTs:%' OR key LIKE 'lastRosterPush:%' "
            "OR key LIKE 'lastLanTs:%'");

    // مضاد الأشباح: deviceId حتمي من بصمة العتاد — إعادة التثبيت تعيد
    // إنتاج نفس المعرف. إن وُجد سجلنا القديم في roster السحابي (بدوره
    // وصلاحياته) نحييه: نستعيد user_id والاسم ونمسح أي طرد قديم بدل
    // إنشاء جهاز مكرر جديد.
    try {
      final oldRec = await _getJson(
          '$root/roster/${Uri.encodeComponent(ourId)}.json');
      if (oldRec != null && oldRec.isNotEmpty) {
        final nowIso = DateTime.now().toIso8601String();
        await db.update(
          'devices',
          {
            'user_id': oldRec['user_id'],
            'name': (oldRec['name'] as String?)?.trim().isNotEmpty == true
                ? oldRec['name']
                : null,
            'revoked_at': '',
            'expelled_at': '',
            'is_paired': 1,
            'last_seen_at': nowIso,
            'updated_at': nowIso,
          }..removeWhere((k, v) => v == null),
          where: 'id = ?',
          whereArgs: [ourId],
        );
      }
    } catch (_) {}

    // سجّل جهازنا في السجل السحابي حتى يراه المدير ويعيّن له الصلاحيات.
    final own = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    if (own.isNotEmpty) {
      try {
        await _putJson(
            '$root/roster/${Uri.encodeComponent(ourId)}.json',
            _safeDeviceRow(own.first),
            timeout: const Duration(seconds: 20));
      } catch (_) {}
    }

    // الدعوة تُستخدم مرة واحدة (حُذفت مبكراً؛ هذا حذف احتياطي idempotent).
    try {
      await _delete('$root/invites/$tok.json');
    } catch (_) {}
  }

  // ==================== سجل الأجهزة السحابي (roster) ====================

  /// دمج + رفع سجل الأجهزة. تُستدعى مع كل سحب سحابي:
  ///  - الدمج: أي سجل سحابي أحدث من المحلي (updated_at) يُطبَّق محلياً
  ///    (بلا مساس بأسرار المصادقة المحلية ولا بملكية جهازنا).
  ///  - الرفع: المدير يرفع سجلات كل الأجهزة التي تغيّرت، والعضو يرفع سجله فقط.
  static Future<bool> syncRoster(
    Repo repo,
    Database db, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final root = _root(backendUrl, workspaceId);
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return false;
    final isOwner = await repo.isWorkspaceOwner();
    var changed = false;

    // 1) الدمج من السحابة.
    Map<String, dynamic>? remote;
    try {
      remote = await _getJson('$root/roster.json');
    } catch (_) {
      remote = null;
    }
    if (remote != null && remote.isNotEmpty) {
      final localRows = await db.query('devices');
      final localById = {
        for (final r in localRows) '${r['id']}': Map<String, Object?>.from(r)
      };
      final wsRows = await db.query('workspaces', limit: 1);
      final localWs =
          wsRows.isNotEmpty ? (wsRows.first['id'] as String) : workspaceId;
      var sawNewPeer = false;
      for (final entry in remote.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final r = Map<String, Object?>.from(v);
        final id = '${r['id'] ?? entry.key}';
        if (id.isEmpty) continue;
        final remoteUpd = '${r['updated_at'] ?? ''}';
        final local = localById[id];
        if (id == ourId) {
          // سجلنا: المدير هو المرجع في التعيين/التسمية/الحظر/الطرد فقط.
          if (local == null) continue;
          final localUpd = '${local['updated_at'] ?? ''}';
          if (remoteUpd.compareTo(localUpd) <= 0) continue;
          await db.update(
            'devices',
            {
              'user_id': r['user_id'],
              'name': r['name'] ?? local['name'],
              'revoked_at': r['revoked_at'] ?? '',
              'expelled_at': r['expelled_at'] ?? '',
              'is_paired': r['is_paired'] ?? local['is_paired'],
              'updated_at': remoteUpd,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          changed = true;
          // إبطال فوري من جهة العميل: المدير طردنا عبر السحابة →
          // مسح بيانات المجموعة والعودة مستقلين + شاشة الإعداد الأول.
          final expelledNow = '${r['expelled_at'] ?? ''}'.isNotEmpty ||
              '${r['revoked_at'] ?? ''}'.isNotEmpty;
          if (expelledNow && !isOwner) {
            try {
              // (دفعة 53) الخطاف المركزي أولاً: المحرك يوقف SSE/الدفع،
              // ينظف الجلسة، يعيد الضبط، ويبث onDeviceEvicted للواجهة.
              final hook = onSelfEvicted;
              if (hook != null) {
                await hook();
              } else {
                await repo.resetToStandaloneAfterExpulsion();
              }
            } catch (_) {}
            return true;
          }
          continue;
        }
        if (local == null) {
          final row = _safeDeviceRow(r);
          // (دفعة 56) user_role حقل عرضي للشارات فقط — ليس عموداً في
          // جدول devices، وإبقاؤه يفشل الإدراج بصمت ويعطل مزامنة السجل.
          row.remove('user_role');
          row['id'] = id;
          row['workspace_id'] = localWs;
          row['created_at'] =
              '${r['created_at'] ?? DateTime.now().toIso8601String()}';
          row['updated_at'] = remoteUpd.isEmpty
              ? DateTime.now().toIso8601String()
              : remoteUpd;
          try {
            await db.insert('devices', row,
                conflictAlgorithm: ConflictAlgorithm.ignore);
            changed = true;
            sawNewPeer = true;
          } catch (_) {}
        } else {
          final localUpd = '${local['updated_at'] ?? ''}';
          if (remoteUpd.compareTo(localUpd) <= 0) continue;
          final row = _safeDeviceRow(r);
          row.remove('id');
          row.remove('created_at');
          // (دفعة 56) حقل عرضي — ليس عموداً في devices (انظر أعلاه).
          row.remove('user_role');
          // لا نلمس سرّ المصادقة المحلي (قد يكون تعلّمه عبر اقتران LAN).
          row.remove('auth_secret');
          row['workspace_id'] = localWs;
          try {
            await db.update('devices', row, where: 'id = ?', whereArgs: [id]);
            changed = true;
            // طرد كامل: انتقال القرين إلى مطرود يطهّر محادثته الفردية
            // من قوائم الدردشة لدى كل الأجهزة التي تصلها المصالحة.
            final wasExpelled =
                '${local['expelled_at'] ?? ''}'.isNotEmpty ||
                    '${local['revoked_at'] ?? ''}'.isNotEmpty;
            final nowExpelled = '${row['expelled_at'] ?? ''}'.isNotEmpty ||
                '${row['revoked_at'] ?? ''}'.isNotEmpty;
            if (nowExpelled && !wasExpelled) {
              try {
                await repo.purgePeerChat(id);
              } catch (_) {}
            }
          } catch (_) {}
        }
      }
      // مدير مستقل انضم إليه أول عضو عن بُعد → المساحة أصبحت مُدارة.
      if (isOwner && sawNewPeer) {
        final mode = await repo.workspaceMode();
        if (mode == 'standalone') {
          await db.insert(
              'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }

    // 2) الرفع إلى السحابة (التغييرات فقط منذ آخر رفع).
    try {
      final metaKey = 'lastRosterPush:$workspaceId';
      final metaRows = await db.query('sync_meta',
          where: 'key = ?', whereArgs: [metaKey], limit: 1);
      final lastPush =
          metaRows.isEmpty ? '' : '${metaRows.first['value'] ?? ''}';
      // (دفعة 56) ضمّ دور المستخدم المرتبط لكل جهاز — حتى تعرض بقية
      // الأجهزة شارة الدور الصحيحة فور تغييرها من المدير.
      final rows = isOwner
          ? await db.rawQuery('SELECT d.*, u.role AS user_role '
              'FROM devices d LEFT JOIN users u ON u.id = d.user_id')
          : await db.rawQuery(
              'SELECT d.*, u.role AS user_role FROM devices d '
              'LEFT JOIN users u ON u.id = d.user_id WHERE d.id = ?',
              [ourId]);
      var maxUpd = lastPush;
      for (final d in rows) {
        final upd = '${d['updated_at'] ?? ''}';
        if (upd.compareTo(lastPush) <= 0) continue;
        await _putJson(
            '$root/roster/${Uri.encodeComponent('${d['id']}')}.json',
            _safeDeviceRow(Map<String, Object?>.from(d)),
            timeout: const Duration(seconds: 20));
        if (upd.compareTo(maxUpd) > 0) maxUpd = upd;
      }
      if (maxUpd.compareTo(lastPush) > 0) {
        await db.insert('sync_meta', {'key': metaKey, 'value': maxUpd},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {}

    return changed;
  }

  // ══════════ خط أنابيب الانضمام بموافقة المدير (دفعة 51) ══════════
  //
  // التدفق: الجهاز الجديد يتحقق من الدعوة (QR أو PIN من 6 أرقام) ثم يدفع
  // طلباً إلى /workspaces/$ws/joinRequests/$deviceId ويدخل حالة
  // «بانتظار موافقة المدير» — حارس صارم: لا سحب لللقطة ولا أي بيانات
  // قبل الموافقة. المدير يرى الطلب، يعيّن دوراً، ويوافق/يرفض. عند
  // الموافقة فقط يُنفَّذ الترطيب النظيف (join الكامل).

  static String requestPath(String base, String ws, String deviceId) =>
      '${_root(base, ws)}/joinRequests/${Uri.encodeComponent(deviceId)}.json';

  /// (الجهاز الجديد — خطوة 3) التحقق من الدعوة/PIN ودفع طلب الانضمام.
  /// لا يمس أي بيانات محلية ولا يسحب اللقطة — يسجّل الطلب فقط.
  /// يتحقق من التوكن الكامل أو رمز PIN المرافق للدعوة (invite.pin).
  /// (المعمارية الصامتة) اكتشاف مساحة العمل من رمز الدعوة وحده:
  /// المستخدم يُدخل PIN من 6 أرقام (أو توكن الدعوة) فقط — لا يعرف معرف
  /// WS-XXXXXXXX الخاص بمدير المجموعة. نمسح مفاتيح /workspaces (shallow)
  /// ونبحث عن دعوة حية مطابقة؛ نعيد معرف المساحة أو null.
  static Future<String?> findWorkspaceByInvite({
    required String backendUrl,
    required String tokenOrPin,
  }) async {
    final url = backendUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final input = tokenOrPin.trim().toUpperCase();
    if (input.isEmpty) return null;
    final isPin = RegExp(r'^\d{6}$').hasMatch(input);
    final keys = await _getJson('$url/workspaces.json?shallow=true');
    if (keys == null) return null;
    // الأحدث إنشاءً لا يمكن تمييزه من shallow — نمسح بالترتيب مع سقف
    // حماية (500 مساحة) يبقي الفحص سريعاً على القاعدة المشتركة.
    var scanned = 0;
    for (final ws in keys.keys) {
      if (++scanned > 500) break;
      try {
        if (isPin) {
          final all = await _getJson(
              '${_root(url, ws)}/invites.json');
          if (all == null) continue;
          for (final e in all.entries) {
            final v = e.value;
            if (v is Map && '${v['pin'] ?? ''}' == input) {
              final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
              if (exp != null && DateTime.now().isBefore(exp)) return ws;
            }
          }
        } else {
          final inv = await _getJson(
              '${_root(url, ws)}/invites/${Uri.encodeComponent(input)}.json');
          if (inv != null) {
            final exp = DateTime.tryParse('${inv['expiresAt'] ?? ''}');
            if (exp != null && DateTime.now().isBefore(exp)) return ws;
          }
        }
      } catch (_) {
        // مساحة معطوبة/محظورة قراءةً — تُتجاوز.
      }
    }
    return null;
  }

  static Future<void> requestJoin(
    Repo repo, {
    required String backendUrl,
    required String tokenOrPin,
    required String deviceName,
    String workspaceId = 'default',
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final input = tokenOrPin.trim().toUpperCase();
    if (input.isEmpty) throw const CloudJoinException('أدخل رمز الاقتران.');
    if (deviceName.trim().isEmpty) {
      throw const CloudJoinException('أدخل اسم الجهاز أولاً.');
    }
    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      throw const CloudJoinException(
          'هذا الجهاز عضو في مجموعة قائمة بالفعل.');
    }
    final root = _root(url, workspaceId);
    // مطابقة الدعوة: توكن كامل، أو PIN من 6 أرقام (نمسح كل الدعوات الحية).
    String? matchedToken;
    Map<String, dynamic>? invite;
    if (RegExp(r'^\d{6}$').hasMatch(input)) {
      final all = await _getJson('$root/invites.json');
      if (all != null) {
        for (final e in all.entries) {
          final v = e.value;
          if (v is Map && '${v['pin'] ?? ''}' == input) {
            matchedToken = e.key;
            invite = Map<String, dynamic>.from(v);
            break;
          }
        }
      }
    } else {
      invite = await _getJson('$root/invites/$input.json');
      if (invite != null) matchedToken = input;
    }
    if (invite == null || matchedToken == null) {
      throw const CloudJoinException(
          'رمز الاقتران غير صحيح أو انتهت صلاحيته.');
    }
    final exp = DateTime.tryParse('${invite['expiresAt'] ?? ''}');
    if (exp == null || DateTime.now().isAfter(exp)) {
      await _delete('$root/invites/$matchedToken.json');
      throw const CloudJoinException(
          'انتهت صلاحية رمز الاقتران — اطلب من المدير رمزاً جديداً.');
    }
    // حفظ اسم الجهاز محلياً + دفع الطلب.
    await setDeviceName(repo, deviceName.trim());
    final ourId = await ensureDeviceId(repo);
    final fp = await hardwareFingerprintRaw();
    await _putJson(requestPath(url, workspaceId, ourId), {
      'deviceId': ourId,
      'deviceName': deviceName.trim(),
      'fingerprint': fp == null ? '' : fp.hashCode.toRadixString(16),
      'platform': Platform.operatingSystem,
      'token': matchedToken,
      'status': 'pending',
      'requestedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 20));
    // حفظ سياق الانتظار محلياً لاستئناف الاستطلاع بعد إعادة التشغيل.
    await repo.setSetting('pendingJoin.url', url);
    await repo.setSetting('pendingJoin.ws', workspaceId);
    await repo.setSetting('pendingJoin.token', matchedToken);
  }

  /// (الجهاز الجديد — استطلاع الحالة) يعيد: pending | approved | rejected |
  /// missing. عند approved تُعاد أيضاً بيانات الدور المعيّن.
  static Future<Map<String, String>> pollJoinStatus(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final rec =
        await _getJson(requestPath(backendUrl, workspaceId, deviceId));
    if (rec == null) return {'status': 'missing'};
    return {
      'status': '${rec['status'] ?? 'pending'}',
      'role': '${rec['role'] ?? ''}',
      'token': '${rec['token'] ?? ''}',
    };
  }

  /// (الجهاز الجديد — خطوة 4ب) بعد الموافقة: الترطيب النظيف الكامل —
  /// مسح ذري + لقطة + مؤشرات. ثم حذف الطلب من السحابة (نظافة).
  static Future<void> completeApprovedJoin(
    Repo repo, {
    required String backendUrl,
    required String token,
    String workspaceId = 'default',
    String cloudCode = '',
  }) async {
    await join(repo,
        backendUrl: backendUrl,
        token: token,
        workspaceId: workspaceId,
        cloudCode: cloudCode);
    final ourId = await ensureDeviceId(repo);
    try {
      await _delete(requestPath(backendUrl, workspaceId, ourId));
    } catch (_) {}
    // تنظيف سياق الانتظار.
    final db = await repo.database;
    await db.delete('settings',
        where: "key LIKE 'pendingJoin.%'");
  }

  /// (دفعة 58 — متطلب 11) «طلب مغادرة»: العضو يكتب طلباً في نفس عقدة
  /// /joinRequests بوسم kind=leave — يصل للمدير لحظياً عبر نفس قناة SSE
  /// ليقرّه (طرد نظيف + بث شاهدة) أو يرفضه.
  /// (إصلاح تسليم الإدارة) رفع فوري لعلم الملكية الجديد إلى roster:
  /// عقدة المالك الجديد تُرفع بـ is_owner=1 ودور admin، وعقدة المدير
  /// السابق بـ is_owner=0 — حتى تلتقط المصالحة الدورية على كل الأجهزة
  /// الملكية الجديدة حتى لو سبقت وصولَ العمليات.
  static Future<void> pushOwnershipToRoster(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String newOwnerDeviceId,
    required String previousOwnerDeviceId,
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final root = _root(url, workspaceId);
    final db = await repo.database;
    for (final id in [newOwnerDeviceId, previousOwnerDeviceId]) {
      final rows = await db.rawQuery(
          'SELECT d.*, u.role AS user_role FROM devices d '
          'LEFT JOIN users u ON u.id = d.user_id WHERE d.id = ?',
          [id]);
      if (rows.isEmpty) continue;
      await _putJson(
          '$root/roster/${Uri.encodeComponent(id)}.json',
          _safeDeviceRow(Map<String, Object?>.from(rows.first)),
          timeout: const Duration(seconds: 20));
    }
  }

  static Future<void> requestLeave(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final ourId = await ensureDeviceId(repo);
    final db = await repo.database;
    final own = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    final name = own.isNotEmpty ? '${own.first['name'] ?? ''}'.trim() : '';
    await _putJson(requestPath(url, workspaceId, ourId), {
      'deviceId': ourId,
      'deviceName': name.isEmpty ? 'جهاز عضو' : name,
      'kind': 'leave',
      'platform': Platform.operatingSystem,
      'status': 'pending',
      'requestedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 20));
  }

  /// (المدير) حذف طلب انضمام/مغادرة من السحابة (رفض أو تنظيف).
  static Future<void> deleteJoinRequest({
    required String backendUrl,
    String workspaceId = 'default',
    required String deviceId,
  }) =>
      _delete(requestPath(backendUrl, workspaceId, deviceId));

  /// (المدير) جلب طلبات الانضمام المعلّقة.
  static Future<List<Map<String, Object?>>> fetchJoinRequests(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final all =
        await _getJson('${_root(backendUrl, workspaceId)}/joinRequests.json');
    if (all == null) return const [];
    final out = <Map<String, Object?>>[];
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final m = Map<String, Object?>.from(v);
      if ('${m['status'] ?? 'pending'}' != 'pending') continue;
      m['deviceId'] = '${m['deviceId'] ?? e.key}';
      out.add(m);
    }
    out.sort((a, b) =>
        '${a['requestedAt']}'.compareTo('${b['requestedAt']}'));
    return out;
  }

  /// (المدير — خطوة 4أ) الموافقة: تعيين الدور + تسجيل الجهاز في roster
  /// + تحديث الطلب إلى approved ليستلمه الجهاز المنتظر فوراً.
  static Future<void> approveJoinRequest(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    required String deviceName,
    required String roleCode,
    String workspaceId = 'default',
  }) async {
    final owner = await repo.isWorkspaceOwner();
    if (!owner) {
      throw const CloudJoinException('الموافقة لجهاز المدير فقط.');
    }
    // 🔒 (التجربة) انتهاء الفترة يمنع قبول طلبات ربط أجهزة جديدة.
    await _ensureSubscriptionAllows(repo);
    // 🪑 (باقة المؤسسات) حد المقاعد max_devices: الموافقة على جهاز يتجاوز
    // الحد تُرفض برسالة واضحة للمدير.
    await _ensureSeatAvailable(repo,
        backendUrl: backendUrl,
        workspaceId: workspaceId,
        joiningDeviceId: deviceId);
    final db = await repo.database;
    final now = DateTime.now().toIso8601String();
    // مستخدم منطقي بالدور المعيّن (أو إعادة استخدام مستخدم بنفس الاسم).
    final role = UserRole.values.firstWhere((r) => r.code == roleCode,
        orElse: () => UserRole.viewer);
    final perms = defaultPerms(role);
    final permStr =
        perms.entries.where((e) => e.value).map((e) => e.key).join(',');
    // (دفعة 58 — متطلب 3) لا مستخدمي ظل مكررين: انضمام نفس الجهاز مجدداً
    // يعيد استخدام مستخدم الظل القائم بنفس الاسم بدل إنشاء نسخة ثانية.
    int uid;
    final existing = await db.query('users',
        columns: ['id'],
        where:
            "name = ? AND is_me = 0 AND COALESCE(deleted_at,'') = ''",
        whereArgs: [deviceName],
        limit: 1);
    if (existing.isNotEmpty) {
      uid = existing.first['id'] as int;
      await db.update(
          'users',
          {
            'role': role.code,
            'permissions': permStr,
            'active': 1,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [uid]);
    } else {
      uid = await db.insert('users', {
        'name': deviceName,
        'role': role.code,
        'pin': '',
        'password': '',
        'permissions': permStr,
        'is_me': 0,
        'active': 1,
        'workspace_id': repo.requireWorkspaceId,
        'deleted_at': '',
        'created_at': now,
        'updated_at': now,
      });
    }
    // سجل الجهاز محلياً (مقترن بالمستخدم) — بصمة العتاد تمنع التكرار:
    // نفس deviceId الحتمي يعيد استخدام السجل القديم إن وُجد.
    await db.insert(
        'devices',
        {
          'id': deviceId,
          'workspace_id': repo.requireWorkspaceId,
          'name': deviceName,
          'is_paired': 1,
          'is_owner': 0,
          'user_id': uid,
          'revoked_at': '',
          'expelled_at': '',
          'last_seen_at': now,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    // رفع للسحابة: roster + حالة الطلب approved.
    final root = _root(backendUrl, workspaceId);
    // (دفعة 56) كسر حلقة إعادة الطرد: إن كان الجهاز مطروداً سابقاً فلديه
    // شاهدة في /evictions — يجب حذفها قبل تسجيله في roster وإلا طرد
    // نفسه فور أول مصافحة بعد إعادة الربط.
    try {
      await _delete(evictionPath(backendUrl, workspaceId, deviceId));
    } catch (_) {}
    final own = await db.query('devices',
        where: 'id = ?', whereArgs: [deviceId], limit: 1);
    if (own.isNotEmpty) {
      await _putJson('$root/roster/${Uri.encodeComponent(deviceId)}.json',
          {..._safeDeviceRow(own.first), 'user_role': role.code},
          timeout: const Duration(seconds: 20));
    }
    final req =
        await _getJson(requestPath(backendUrl, workspaceId, deviceId));
    await _putJson(requestPath(backendUrl, workspaceId, deviceId), {
      ...?req,
      'status': 'approved',
      'role': role.code,
      'approvedAt': now,
    }, timeout: const Duration(seconds: 20));
  }

  /// (دفعة 54) مسار شاهدة الطرد الصريحة لجهاز معيّن.
  static String evictionPath(String base, String ws, String deviceId) =>
      '${_root(base, ws)}/evictions/${Uri.encodeComponent(deviceId)}.json';

  /// (المدير — بروتوكول الطرد النشط، دفعة 54) عند «طرد نهائي» أو حظر:
  ///  1) كتابة شاهدة طرد صريحة في /evictions/$deviceId بختم وقت الخادم —
  ///     الجهاز المستهدف يستمع عليها عبر SSE فيبطل جلسته لحظياً.
  ///  2) حذف عقدته نهائياً من /roster/$deviceId — غياب العقدة محفّز طرد
  ///     ثانٍ لدى مصافحة العضوية (دفاع مزدوج).
  ///  3) حذف أي طلب انضمام قديم له (نظافة).
  static Future<void> purgePeerFromCloud(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
    String reason = 'revoked_by_manager',
  }) async {
    final root = _root(backendUrl, workspaceId);
    // 1) الشاهدة الصريحة أولاً — أهم خطوة: تصل المستهدف عبر SSE فوراً،
    //    وختم {".sv":"timestamp"} يمنع تلاعب ساعات الأجهزة.
    await _putJson(evictionPath(backendUrl, workspaceId, deviceId), {
      'deviceId': deviceId,
      'expelled_at': {'.sv': 'timestamp'},
      'reason': reason,
      // (دفعة 57) TTL: بعد 7 أيام تُقلَّم الشاهدة تلقائياً في دورة صيانة
      // المدير — لا ركام أبدياً في /evictions، والمستهدف المطفأ لديه
      // أسبوع كامل ليلتقطها عند أول إقلاع.
      'expires_at': DateTime.now()
          .add(const Duration(days: 7))
          .millisecondsSinceEpoch,
    }, timeout: const Duration(seconds: 20));
    // 2) إزالة العقدة من السجل نهائياً (لا مجرد وسمها).
    try {
      await _delete('$root/roster/${Uri.encodeComponent(deviceId)}.json');
    } catch (_) {}
    // 3) حذف أي طلب انضمام قديم له.
    try {
      await _delete(requestPath(backendUrl, workspaceId, deviceId));
    } catch (_) {}
  }

  /// (المدير — دفعة 55) حل المجموعة نهائياً وإلغاء كل الارتباطات:
  ///  1) كتابة شاهدة طرد لكل جهاز عضو (غير المالك) في /evictions —
  ///     تصلهم لحظياً عبر قنواتهم المخصصة فيبطلون جلساتهم ويعودون مستقلين.
  ///  2) مهلة سماح قصيرة ليلتقط الأعضاء المتصلون الشواهد عبر SSE.
  ///  3) حذف عقدة المجموعة بأكملها من السحابة:
  ///     roster + operations + invites + joinRequests + joinSnapshot —
  ///     تُترك /evictions وحدها مدة سماح ليلتقطها من كان مطفأً عند الحل
  ///     (مصافحته عند الإقلاع تفحصها قبل أي شيء).
  /// يعيد عدد الأجهزة التي بُثّت لها شواهد.
  static Future<int> dissolveGroup(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    if (!await repo.isWorkspaceOwner()) {
      throw const CloudJoinException('حل المجموعة متاح لجهاز المدير فقط.');
    }
    final root = _root(backendUrl, workspaceId);
    final db = await repo.database;
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';

    // 1) اجمع كل معرفات الأجهزة: المحلية + السحابية (roster) — اتحاداً،
    //    حتى لا يفلت جهاز موجود سحابياً فقط.
    final ids = <String>{};
    // لا تُكتب شواهد لأجهزة المالك إطلاقاً (جهاز المدير نفسه).
    for (final r in await db.query('devices',
        columns: ['id'], where: 'COALESCE(is_owner, 0) <> 1')) {
      ids.add('${r['id']}');
    }
    try {
      final remote = await _getJson('$root/roster.json');
      if (remote != null) ids.addAll(remote.keys);
    } catch (_) {}
    ids.remove(ourId);
    ids.removeWhere((e) => e.isEmpty);

    // 2) شاهدة طرد لكل عضو — كل شاهدة مستقلة حتى لا يوقف فشلُ واحدة البقية.
    var broadcast = 0;
    for (final id in ids) {
      try {
        await _putJson(evictionPath(backendUrl, workspaceId, id), {
          'deviceId': id,
          'expelled_at': {'.sv': 'timestamp'},
          'reason': 'group_dissolved',
          'expires_at': DateTime.now()
              .add(const Duration(days: 7))
              .millisecondsSinceEpoch,
        }, timeout: const Duration(seconds: 15));
        broadcast++;
      } catch (_) {}
    }

    // 3) مهلة سماح: الأعضاء المتصلون يلتقطون الشواهد عبر SSE فوراً.
    await Future<void>.delayed(const Duration(seconds: 3));

    // 4) تفكيك عقدة المجموعة السحابية (كل قسم على حدة — أفضل جهد،
    //    ونُبقي /evictions للأعضاء المطفأين).
    for (final node in const [
      'roster',
      'operations',
      'invites',
      'joinRequests',
      'joinSnapshot',
    ]) {
      try {
        await _delete('$root/$node.json');
      } catch (_) {}
    }
    return broadcast;
  }

  /// (المدير — دفعة 57) زوال اللقطة: يحذف الدعوات المنتهية من /invites،
  /// وإن لم تبق أي دعوة حيّة يحذف joinSnapshot.json نهائياً — لقطة
  /// الأعمال الكاملة لا تبقى معلقة بمسار قابل للتخمين بعد انتهاء
  /// نافذة الانضمام (15 دقيقة). يعيد true إن حُذفت اللقطة.
  static Future<bool> purgeStaleInviteArtifacts({
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? invites;
    try {
      invites = await _getJson('$root/invites.json');
    } catch (_) {
      return false; // شبكة — لا نحذف اللقطة على عمى.
    }
    final now = DateTime.now();
    var liveInvite = false;
    if (invites != null) {
      for (final e in invites.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
        if (exp != null && now.isBefore(exp)) {
          liveInvite = true; // دعوة سارية — اللقطة ما تزال مطلوبة.
          continue;
        }
        // دعوة منتهية → تُحذف.
        try {
          await _delete('$root/invites/${Uri.encodeComponent(e.key)}.json');
        } catch (_) {}
      }
    }
    if (liveInvite) return false;
    // لا دعوات حية: هل توجد لقطة أصلاً؟ احذفها.
    try {
      final snap = await _getJson('$root/joinSnapshot.json');
      if (snap == null) return false;
      await _delete('$root/joinSnapshot.json');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// (المدير — دفعة 57) ضغط سجل العمليات السحابي: يحذف كل عملية
  /// server_ts ≤ [throughTsMs] — تُستدعى فقط من SyncEngine بعد التحقق
  /// من أن الحد مغطى بلقطة موثّقة. تحذف على دفعات (استعلام مرشّح
  /// بالفهرس، وتراجع «جلب كامل» عند غياب .indexOn). تعيد عدد المحذوف.
  /// (دفعة 58 — متطلب 4) تطهير سحابي لرسائل الدردشة الأقدم من 24 ساعة:
  /// يحذف من /operations كل عملية entity=message تجاوز server_ts عمرها
  /// المقرر — حمولات المرفقات (base64) تختفي من السحابة نهائياً.
  /// يستدعيها المدير في دورة الصيانة. يعيد عدد العقد المحذوفة.
  static Future<int> purgeOldChatOperations({
    required String backendUrl,
    String workspaceId = 'default',
    Duration ttl = const Duration(hours: 24),
  }) async {
    final root = _root(backendUrl, workspaceId);
    final cutoffMs = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    Map<String, dynamic>? all;
    try {
      final uri = Uri.parse('$root/operations.json').replace(
        queryParameters: {
          'orderBy': jsonEncode('server_ts'),
          'endAt': '$cutoffMs',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 30));
      if (res.statusCode == 400 && res.body.contains('Index not defined')) {
        all = await _getJson('$root/operations.json');
      } else if (res.statusCode >= 200 && res.statusCode < 300) {
        final d = jsonDecode(res.body);
        all = d is Map ? Map<String, dynamic>.from(d) : null;
      }
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    var removed = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      if ('${v['entity_type'] ?? ''}' != 'message') continue;
      final ts = (v['server_ts'] as num?)?.toInt() ?? 0;
      if (ts == 0 || ts > cutoffMs) continue;
      try {
        await _delete('$root/operations/${Uri.encodeComponent(e.key)}.json');
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  static Future<int> compactOperations({
    required String backendUrl,
    String workspaceId = 'default',
    required int throughTsMs,
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? all;
    try {
      // ترشيح خادمي إن توفر الفهرس.
      final uri = Uri.parse('$root/operations.json').replace(
        queryParameters: {
          'orderBy': jsonEncode('server_ts'),
          'endAt': '$throughTsMs',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 30));
      if (res.statusCode == 400 && res.body.contains('Index not defined')) {
        all = await _getJson('$root/operations.json');
      } else if (res.statusCode >= 200 && res.statusCode < 300) {
        final d = jsonDecode(res.body);
        all = d is Map ? Map<String, dynamic>.from(d) : null;
      }
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    var removed = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final ts = (v['server_ts'] as num?)?.toInt() ?? 0;
      if (ts == 0 || ts > throughTsMs) continue;
      try {
        await _delete(
            '$root/operations/${Uri.encodeComponent(e.key)}.json');
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  /// (المدير — دفعة 57) تقليم شواهد الطرد المنتهية (TTL 7 أيام):
  /// يقرأ /evictions كاملة ويحذف كل شاهدة تجاوزت expires_at.
  /// الشواهد القديمة (قبل الدفعة، بلا expires_at) تُمنح مهلة سماح شهراً
  /// من expelled_at ثم تُقلَّم. يعيد عدد الشواهد المحذوفة.
  static Future<int> pruneExpiredEvictions({
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? all;
    try {
      all = await _getJson('$root/evictions.json');
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var pruned = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      var expMs = (v['expires_at'] as num?)?.toInt() ?? 0;
      if (expMs == 0) {
        // شاهدة قديمة بلا TTL: مهلة شهر من وقت الطرد ثم تقليم.
        final at = (v['expelled_at'] as num?)?.toInt() ?? 0;
        if (at == 0) continue; // شكل مجهول — لا نلمسها.
        expMs = at + const Duration(days: 30).inMilliseconds;
      }
      if (nowMs < expMs) continue;
      try {
        await _delete(
            '$root/evictions/${Uri.encodeComponent(e.key)}.json');
        pruned++;
      } catch (_) {}
    }
    return pruned;
  }

  /// (المعمارية الصامتة — نظافة السجل) تطهير roster من الأجهزة الغريبة:
  /// سجل أجهزة المدير المحلي هو مصدر الحقيقة السيادي للعضوية — أي مدخل
  /// سحابي غير موجود محلياً هو جهاز دخيل (تثبيت قديم هبط في مساحة مشتركة
  /// وسجّل نفسه مالكاً، أو بقايا جهاز مطرود) ويُحذف تلقائياً.
  ///
  /// ضمانات الأمان:
  ///  - يعمل على جهاز المالك فقط (يُفرض عند الاستدعاء في محرك المزامنة).
  ///  - لا يلمس جهازنا نحن أبداً.
  ///  - مهلة سماح 15 دقيقة للمداخل حديثة الإنشاء (سباق موافقة انضمام
  ///    لم تصل عمليتها المحلية بعد).
  /// يعيد عدد المداخل المحذوفة.
  static Future<int> pruneForeignRosterEntries(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? roster;
    try {
      roster = await _getJson('$root/roster.json');
    } catch (_) {
      return 0;
    }
    if (roster == null || roster.isEmpty) return 0;
    final db = await repo.database;
    final local = await db.query('devices', columns: ['id']);
    final known = {for (final r in local) '${r['id']}'};
    final ourId = repo.requireDeviceId;
    final now = DateTime.now();
    var pruned = 0;
    for (final e in roster.entries) {
      final id = e.key;
      if (id == ourId) continue; // جهازنا لا يُمس أبداً.
      if (known.contains(id)) continue; // عضو معروف محلياً — سليم.
      final v = e.value;
      if (v is! Map) continue;
      // مهلة سماح: مدخل أُنشئ للتو قد يكون موافقة انضمام في الطريق.
      final created = DateTime.tryParse('${v['created_at'] ?? ''}') ??
          DateTime.tryParse('${v['updated_at'] ?? ''}');
      if (created != null &&
          now.difference(created) < const Duration(minutes: 15)) {
        continue;
      }
      try {
        await _delete('$root/roster/${Uri.encodeComponent(id)}.json');
        pruned++;
        // شاهدة طرد للجهاز الدخيل النشط: لو أقلع لاحقاً يُقصي نفسه فوراً
        // (المطرود سابقاً لديه شاهدته أصلاً — لا نكررها).
        final revoked = '${v['revoked_at'] ?? ''}'.trim().isNotEmpty;
        if (!revoked) {
          final nowMs = now.millisecondsSinceEpoch;
          await _putJson('$root/evictions/${Uri.encodeComponent(id)}.json', {
            'device_id': id,
            'reason': 'foreign_roster_cleanup',
            'expelled_at': nowMs,
            'expires_at':
                nowMs + const Duration(days: 7).inMilliseconds,
          });
        }
      } catch (_) {}
    }
    return pruned;
  }

  /// (المدير — دفعة 56) «حذف نهائي من السجل»: محو كل أثر سحابي لجهاز
  /// مطرود — roster + شاهدة الطرد + طلب الانضمام. يُستدعى بعد أن يكون
  /// الجهاز قد استهلك شاهدته (أو لم يعد يهمنا وصولها): البطاقة تختفي
  /// من كل الأجهزة ولا يبقى ركام في /evictions.
  static Future<void> purgeDeviceRecordFromCloud({
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    final enc = Uri.encodeComponent(deviceId);
    for (final url in [
      '$root/roster/$enc.json',
      '$root/evictions/$enc.json',
      '$root/joinRequests/$enc.json',
    ]) {
      try {
        await _delete(url);
      } catch (_) {}
    }
  }

  /// (المدير — دفعة 54) إزالة شاهدة الطرد عند «إعادة السماح» — وإلا
  /// سيطرد الجهاز المستعاد نفسه فور فحصه القادم.
  static Future<void> clearEvictionTombstone({
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    try {
      await _delete(evictionPath(backendUrl, workspaceId, deviceId));
    } catch (_) {}
  }

  /// (العضو — المصافحة، دفعة 54) هل توجد شاهدة طرد لهذا الجهاز؟
  static Future<bool> hasEvictionTombstone({
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final rec =
        await _getJson(evictionPath(backendUrl, workspaceId, deviceId));
    return rec != null;
  }

  /// (المدير) الرفض: تحديث الحالة rejected — الجهاز المنتظر يتلقاها
  /// ويعرضها للمستخدم دون أي مساس ببياناته.
  static Future<void> rejectJoinRequest(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final req =
        await _getJson(requestPath(backendUrl, workspaceId, deviceId));
    await _putJson(requestPath(backendUrl, workspaceId, deviceId), {
      ...?req,
      'status': 'rejected',
      'rejectedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 20));
  }
}
