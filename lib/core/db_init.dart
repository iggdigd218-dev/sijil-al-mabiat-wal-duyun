// تهيئة قاعدة البيانات حسب المنصة:
//  - أندرويد/iOS: مصنع sqflite الافتراضي (لا تهيئة).
//  - ويندوز/لينكس/ماك: sqflite_common_ffi (SQLite عبر FFI).
// الملاحظة: الاستيراد آمن على الهاتف لأننا لا نستدعي دوال FFI إلا على سطح المكتب.
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// تُستدعى مرة واحدة عند إقلاع التطبيق.
void initDbForPlatform() {
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}

/// مجلد قاعدة البيانات المناسب للمنصة.
Future<String> databaseDirectory() async {
  if (isDesktop) {
    // ويندوز/لينكس: AppData/Roaming؛ ماك: Library.
    final dir = Platform.isMacOS
        ? await getLibraryDirectory()
        : await getApplicationSupportDirectory();
    return dir.path;
  }
  return getDatabasesPath();
}
