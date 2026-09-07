// التحديث بنقرة واحدة (أندرويد):
// ينزّل ملف الـ APK في الخلفية داخل cache/updates ثم يفتح شاشة تثبيت النظام
// مباشرةً — يبقى القرار النهائي للمستخدم في حوار النظام (لا يسمح أندرويد
// بتثبيت صامت لتطبيقات خارج المتجر، وهذا قيد أمني في النظام نفسه).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// مراحل عملية التحديث بنقرة واحدة.
enum InstallPhase {
  idle,
  downloading,
  launchingInstaller,
  awaitingPermission,
  failed,
  done,
}

/// حالة لحظية تُبث أثناء التنزيل/التثبيت لعرض شريط التقدم.
class InstallProgress {
  final InstallPhase phase;

  /// نسبة التنزيل 0..1 (أو null إذا كان الحجم مجهولاً).
  final double? progress;
  final String? error;

  const InstallProgress(this.phase, {this.progress, this.error});
}

class UpdateInstaller {
  static const _channel = MethodChannel('nexora/updates');

  final http.Client Function() _clientFactory;

  UpdateInstaller({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? (() => http.Client());

  /// هل منح المستخدم إذن «تثبيت التطبيقات غير المعروفة» لهذا التطبيق؟
  Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// يفتح صفحة إعدادات النظام لمنح إذن التثبيت (مرة واحدة فقط).
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// ينزّل APK من [url] ويبث التقدم، ثم يفتح شاشة تثبيت النظام.
  /// لا يرمي استثناءً — يبث InstallPhase.failed مع سبب عربي مفهوم.
  Stream<InstallProgress> downloadAndInstall(String url) async* {
    if (!Platform.isAndroid) {
      yield const InstallProgress(InstallPhase.failed,
          error: 'التحديث المباشر متاح على أندرويد فقط.');
      return;
    }

    // 0) إذن «المصادر غير المعروفة»: إن لم يُمنح نفتح إعداداته وننتظر المستخدم.
    if (!await canInstall()) {
      yield const InstallProgress(InstallPhase.awaitingPermission);
      await openInstallSettings();
      // ننتظر عودة المستخدم من الإعدادات (فحص دوري بمهلة قصوى دقيقة واحدة).
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await canInstall()) break;
      }
      if (!await canInstall()) {
        yield const InstallProgress(InstallPhase.failed,
            error: 'لم يُمنح إذن تثبيت التحديثات. فعّله من إعدادات النظام '
                'ثم أعد المحاولة.');
        return;
      }
    }

    // 1) التنزيل إلى cache/updates (مسار معلن في file_paths.xml).
    yield const InstallProgress(InstallPhase.downloading, progress: 0);
    final File apk;
    try {
      final cache = await getTemporaryDirectory();
      final dir = Directory('${cache.path}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true); // تنظيف القديم.
      dir.createSync(recursive: true);
      apk = File('${dir.path}/nexora-update.apk');
    } catch (e) {
      yield InstallProgress(InstallPhase.failed,
          error: 'تعذّر تجهيز مجلد التنزيل: $e');
      return;
    }

    final client = _clientFactory();
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        yield InstallProgress(InstallPhase.failed,
            error: 'الخادم أعاد الرمز ${res.statusCode}.');
        return;
      }
      final total = res.contentLength;
      var received = 0;
      sink = apk.openWrite();
      var lastYield = DateTime.now();
      await for (final chunk in res.stream
          .timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        received += chunk.length;
        // نبث التقدم كل ~150ms حتى لا نغرق الواجهة بالتحديثات.
        final now = DateTime.now();
        if (now.difference(lastYield).inMilliseconds > 150) {
          lastYield = now;
          yield InstallProgress(
            InstallPhase.downloading,
            progress: (total != null && total > 0) ? received / total : null,
          );
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (apk.lengthSync() < 1024 * 1024) {
        // أقل من 1MB — قطعاً ليس APK التطبيق (حجمه ~24MB).
        yield const InstallProgress(InstallPhase.failed,
            error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.');
        return;
      }
    } on TimeoutException {
      yield const InstallProgress(InstallPhase.failed,
          error: 'انقطع الاتصال أثناء التنزيل. أعد المحاولة.');
      return;
    } catch (e) {
      yield InstallProgress(InstallPhase.failed, error: 'فشل التنزيل: $e');
      return;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }

    // 2) إطلاق شاشة تثبيت النظام.
    yield const InstallProgress(InstallPhase.launchingInstaller, progress: 1);
    try {
      final r =
          await _channel.invokeMethod<String>('installApk', {'path': apk.path});
      if (r == 'ok') {
        yield const InstallProgress(InstallPhase.done, progress: 1);
      } else {
        yield InstallProgress(InstallPhase.failed,
            error: switch (r) {
              'file_missing' => 'ملف التحديث اختفى بعد التنزيل.',
              'uri_failed' => 'تعذّر تجهيز ملف التثبيت.',
              _ => 'تعذّر فتح شاشة التثبيت.',
            });
      }
    } catch (e) {
      yield InstallProgress(InstallPhase.failed,
          error: 'تعذّر فتح شاشة التثبيت: $e');
    }
  }
}
