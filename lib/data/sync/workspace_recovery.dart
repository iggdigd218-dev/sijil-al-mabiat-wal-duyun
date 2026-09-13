// (استرداد بصمة العتاد) الاسترداد الذاتي عند الإقلاع.
//
// تثبيت جديد نظيف (بعد حذف التطبيق/مسح بياناته) يفحص /device_index
// ببصمة عتاده: وُجد سجل سابق؟ تُستعاد مساحته ودوره وبياناته (من النسخة
// الصامتة /workspaces/{ws}/backup.json) تلقائياً وبصمت — المدير يعود
// مديراً لمؤسسته نفسها، والعضو يعود عضواً في مجموعته.
import 'package:sqflite/sqflite.dart';

import '../../core/cloud_config.dart';
import '../cloud_sync.dart';
import '../repository.dart';
import 'device_registry.dart';

class WorkspaceRecovery {
  WorkspaceRecovery._();

  /// مفتاح علم «جرى فحص الاسترداد» — يمنع تكرار الفحص في كل إقلاع.
  static const _checkedKey = 'recovery.checked';

  /// (اختبارات) إعادة ضبط.
  static void debugReset() {}

  /// الفحص الصامت عند الإقلاع. يعيد true إن جرى استرداد فعلي.
  ///
  /// شروط التشغيل: تثبيت نظيف فقط — مستقل، بلا حسابات، ولم يُفحص سابقاً.
  /// أي فشل شبكة = تجاهل صامت (يُعاد الفحص في الإقلاع التالي لأن العلم
  /// لا يُكتب إلا بعد فحص ناجح فعلاً).
  static Future<bool> attemptSilentRecovery(Repo repo) async {
    try {
      final st = await repo.settings();
      if ((st[_checkedKey] ?? '') == '1') return false;
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return false;
      final mode = await repo.workspaceMode();
      if (mode != 'standalone') {
        await repo.setSetting(_checkedKey, '1');
        return false;
      }
      final accounts =
          await repo.accounts(includeArchived: true, includeDeleted: true);
      if (accounts.isNotEmpty) {
        // بيانات قائمة = ليس تثبيتاً نظيفاً؛ نسجل الربط الحالي فقط.
        await repo.setSetting(_checkedKey, '1');
        await DeviceRegistry.upsertBinding(repo, backendUrl: url);
        return false;
      }
      // 1) بصمة العتاد → الفهرس.
      final fp = await DeviceRegistry.fingerprintKey(repo);
      final rec = await DeviceRegistry.lookup(
          backendUrl: url, fingerprint: fp);
      if (rec == null) {
        // جهاز جديد كلياً: سجّل ربطه بمساحته المولدة (owner).
        await repo.setSetting(_checkedKey, '1');
        await DeviceRegistry.upsertBinding(repo, backendUrl: url);
        return false;
      }
      // 2) سجل سابق: استعادة المساحة والدور.
      final restored = await _restoreWorkspace(repo,
          backendUrl: url, record: rec);
      await repo.setSetting(_checkedKey, '1');
      return restored;
    } catch (_) {
      return false; // شبكة غائبة — يُعاد الفحص في الإقلاع القادم.
    }
  }

  /// (هاتف بديل — استرداد يدوي) المدير يُدخل رمز مساحته القديمة:
  /// تُسحب النسخة الصامتة وتُستعاد، وتُبدَّل المساحة المحلية إليها،
  /// ويُسجَّل الجهاز مالكاً لها في الفهرس (force — قرار صريح منه).
  /// يعيد false إن لم توجد نسخة للمساحة المدخلة.
  static Future<bool> manualRestore(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    if (backendUrl.isEmpty || workspaceId.isEmpty) return false;
    final pulled = await CloudSync.pullWorkspaceBackup(repo,
        backendUrl: backendUrl, workspaceId: workspaceId);
    if (pulled == null) return false;
    final db = await repo.database;
    final current = repo.requireWorkspaceId;
    if (current != workspaceId) {
      await swapWorkspaceId(db, from: current, to: workspaceId);
      await repo.setSetting('sync.workspaceId', workspaceId);
      repo.debugSetWorkspaceId(workspaceId);
    }
    await repo.importAll(pulled);
    await repo.setSetting(_checkedKey, '1');
    try {
      await DeviceRegistry.upsertBinding(repo,
          backendUrl: backendUrl, force: true);
    } catch (_) {}
    return true;
  }

  /// تبديل المساحة المحلية إلى المساحة المستعادة + استرجاع البيانات.
  static Future<bool> _restoreWorkspace(
    Repo repo, {
    required String backendUrl,
    required DeviceRegistryRecord record,
  }) async {
    final db = await repo.database;
    final targetWs = record.workspaceId;
    final current = repo.requireWorkspaceId;
    // 1) ترحيل المعرف المحلي إلى المساحة المسجلة.
    if (current != targetWs) {
      await swapWorkspaceId(db, from: current, to: targetWs);
      await repo.setSetting('sync.workspaceId', targetWs);
      repo.debugSetWorkspaceId(targetWs);
    }
    // 2) الدور: المالك يبقى مالكاً (is_owner=1 افتراضاً في المستقل)؛
    //    العضو يُوسم member — واسترجاع بياناته يتم عبر أول مزامنة
    //    (السجل والعمليات تصله من المجموعة نفسها).
    if (!record.isOwner) {
      await db.insert(
          'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      final devId = repo.requireDeviceId;
      await db.update('devices', {'is_owner': 0},
          where: 'id = ?', whereArgs: [devId]);
      return true;
    }
    // 3) مالك: استرجاع بيانات المؤسسة من النسخة الصامتة إن وُجدت.
    try {
      final pulled = await CloudSync.pullWorkspaceBackup(repo,
          backendUrl: backendUrl, workspaceId: targetWs);
      if (pulled != null) {
        await repo.importAll(pulled);
      }
    } catch (_) {
      // نسخة غائبة/تالفة — المساحة استُعيدت على الأقل، والعمليات
      // السحابية القادمة عبر المزامنة تكمل الباقي.
    }
    return true;
  }

  /// تبديل معرف المساحة عبر كل الجداول (نفس منطق ترحيل default الآمن).
  static Future<void> swapWorkspaceId(Database db,
      {required String from, required String to}) async {
    await db.transaction((txn) async {
      final old = await txn
          .query('workspaces', where: 'id = ?', whereArgs: [from], limit: 1);
      final row = old.isNotEmpty
          ? Map<String, Object?>.from(old.first)
          : <String, Object?>{
              'name': 'متجري',
              'owner_google_id': '',
              'owner_email': '',
              'owner_name': '',
              'created_at': DateTime.now().toIso8601String(),
            };
      row['id'] = to;
      row['updated_at'] = DateTime.now().toIso8601String();
      final exists = await txn
          .query('workspaces', where: 'id = ?', whereArgs: [to], limit: 1);
      if (exists.isEmpty) await txn.insert('workspaces', row);
      final tables = await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT IN ('workspaces') AND name NOT LIKE 'sqlite_%'");
      for (final t in tables) {
        final name = t['name'] as String;
        final cols = await txn.rawQuery('PRAGMA table_info($name)');
        if (!cols.any((c) => c['name'] == 'workspace_id')) continue;
        await txn.update(name, {'workspace_id': to},
            where: 'workspace_id = ?', whereArgs: [from]);
      }
      await txn.delete('workspaces', where: 'id = ?', whereArgs: [from]);
    });
  }
}
