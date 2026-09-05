// Workspace bootstrap.
// يُولّد Workspace افتراضي "محلي" عند أول تشغيل، ويتيح ربطه لاحقًا بحساب Google.
// في المرحلة الحالية لا ندعم أكثر من Workspace في نفس الوقت، لكن البنية جاهزة لذلك.
import 'package:sqflite/sqflite.dart';

import '../repository.dart';

const defaultWorkspaceId = 'default';
const _workspaceIdSetting = 'sync.workspaceId';

Future<String> ensureWorkspace(Database db, {Repo? repo}) async {
  // تحقق إن كان Workspace موجود في جدول workspaces.
  final rows = await db.query('workspaces', limit: 1);
  if (rows.isNotEmpty) {
    final id = rows.first['id'] as String;
    await repo?.setSetting(_workspaceIdSetting, id);
    return id;
  }
  final now = DateTime.now().toIso8601String();
  await db.insert('workspaces', {
    'id': defaultWorkspaceId,
    'name': 'متجري',
    'owner_google_id': '',
    'owner_email': '',
    'owner_name': '',
    'created_at': now,
    'updated_at': now,
  });
  await repo?.setSetting(_workspaceIdSetting, defaultWorkspaceId);
  // سجّل الجهاز الحالي أيضًا إذا كان deviceId متوفرًا.
  return defaultWorkspaceId;
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
