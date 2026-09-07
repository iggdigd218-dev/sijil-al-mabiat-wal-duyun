// اختبارات نظام التحديث المركزي.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/data/update_service.dart';

UpdateService svcReturning(
  String body, {
  int status = 200,
  AppSemVer? current,
  UpdatePlatform platform = UpdatePlatform.android,
  void Function(Uri)? onRequest,
}) =>
    UpdateService(
      manifestUrl: 'https://example.com/version.json',
      current: current ?? const AppSemVer(3, 12, 3, 20),
      platform: platform,
      clientFactory: () => MockClient((req) async {
        onRequest?.call(req.url);
        return http.Response(body, status,
            headers: {'content-type': 'application/json'});
      }),
    );

String manifest({
  String version = '3.13.0+21',
  String? minSupported,
  String notes = 'تحسينات',
}) =>
    jsonEncode({
      'version': version,
      if (minSupported != null) 'minSupported': minSupported,
      'releaseUrl': 'https://github.com/x/y/releases/tag/latest',
      'downloads': {
        'android': 'https://github.com/x/y/releases/download/latest/app.apk',
        'windows': 'https://github.com/x/y/releases/download/latest/app.zip',
      },
      'publishedAt': '2026-09-06T10:00:00Z',
      'notes': notes,
    });

void main() {
  group('مطابقة الإصدار', () {
    test('kAppVersion يطابق pubspec.yaml تمامًا', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9.]+)\+([0-9]+)', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec.yaml يجب أن يحتوي version');
      expect(kAppVersion, m!.group(1),
          reason: 'حدّث kAppVersion في lib/core/app_version.dart');
      expect(kAppBuild, int.parse(m.group(2)!),
          reason: 'حدّث kAppBuild في lib/core/app_version.dart');
    });

    test('لا توجد أرقام إصدار مكتوبة يدويًا في الواجهة', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('app_version.dart')) continue;
        final src = f.readAsStringSync();
        if (RegExp(r"'الإصدار \d+\.\d+").hasMatch(src)) bad.add(f.path);
      }
      expect(bad, isEmpty,
          reason: 'استخدم appVersionLabel بدل كتابة الإصدار يدويًا');
    });
  });

  group('مقارنة الإصدارات', () {
    test('التحليل يقبل الصيغ المختلفة', () {
      expect(AppSemVer.tryParse('3.12.3')?.toString(), '3.12.3');
      expect(AppSemVer.tryParse('v3.12.3+20')?.toString(), '3.12.3+20');
      expect(AppSemVer.tryParse('flutter-v3.7')?.toString(), '3.7.0');
      expect(AppSemVer.tryParse('نص بلا رقم'), isNull);
      expect(AppSemVer.tryParse(null), isNull);
    });

    test('الترتيب صحيح رقميًا لا نصيًا', () {
      // 3.9.0 < 3.12.0 (نصيًا "3.9" > "3.12" وهو الخطأ الشائع)
      expect(
          AppSemVer.tryParse('3.12.0')! > AppSemVer.tryParse('3.9.0')!, isTrue);
      expect(AppSemVer.tryParse('3.12.3')! > AppSemVer.tryParse('3.12.2')!,
          isTrue);
      expect(
          AppSemVer.tryParse('3.12.3+21')! > AppSemVer.tryParse('3.12.3+20')!,
          isTrue);
      expect(
          AppSemVer.tryParse('3.12.3') == AppSemVer.tryParse('3.12.3'), isTrue);
    });
  });

  group('فحص التحديث', () {
    test('إصدار أحدث ⇒ تحديث متاح', () async {
      final info = await svcReturning(manifest(version: '3.13.0+21')).check();
      expect(info.status, UpdateStatus.available);
      expect(info.hasUpdate, isTrue);
      expect(info.isMandatory, isFalse);
      expect(info.latest.toString(), '3.13.0+21');
    });

    test('نفس الإصدار ⇒ محدَّث', () async {
      final info = await svcReturning(manifest(version: '3.12.3+20')).check();
      expect(info.status, UpdateStatus.upToDate);
      expect(info.hasUpdate, isFalse);
    });

    test('إصدار أقدم على الخادم ⇒ محدَّث (لا تراجع)', () async {
      final info = await svcReturning(manifest(version: '3.10.0+15')).check();
      expect(info.status, UpdateStatus.upToDate);
    });

    test('أقل من الحد الأدنى المدعوم ⇒ تحديث إجباري', () async {
      final info = await svcReturning(
              manifest(version: '4.0.0+30', minSupported: '3.13.0'))
          .check();
      expect(info.status, UpdateStatus.required_);
      expect(info.isMandatory, isTrue);
    });

    test('يختار رابط التنزيل حسب المنصّة', () async {
      final a = await svcReturning(manifest(), platform: UpdatePlatform.android)
          .check();
      expect(a.downloadUrl, endsWith('app.apk'));
      final w = await svcReturning(manifest(), platform: UpdatePlatform.windows)
          .check();
      expect(w.downloadUrl, endsWith('app.zip'));
      final o = await svcReturning(manifest(), platform: UpdatePlatform.other)
          .check();
      expect(o.downloadUrl, isNull);
      expect(o.releaseUrl, isNotNull, reason: 'يبقى رابط الصفحة متاحًا');
    });
  });

  group('الفشل الآمن — لا انهيار أبدًا', () {
    test('خطأ خادم 500', () async {
      final info = await svcReturning('{}', status: 500).check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.hasUpdate, isFalse);
      expect(info.error, contains('500'));
    });

    test('JSON تالف', () async {
      final info = await svcReturning('<<< ليس JSON >>>').check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.error, contains('تالف'));
    });

    test('بيان بلا رقم إصدار', () async {
      final info = await svcReturning(jsonEncode({'notes': 'x'})).check();
      expect(info.status, UpdateStatus.unknown);
    });

    test('انقطاع الشبكة', () async {
      final svc = UpdateService(
        manifestUrl: 'https://example.com/version.json',
        clientFactory: () =>
            MockClient((_) async => throw const SocketException('offline')),
      );
      final info = await svc.check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.hasUpdate, isFalse);
    });

    test('يرفض رابط غير https', () async {
      final svc = UpdateService(manifestUrl: 'http://insecure.example/v.json');
      final info = await svc.check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.error, contains('https'));
    });

    test('يرفض رابط تنزيل غير https داخل البيان', () async {
      final body = jsonEncode({
        'version': '9.9.9',
        'downloads': {'android': 'http://evil.example/x.apk'},
      });
      final info = await svcReturning(body).check();
      expect(info.status, UpdateStatus.available);
      expect(info.downloadUrl, isNull, reason: 'لا نقبل روابط غير آمنة');
    });
  });

  test('يطلب البيان من الرابط الصحيح', () async {
    Uri? seen;
    await svcReturning(manifest(), onRequest: (u) => seen = u).check();
    expect(seen.toString(), 'https://example.com/version.json');
  });
}
