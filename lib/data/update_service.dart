// نظام التحديث المركزي.
//
// يقرأ بيان إصدار (version.json) يُنشر تلقائيًا مع كل إصدار على GitHub،
// يقارنه بإصدار التطبيق الحالي، ويقرر: لا تحديث / تحديث اختياري / تحديث إجباري.
// التنزيل والتثبيت يتمّان بفتح رابط الإصدار في المتصفح — لا نُنزّل ونُثبّت
// حزمًا تلقائيًا لأن ذلك يتطلب أذونات خطرة على أندرويد ولا يعمل في المتاجر.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/app_version.dart';

/// نتيجة فحص التحديث.
enum UpdateStatus {
  /// التطبيق محدّث.
  upToDate,

  /// يوجد إصدار أحدث (اختياري).
  available,

  /// يوجد إصدار أحدث وإلزامي (الإصدار الحالي أقدم من minSupported).
  required_,

  /// تعذّر الفحص (لا شبكة / خطأ خادم / بيان تالف).
  unknown,
}

/// منصّة التنزيل المطلوبة.
enum UpdatePlatform { android, windows, other }

class UpdateInfo {
  final UpdateStatus status;
  final AppSemVer current;
  final AppSemVer? latest;

  /// أدنى إصدار مدعوم؛ أقل منه = تحديث إجباري.
  final AppSemVer? minSupported;

  /// رابط صفحة الإصدار (يُفتح في المتصفح).
  final String? releaseUrl;

  /// رابط الملف المباشر للمنصّة الحالية إن وُجد.
  final String? downloadUrl;

  /// ملاحظات الإصدار بالعربية.
  final String notes;

  /// تاريخ النشر إن وُجد.
  final DateTime? publishedAt;

  /// سبب الفشل عند status == unknown.
  final String? error;

  const UpdateInfo({
    required this.status,
    required this.current,
    this.latest,
    this.minSupported,
    this.releaseUrl,
    this.downloadUrl,
    this.notes = '',
    this.publishedAt,
    this.error,
  });

  bool get hasUpdate =>
      status == UpdateStatus.available || status == UpdateStatus.required_;

  bool get isMandatory => status == UpdateStatus.required_;

  /// نص مختصر للعرض.
  String get headline => switch (status) {
        UpdateStatus.upToDate => 'التطبيق محدَّث',
        UpdateStatus.available => 'يتوفّر تحديث جديد',
        UpdateStatus.required_ => 'تحديث إلزامي مطلوب',
        UpdateStatus.unknown => 'تعذّر التحقق من التحديثات',
      };
}

/// مزوّد الوقت — لتسهيل الاختبار.
typedef NowFn = DateTime Function();

class UpdateService {
  /// الرابط الافتراضي لبيان الإصدار (يُنشر مع كل بناء ناجح).
  static const String kDefaultManifestUrl =
      'https://github.com/iggdigd218-dev/sijil-al-mabiat-wal-duyun/releases/download/latest/version.json';

  /// صفحة الإصدار الرسمية (احتياطي إذا لم يذكر البيان رابطًا).
  static const String kFallbackReleaseUrl =
      'https://github.com/iggdigd218-dev/sijil-al-mabiat-wal-duyun/releases/latest';

  final String manifestUrl;
  final http.Client Function() _clientFactory;
  final AppSemVer current;
  final UpdatePlatform platform;
  final Duration timeout;

  UpdateService({
    String? manifestUrl,
    http.Client Function()? clientFactory,
    AppSemVer? current,
    UpdatePlatform? platform,
    this.timeout = const Duration(seconds: 12),
  })  : manifestUrl = manifestUrl ?? kDefaultManifestUrl,
        _clientFactory = clientFactory ?? (() => http.Client()),
        current = current ?? AppSemVer.current,
        platform = platform ?? detectPlatform();

  static UpdatePlatform detectPlatform() {
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isWindows) return UpdatePlatform.windows;
    return UpdatePlatform.other;
  }

  /// يفحص وجود تحديث. لا يرمي استثناءً أبدًا — يُعيد status=unknown عند الفشل.
  Future<UpdateInfo> check() async {
    final uri = Uri.tryParse(manifestUrl);
    if (uri == null || !uri.isScheme('https')) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'رابط بيان التحديث غير صالح (يجب أن يكون https).',
      );
    }
    // كسر كاش CDN الوسيط: GitHub/Fastly قد يخدمان version.json قديماً
    // لدقائق بعد النشر — معامل عشوائي لكل طلب يضمن قراءة أحدث بيان.
    final uriWithBuster = uri.replace(queryParameters: {
      ...uri.queryParameters,
      't': '${DateTime.now().millisecondsSinceEpoch}',
    });
    final client = _clientFactory();
    try {
      final res = await client.get(uriWithBuster, headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
      }).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'الخادم أعاد الرمز ${res.statusCode}.',
        );
      }
      // نفكّ البايتات بـ UTF-8 صراحةً: GitHub يقدّم version.json بنوع
      // application/octet-stream بلا charset، فتتراجع res.body إلى Latin-1
      // ويتشوّه النص العربي في الملاحظات (Ø§Ù…). allowMalformed حمايةً من بايتات شاذة.
      return _parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    } on TimeoutException {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'انتهت مهلة الاتصال.',
      );
    } catch (e) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'تعذّر الاتصال بالإنترنت.',
      );
    } finally {
      client.close();
    }
  }

  UpdateInfo _parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث تالف.',
      );
    }
    if (decoded is! Map) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث بصيغة غير متوقعة.',
      );
    }
    final map = Map<String, Object?>.from(decoded);
    final latest = AppSemVer.tryParse('${map['version'] ?? ''}');
    if (latest == null) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث لا يحتوي رقم إصدار صالح.',
      );
    }
    final minSupported = AppSemVer.tryParse('${map['minSupported'] ?? ''}');
    final downloads = map['downloads'];
    String? downloadUrl;
    if (downloads is Map) {
      final key = switch (platform) {
        UpdatePlatform.android => 'android',
        UpdatePlatform.windows => 'windows',
        UpdatePlatform.other => '',
      };
      final v = downloads[key];
      if (v is String && v.startsWith('https://')) downloadUrl = v;
    }
    final release = map['releaseUrl'];
    final releaseUrl = (release is String && release.startsWith('https://'))
        ? release
        : kFallbackReleaseUrl;

    final status = () {
      if (minSupported != null && current < minSupported) {
        return UpdateStatus.required_;
      }
      if (latest > current) return UpdateStatus.available;
      return UpdateStatus.upToDate;
    }();

    return UpdateInfo(
      status: status,
      current: current,
      latest: latest,
      minSupported: minSupported,
      releaseUrl: releaseUrl,
      downloadUrl: downloadUrl,
      notes: '${map['notes'] ?? ''}'.trim(),
      publishedAt: DateTime.tryParse('${map['publishedAt'] ?? ''}'),
    );
  }
}
