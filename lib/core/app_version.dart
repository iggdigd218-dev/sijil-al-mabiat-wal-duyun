// المصدر الوحيد لإصدار التطبيق داخل الشيفرة.
//
// كان الإصدار مكتوبًا يدويًا في الدرج الجانبي ("الإصدار 3.4.0") وتخلّف عن
// pubspec.yaml (3.12.3+20). الآن يُقرأ من هنا فقط، ويوجد اختبار يفشل إذا
// اختلفت هذه القيم عن pubspec.yaml حتى لا تتخلّف مرة أخرى.
library;

/// إصدار التطبيق المعروض (يطابق pubspec.yaml).
const String kAppVersion = '3.31.1';

/// رقم البناء (ما بعد + في pubspec.yaml).
const int kAppBuild = 54;

/// النص المعروض للمستخدم.
String get appVersionLabel => 'الإصدار $kAppVersion';

/// إصدار دلالي قابل للمقارنة (major.minor.patch) مع رقم بناء اختياري.
class AppSemVer implements Comparable<AppSemVer> {
  final int major;
  final int minor;
  final int patch;
  final int build;

  const AppSemVer(this.major, this.minor, this.patch, [this.build = 0]);

  static const AppSemVer zero = AppSemVer(0, 0, 0);

  /// يقبل الصيغ: `3.12.3` و `3.12.3+20` و `v3.12.3` و `flutter-v3.7.12`.
  /// يُعيد null إذا لم يعثر على رقم إصدار صالح.
  static AppSemVer? tryParse(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?(?:\+(\d+))?').firstMatch(raw);
    if (m == null) return null;
    return AppSemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.tryParse(m.group(3) ?? '0') ?? 0,
      int.tryParse(m.group(4) ?? '0') ?? 0,
    );
  }

  /// إصدار التطبيق الحالي — يُشتق تلقائياً من kAppVersion/kAppBuild.
  ///
  /// كان الرقم مكتوباً يدوياً (3,20,0) وتخلّف عن kAppVersion عند الترقية،
  /// فظل زر «تحديث الآن» عالقاً يعرض نفس النسخة كتحديث جديد حتى بعد
  /// التثبيت. الاشتقاق التلقائي + اختبار مطابقة يمنعان تكرارها نهائياً.
  static final AppSemVer current =
      tryParse('$kAppVersion+$kAppBuild') ?? const AppSemVer(0, 0, 0);

  @override
  int compareTo(AppSemVer o) {
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    if (patch != o.patch) return patch.compareTo(o.patch);
    return build.compareTo(o.build);
  }

  bool operator >(AppSemVer o) => compareTo(o) > 0;
  bool operator <(AppSemVer o) => compareTo(o) < 0;
  bool operator >=(AppSemVer o) => compareTo(o) >= 0;
  bool operator <=(AppSemVer o) => compareTo(o) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppSemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.build == build;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() =>
      build > 0 ? '$major.$minor.$patch+$build' : '$major.$minor.$patch';
}
