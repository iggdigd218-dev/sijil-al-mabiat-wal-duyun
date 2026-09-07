import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// محاكي بسيط لمنصة url_launcher يعترض محاولات الفتح في الاختبارات.
final List<String> mockLaunchLog = <String>[];
bool mockCanLaunchResult = true;

void setupUrlLauncherMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher_android'),
          (call) async {
    switch (call.method) {
      case 'canLaunch':
        return mockCanLaunchResult;
      case 'launch':
        mockLaunchLog.add((call.arguments['url'] ?? '').toString());
        return true;
      default:
        return null;
    }
  });

  // قناة عامة احتياطية لبعض الإصدارات.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
    switch (call.method) {
      case 'canLaunch':
        return mockCanLaunchResult;
      case 'launch':
        mockLaunchLog.add((call.arguments['url'] ?? '').toString());
        return true;
      default:
        return null;
    }
  });
}
