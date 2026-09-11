// (دفعة 52) إعادة ضبط المصنع لنسخة سطح المكتب:
// حذف ملف قاعدة البيانات نفسه من القرص (nexora.db + wal/shm) بعد إغلاق
// الاتصال — الحل الجذري للبيانات القديمة العالقة التي لا يمكن تنظيفها
// يدوياً على ويندوز، ثم إقلاع نظيف من شاشة الترحيب.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'database.dart';
import 'db_init.dart';
import 'media_paths.dart';

class FactoryReset {
  FactoryReset._();

  /// ينفّذ التصفير الكامل. يعيد قائمة بما حُذف (للتشخيص).
  /// الترتيب حاسم:
  ///  1) إغلاق اتصال SQLite (وإلا يقفل ويندوز الملف ويمنع حذفه).
  ///  2) حذف nexora.db و nexora.db-wal و nexora.db-shm.
  ///  3) حذف وسائط الدردشة والمرفقات من مجلد المستندات.
  /// بعدها يجب على المستدعي إعادة تشغيل حالة التطبيق (شاشة الترحيب).
  static Future<List<String>> wipeAllLocalData() async {
    final deleted = <String>[];
    // 1) أغلق القاعدة أولاً — ويندوز يقفل الملفات المفتوحة.
    try {
      await AppDatabase.instance.close();
    } catch (e) {
      debugPrint('FactoryReset: close db: $e');
    }
    // 2) احذف ملفات القاعدة الثلاثة.
    try {
      final dir = await databaseDirectory();
      for (final name in const [
        'nexora.db',
        'nexora.db-wal',
        'nexora.db-shm',
        'nexora.db-journal',
      ]) {
        final f = File(p.join(dir, name));
        if (await f.exists()) {
          await f.delete();
          deleted.add(name);
        }
      }
    } catch (e) {
      debugPrint('FactoryReset: delete db files: $e');
      rethrow; // فشل حذف القاعدة = فشل التصفير — لا نتظاهر بالنجاح.
    }
    // 3) وسائط الدردشة/المرفقات (أفضل جهد — غيابها لا يفشل التصفير).
    try {
      final docs = await MediaPaths.ensureDocsDir();
      if (docs != null) {
        for (final sub in const ['chat_media', 'attachments', 'backups']) {
          final d = Directory(p.join(docs, sub));
          if (await d.exists()) {
            await d.delete(recursive: true);
            deleted.add('$sub/');
          }
        }
      }
    } catch (e) {
      debugPrint('FactoryReset: media wipe: $e');
    }
    return deleted;
  }
}
