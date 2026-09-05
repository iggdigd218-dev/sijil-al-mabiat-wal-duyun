// إدارة معرّف الجهاز الثابت.
// deviceId ثابت يُولّد مرة واحدة ويُحفظ إلى الأبد في settings حتى لا يتغير
// بين تشغيلات التطبيق أو مسح الكاش. يستخدم لربط الأجهزة وبناء Operation IDs.
import 'dart:math';

import '../repository.dart';

const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _deviceIdKey = 'sync.deviceId';
const _deviceNameKey = 'sync.deviceName';

/// يولّد سلسلة عشوائية من 8 أحرف من قاعدة Base32 مبسطة.
String generateDeviceCode([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _chars[rnd.nextInt(_chars.length)]).join();
}

String formatDeviceId(String code) => 'DEVICE-$code';

/// يُعيد deviceId الثابت لهذا الجهاز، ويولّده إن لم يكن موجودًا.
Future<String> ensureDeviceId(Repo repo) async {
  final st = await repo.settings();
  final existing = st[_deviceIdKey];
  if (existing != null && existing.startsWith('DEVICE-')) return existing;
  final fresh = formatDeviceId(generateDeviceCode());
  await repo.setSetting(_deviceIdKey, fresh);
  return fresh;
}

Future<String?> getDeviceIdCached(Repo repo) async {
  final st = await repo.settings();
  return st[_deviceIdKey];
}

Future<void> setDeviceName(Repo repo, String name) =>
    repo.setSetting(_deviceNameKey, name);

Future<String> deviceName(Repo repo) async {
  final st = await repo.settings();
  final n = st[_deviceNameKey];
  if (n != null && n.trim().isNotEmpty) return n;
  // اسم افتراضي بناء على المنصة.
  return 'جهاز نكسورا';
}
