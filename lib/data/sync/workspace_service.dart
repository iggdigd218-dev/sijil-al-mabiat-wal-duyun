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
    await repo?.setSetting(_workspaceIdSetting, id);
    return id;
  }
  final now = DateTime.now().toIso8601String();
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
