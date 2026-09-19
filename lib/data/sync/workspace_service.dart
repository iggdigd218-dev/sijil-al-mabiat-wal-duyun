// Workspace bootstrap.
// (المعمارية الصامتة) يُولّد لكل تثبيت جديد معرف مساحة عمل فريداً وعشوائياً
// بصيغة WS-XXXXXXXX — فتعمل كل منشأة في مسار سحابي معزول تماماً
// /workspaces/{WS_ID}/ ولا تتصادم بياناتها مع أي منشأة أخرى على قاعدة
// النظام الرسمية المشتركة (كان الجميع سابقاً على 'default' الواحد).
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../repository.dart';

const defaultWorkspaceId = 'default';
const _workspaceIdSetting = 'sync.workspaceId';

/// (اختبارات فقط) إبقاء المعرف القديم 'default': حزم كثيرة تبني
/// فرضياتها على مسارات workspaces/default — تضبطه على true في main().
bool debugForceLegacyWorkspaceId = false;

/// أبجدية آمنة بلا حروف ملتبسة (0/O، 1/I/L) — قراءة ونسخ بلا أخطاء.
const _wsAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// يولّد معرف مساحة فريداً: WS- تليها 8 خانات عشوائية آمنة (Random.secure).
String generateWorkspaceId() {
  final rnd = Random.secure();
  final b = StringBuffer('WS-');
  for (var i = 0; i < 8; i++) {
    b.write(_wsAlphabet[rnd.nextInt(_wsAlphabet.length)]);
  }
  return b.toString();
}

/// هل المعرف من الجيل القديم المشترك ('default' أو فارغ)؟
bool isLegacyWorkspaceId(String? id) {
  final t = (id ?? '').trim();
  return t.isEmpty || t == defaultWorkspaceId;
}

Future<String> ensureWorkspace(Database db, {Repo? repo}) async {
  // (إصلاح حرج 2026-09-19 — جذر كارثة موت المزامنة الحيّة) الربط الصريح
  // في الإعدادات (sync.workspaceId — يكتبه الانضمام/التزويد ويصل مع لقطة
  // المجموعة) هو مصدر الحقيقة، لا «أول صف» في جدول workspaces: صف المساحة
  // الشخصية القديمة كان يبقى أولاً بعد الانضمام فيلتقطه المحرك ويوجّه كل
  // دفع/سحب العضو إلى مسار ميت — عملياته تهبط في مساحته الشخصية ومزامنة
  // المجموعة تتوقف كلياً بلا أي خطأ ظاهر (الدليل الحي: اختبار LIVE-DEBUG
  // 2026-09-19 وعمليات جهاز العضو في WS-MF38GASA ميدانياً).
  var bound = '';
  try {
    if (repo != null) {
      bound = ((await repo.settings())[_workspaceIdSetting] ?? '').trim();
    } else {
      final r = await db.query('settings',
          columns: ['value'],
          where: 'key = ?',
          whereArgs: [_workspaceIdSetting],
          limit: 1);
      bound = r.isNotEmpty ? '${r.first['value']}'.trim() : '';
    }
  } catch (_) {}
  if (bound.isNotEmpty &&
      !isLegacyWorkspaceId(bound) &&
      !debugForceLegacyWorkspaceId) {
    final exists = await db.query('workspaces',
        where: 'id = ?', whereArgs: [bound], limit: 1);
    if (exists.isEmpty) {
      final now = DateTime.now().toIso8601String();
      await db.insert(
          'workspaces',
          {
            'id': bound,
            'name': 'متجري',
            'owner_google_id': '',
            'owner_email': '',
            'owner_name': '',
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    // (عقد المساحة الواحدة) صف الربط هو الصف الوحيد — أي صف مساحة شخصية
    // قديمة يُحذف فوراً حتى يصلح أول إقلاع بعد التحديث الأجهزة العالقة
    // التي تخطف منها الصفوف القديمة ثمانية مسارات أخرى تقرأ «أول صف»
    // (النسخ الاحتياطي الصامت وغيرها). سجل الجهاز إن حُذف عبر CASCADE
    // يعيد initSyncInfra إنشاءه في نفس الإقلاع.
    try {
      await db.delete('workspaces', where: 'id <> ?', whereArgs: [bound]);
    } catch (_) {}
    await repo?.setSetting(_workspaceIdSetting, bound);
    return bound;
  }
  // تحقق إن كان Workspace موجود في جدول workspaces.
  final rows = await db.query('workspaces', limit: 1);
  if (rows.isNotEmpty) {
    var id = rows.first['id'] as String;
    // (عزل المساحات) معرف قديم مشترك؟ رحّله لمعرف فريد — لكن فقط لجهاز
    // منفرد: العضو يتبع مساحة مديره، ومجموعة قائمة تغيير معرفها يقطع
    // أعضاءها عن المسار السحابي القديم.
    if (!debugForceLegacyWorkspaceId &&
        isLegacyWorkspaceId(id) &&
        await _safeToMigrate(db)) {
      final fresh = generateWorkspaceId();
      await _migrateWorkspaceId(db, from: id, to: fresh);
      id = fresh;
    }
    // (عقد المساحة الواحدة) الصف المختار وحده يبقى — انظر فرع الربط.
    try {
      await db.delete('workspaces', where: 'id <> ?', whereArgs: [id]);
    } catch (_) {}
    await repo?.setSetting(_workspaceIdSetting, id);
    return id;
  }
  final now = DateTime.now().toIso8601String();
  // (استعادة سلوك 3.55) معرّف المساحة عشوائي لكل تثبيت (WS-XXXXXXXX) ولا
  // علاقة له بحساب Google إطلاقاً: الربط يظل يعمل بدقة كاملة بلا إنترنت
  // ودون أي تبادل رموز — هذا بالضبط ما كان يعمل في 3.55.
  final id =
      debugForceLegacyWorkspaceId ? defaultWorkspaceId : generateWorkspaceId();
  await db.insert('workspaces', {
    'id': id,
    'name': 'متجري',
    'owner_google_id': '',
    'owner_email': '',
    'owner_name': '',
    'created_at': now,
    'updated_at': now,
  });
  await repo?.setSetting(_workspaceIdSetting, id);
  // سجّل الجهاز الحالي أيضًا إذا كان deviceId متوفرًا.
  return id;
}

/// آمن للترحيل: ليس عضواً في مجموعة، ولا توجد أجهزة مقترنة أخرى
/// (مجموعة قائمة على المعرف القديم تبقى عليه حفاظاً على اتصال أعضائها).
Future<bool> _safeToMigrate(Database db) async {
  try {
    final m = await db.query('sync_meta',
        where: 'key = ?', whereArgs: ['workspaceMode'], limit: 1);
    final mode = m.isNotEmpty ? '${m.first['value']}' : 'standalone';
    if (mode == 'member') return false;
    final d = await db.rawQuery(
        "SELECT COUNT(*) c FROM devices WHERE COALESCE(revoked_at,'') = ''");
    final active = (d.first['c'] as int?) ?? 0;
    return active <= 1;
  } catch (_) {
    return false;
  }
}

/// ترحيل ذري للمعرف عبر كل الجداول الحاملة workspace_id + جدول workspaces
/// نفسه (إدراج الجديد ← تحويل الأبناء ← حذف القديم؛ يرضي قيود FK).
Future<void> _migrateWorkspaceId(Database db,
    {required String from, required String to}) async {
  await db.transaction((txn) async {
    final old = await txn
        .query('workspaces', where: 'id = ?', whereArgs: [from], limit: 1);
    if (old.isEmpty) return;
    final row = Map<String, Object?>.from(old.first);
    row['id'] = to;
    row['updated_at'] = DateTime.now().toIso8601String();
    await txn.insert('workspaces', row);
    // كل جدول يحمل عمود workspace_id يُحوَّل للمعرف الجديد.
    final tables = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT IN ('workspaces') AND name NOT LIKE 'sqlite_%'");
    for (final t in tables) {
      final name = t['name'] as String;
      final cols = await txn.rawQuery('PRAGMA table_info($name)');
      final has = cols.any((c) => c['name'] == 'workspace_id');
      if (!has) continue;
      await txn.update(name, {'workspace_id': to},
          where: 'workspace_id = ?', whereArgs: [from]);
    }
    await txn.delete('workspaces', where: 'id = ?', whereArgs: [from]);
  });
}

Future<String?> currentWorkspaceId(Repo repo) async {
  final st = await repo.settings();
  return st[_workspaceIdSetting];
}

Future<void> linkWorkspaceToGoogle(
  Database db, {
  required String workspaceId,
  required String googleId,
  required String email,
  required String name,
}) async {
  await db.update(
    'workspaces',
    {
      'owner_google_id': googleId,
      'owner_email': email,
      'owner_name': name,
      'updated_at': DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [workspaceId],
  );
}
