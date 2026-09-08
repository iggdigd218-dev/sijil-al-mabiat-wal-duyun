// التحديث بنقرة واحدة (أندرويد):
// ينزّل ملف الـ APK عبر DownloadManager (خدمة نظام) ثم يفتح شاشة تثبيت
// النظام مباشرةً — يبقى القرار النهائي للمستخدم في حوار النظام (لا يسمح
// أندرويد بتثبيت صامت لتطبيقات خارج المتجر، وهذا قيد أمني في النظام نفسه).
//
// لماذا DownloadManager بدل http داخل التطبيق؟
// 1) السرعة: تنزيل داخل عملية التطبيق يخضع لكبح النظام للتطبيقات الخاملة
//    ولقيود Dart isolate، بينما مدير التنزيلات خدمة نظام مخصصة لذلك.
// 2) الاستمرارية: يواصل التنزيل حتى لو أُغلق التطبيق نهائياً.
// 3) الاستئناف: يستأنف تلقائياً بعد انقطاع الشبكة (HTTP Range)، وعند فتح
//    التطبيق مجدداً نلتقط التنزيل الجاري/المكتمل بدل البدء من الصفر.
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

  // ------- تذكّر معرّف التنزيل بين تشغيلات التطبيق (للاستئناف) -------

  Future<File> _idFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/update_download_id.txt');
  }

  Future<int?> _savedDownloadId() async {
    try {
      final f = await _idFile();
      if (!f.existsSync()) return null;
      return int.tryParse((await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDownloadId(int? id) async {
    try {
      final f = await _idFile();
      if (id == null) {
        if (f.existsSync()) await f.delete();
      } else {
        await f.writeAsString('$id');
      }
    } catch (_) {}
  }

  Future<Map<String, Object?>> _query(int id) async {
    try {
      final r = await _channel
          .invokeMapMethod<String, Object?>('queryDownload', {'id': id});
      return r ?? const {'status': 'unknown'};
    } catch (_) {
      return const {'status': 'unknown'};
    }
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

    yield const InstallProgress(InstallPhase.downloading, progress: 0);

    // 1) استئناف تنزيل سابق إن وُجد (بدأ في جلسة سابقة واستمر في الخلفية).
    var id = await _savedDownloadId();
    if (id != null) {
      final st = await _query(id);
      final status = '${st['status']}';
      if (status == 'done' && '${st['path']}'.isNotEmpty) {
        // اكتمل في الخلفية — ثبّت مباشرة بلا إعادة تنزيل.
        yield* _install('${st['path']}');
        return;
      }
      if (status != 'running' && status != 'pending' && status != 'paused') {
        id = null; // فشل/اختفى — نبدأ من جديد.
      }
    }

    // 2) بدء تنزيل جديد عبر مدير تنزيلات النظام.
    if (id == null) {
      try {
        final r = await _channel.invokeMethod<Object?>(
            'startDownload', {'url': url});
        final started = (r is int) ? r : int.tryParse('$r') ?? -1;
        if (started >= 0) {
          id = started;
          await _saveDownloadId(id);
        }
      } catch (_) {}
    }

    if (id == null) {
      // مسار احتياطي (أجهزة عطّل فيها مدير التنزيلات): تنزيل مباشر.
      yield* _fallbackHttpDownload(url);
      return;
    }

    // 3) متابعة التقدم — التنزيل نفسه بيد النظام ويستمر لو خرج المستخدم.
    var stuckCount = 0;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final st = await _query(id);
      final status = '${st['status']}';
      final bytes = (st['bytes'] as num?)?.toInt() ?? 0;
      final total = (st['total'] as num?)?.toInt() ?? -1;
      switch (status) {
        case 'done':
          final path = '${st['path']}';
          if (path.isEmpty) {
            await _saveDownloadId(null);
            yield const InstallProgress(InstallPhase.failed,
                error: 'اكتمل التنزيل لكن الملف غير موجود. أعد المحاولة.');
            return;
          }
          yield* _install(path);
          return;
        case 'failed':
          await _saveDownloadId(null);
          yield InstallProgress(InstallPhase.failed,
              error: 'فشل التنزيل (رمز ${st['reason'] ?? '?'}). '
                  'تحقق من الاتصال ثم أعد المحاولة.');
          return;
        case 'paused':
          // انقطاع مؤقت — النظام سيستأنف وحده؛ نُبقي الشريط ظاهراً.
          yield InstallProgress(InstallPhase.downloading,
              progress: (total > 0) ? bytes / total : null);
          break;
        case 'unknown':
          // اختفى من قائمة التنزيلات (أُلغي من الإشعار مثلاً).
          if (++stuckCount >= 6) {
            await _saveDownloadId(null);
            yield const InstallProgress(InstallPhase.failed,
                error: 'أُلغي التنزيل. أعد المحاولة.');
            return;
          }
          break;
        default: // running / pending
          stuckCount = 0;
          yield InstallProgress(InstallPhase.downloading,
              progress: (total > 0) ? bytes / total : null);
      }
    }
  }

  /// يتحقق من الملف ثم يطلق شاشة تثبيت النظام.
  Stream<InstallProgress> _install(String path) async* {
    final apk = File(path);
    if (!apk.existsSync() || apk.lengthSync() < 1024 * 1024) {
      await _saveDownloadId(null);
      yield const InstallProgress(InstallPhase.failed,
          error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.');
      return;
    }
    yield const InstallProgress(InstallPhase.launchingInstaller, progress: 1);
    try {
      final r =
          await _channel.invokeMethod<String>('installApk', {'path': path});
      if (r == 'ok') {
        await _saveDownloadId(null);
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

  /// مسار احتياطي: تنزيل http داخل التطبيق (كما في السابق) إذا تعذّر
  /// استخدام مدير تنزيلات النظام.
  Stream<InstallProgress> _fallbackHttpDownload(String url) async* {
    final File apk;
    try {
      final cache = await getTemporaryDirectory();
      final dir = Directory('${cache.path}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
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
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        yield InstallProgress(InstallPhase.failed,
            error: 'الخادم أعاد الرمز ${res.statusCode}.');
        return;
      }
      final total = res.contentLength;
      var received = 0;
      sink = apk.openWrite();
      var lastYield = DateTime.now();
      await for (final chunk
          in res.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        received += chunk.length;
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
    yield* _install(apk.path);
  }
}
