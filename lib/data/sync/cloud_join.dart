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
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../repository.dart';
import 'device_id.dart';
import 'lan_http_transport.dart';

const _tokenChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String _newToken([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _tokenChars[rnd.nextInt(_tokenChars.length)])
      .join();
}

/// بيانات دعوة انضمام سحابية جاهزة للعرض/المشاركة.
class CloudInviteInfo {
  final String backendUrl;
  final String workspaceId;
  final String token;
  final String cloudCode;
  final DateTime expiresAt;
  const CloudInviteInfo({
    required this.backendUrl,
    required this.workspaceId,
    required this.token,
    required this.cloudCode,
    required this.expiresAt,
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
    final expires = now.add(const Duration(hours: 24));
    await _putJson('$root/invites/$token.json', {
      'createdAt': now.toIso8601String(),
      'expiresAt': expires.toIso8601String(),
      'ws': ws,
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
    // إبطال فوري (استخدام لمرة واحدة): نحذف الدعوة الآن — قبل تطبيق
    // اللقطة — حتى لا يستطيع أي جهاز آخر (أو إعادة تشغيل لنفس الرابط)
    // استعمال الرمز نفسه أثناء أو بعد الانضمام. فشل الانضمام لاحقاً يتطلب
    // دعوة جديدة من المدير — أرخص أمنياً من دعوة قابلة لإعادة الاستخدام.
    try {
      await _delete('$root/invites/$tok.json');
    } catch (_) {
      // فشل الحذف لا يوقف الانضمام؛ ستُحذف مجدداً في النهاية احتياطاً.
    }

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
    // صفّر مؤشر السحب حتى يُعاد تشغيل كل تاريخ العمليات فوق اللقطة
    // (idempotent) فلا يفوت العضو الجديد أي عملية.
    await db.delete('sync_meta',
        where: 'key = ?', whereArgs: ['lastCloudTs:$workspaceId']);

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
}
