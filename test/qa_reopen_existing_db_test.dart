// انحدار: قاعدة بيانات ويندوز قديمة تحتوي جدول workspaces (وجداول مزامنة)
// لكن دون كل الجداول الأساسية يجب أن تُفتح دون خطأ
// "table workspaces already exists".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';

void main() {
  test('فتح قاعدة فيها workspaces مسبقاً لا يرمي "already exists"', () async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('nexora_dbtest');
    final path = p.join(dir.path, 'nexora.db');

    // قاعدة قديمة فيها جداول المزامنة فقط بنسخة قديمة.
    var db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, v) async {
            await d.execute('''CREATE TABLE workspaces (
              id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
              owner_google_id TEXT DEFAULT '', owner_email TEXT DEFAULT '',
              owner_name TEXT DEFAULT '', created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL)''');
            await d.execute(
                'CREATE TABLE devices (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL)');
          },
        ));
    await db.close();

    // أعد الفتح بنسخة أعلى: onUpgrade يشغّل createSchema (مسار الدفاع).
    final reopened = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: AppDatabase.schemaVersion,
          onCreate: (d, v) => AppDatabase.createSchema(d),
          onUpgrade: (d, f, t) => AppDatabase.createSchema(d),
        ));
    final tables = await reopened
        .rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
    final names = tables.map((e) => e['name'] as String).toSet();
    expect(names,
        containsAll(<String>['workspaces', 'accounts', 'settings', 'devices']));
    await reopened.close();
    await dir.delete(recursive: true);
  });
}
