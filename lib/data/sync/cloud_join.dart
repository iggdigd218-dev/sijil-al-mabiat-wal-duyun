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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/models.dart';
import '../repository.dart';
import 'device_id.dart';
import 'lan_http_transport.dart';

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

  static String _root(String base, String ws) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';

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
    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      final db0 = await repo.database;
      await db0.insert(
          'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final st = await repo.settings();
    final url = (st['cloudBackendUrl'] ?? '').trim();
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
      'data': snapshot,
    });

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
    await LanSyncService.applySnapshot(() async => db, ourId, snap);

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
            'ip_address': before['ip_address'] ?? '',
            'port': before['port'] ?? 0,
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
      final rows = isOwner
          ? await db.query('devices')
          : await db.query('devices',
              where: 'id = ?', whereArgs: [ourId]);
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
    final db = await repo.database;
    final now = DateTime.now().toIso8601String();
    // مستخدم منطقي بالدور المعيّن (أو إعادة استخدام مستخدم بنفس الاسم).
    final role = UserRole.values.firstWhere((r) => r.code == roleCode,
        orElse: () => UserRole.viewer);
    final perms = defaultPerms(role);
    final permStr =
        perms.entries.where((e) => e.value).map((e) => e.key).join(',');
    final uid = await db.insert('users', {
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
    final own = await db.query('devices',
        where: 'id = ?', whereArgs: [deviceId], limit: 1);
    if (own.isNotEmpty) {
      await _putJson('$root/roster/${Uri.encodeComponent(deviceId)}.json',
          _safeDeviceRow(own.first),
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
