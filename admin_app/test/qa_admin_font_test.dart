// (الهوية البصرية — لوحة المدير) اختبارات خط Cairo.
//
// الخلفية: اللوحة عربية بالكامل (`locale: ar` + `Directionality` RTL) لكن
// ثيمها كان يطلب `fontFamily: 'Roboto'` — وRoboto لا يحمل أي محرف عربي،
// فكانت كل النصوص العربية ترتد إلى خط النظام (Noto Sans Arabic) وتنفصل
// بصرياً عن التطبيق الرئيسي الذي يستخدم Cairo.
//
// تُشغَّل هذه الحزمة من مجلد `admin_app` (working-directory في CI)، لذلك
// المسارات نسبية إليه وأصول الخط تُفحص عبر `../assets/fonts/`.
// لا تبعيات خارجية: dart:io + flutter_test فقط.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// الأوزان المعلنة لعائلة في pubspec.yaml: {الوزن: مسار الأصل}.
/// الأصل بلا سطر `weight:` يُعدّ وزناً 400 (سلوك Flutter نفسه).
Map<int, String> _declaredWeights(String pubspec, String family) {
  final block = RegExp(
    r'-\s+family:\s*' + family + r'\s*\n(?:[ \t]*fonts:[ \t]*\n)?'
        r'((?:\s{6,}-\s+asset:[^\n]*\n(?:\s+weight:\s*\d+\s*\n)?)*)',
  ).firstMatch(pubspec);
  expect(block, isNotNull,
      reason: 'عائلة $family غير مسجّلة في pubspec.yaml — الثيم يطلبها '
          'فيرتد المحرك إلى خط النظام');
  final out = <int, String>{};
  final entries =
      RegExp(r'-\s+asset:\s*(\S+)[^\n]*\n(?:[ \t]*weight:[ \t]*(\d+)[ \t]*\n)?')
          .allMatches(block!.group(1)!);
  for (final e in entries) {
    out[int.tryParse(e.group(2) ?? '') ?? 400] = e.group(1)!;
  }
  return out;
}

/// الأوزان المستخدمة فعلاً في شيفرة اللوحة.
Set<int> _usedWeights(Directory lib) {
  final used = <int>{};
  final pattern = RegExp(r'FontWeight\.(?:w([0-9]{3})|(bold)|(normal))');
  final files = lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  expect(files, isNotEmpty, reason: 'لم يُعثر على أي ملف dart في lib/');
  for (final f in files) {
    for (final m in pattern.allMatches(f.readAsStringSync())) {
      final digits = m.group(1);
      used.add(digits != null
          ? int.parse(digits)
          : (m.group(2) != null ? 700 : 400));
    }
  }
  return used;
}

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final cairo = _declaredWeights(pubspec, 'Cairo');

  group('خط Cairo في لوحة المدير', () {
    test('العائلة مسجّلة وكل أصولها المشتركة موجودة على القرص', () {
      expect(cairo, isNotEmpty,
          reason: 'لا أوزان Cairo مُعلنة في admin_app/pubspec.yaml');
      for (final e in cairo.entries) {
        expect(File(e.value).existsSync(), isTrue,
            reason: 'pubspec يعلن ${e.value} (وزن ${e.key}) والملف غير '
                'موجود — تأكد أن actions/checkout يجري على جذر المستودع '
                'وأن المسار النسبي ../assets/fonts/ ما زال صالحاً');
      }
    });

    test('الأصول مشتركة مع التطبيق الرئيسي (لا نسخ مكرّر يملأ الحصة)', () {
      for (final p in cairo.values) {
        expect(p.startsWith('../assets/fonts/'), isTrue,
            reason: '$p خارج مجلد الأصول المشترك — انسخه إلى المسار '
                'المشترك بدل تضخيم المستودع بملف ثانٍ');
      }
    });

    test('كل FontWeight مستخدم في lib/ له وزن Cairo مُعلن', () {
      final used = _usedWeights(Directory('lib'));
      final missing = used.difference(cairo.keys.toSet()).toList()..sort();
      expect(missing, isEmpty,
          reason: 'أوزان مستخدمة بلا ملف Cairo مُعلن (ستُحاكى اصطناعياً '
              'أو ترتد لخط النظام): $missing');
    });

    test('الثيم يطلب Cairo ولا يبقى أي طلب لخط بلا محارف عربية', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src.contains("fontFamily: 'Cairo'"), isTrue,
          reason: 'main.dart لا يربط Cairo في ThemeData');
      expect(src.contains("fontFamily: 'Roboto'"), isFalse,
          reason: 'Roboto ما زال مطلوباً — لا يملك محارف عربية فترتد '
              'الواجهة كلها إلى خط النظام');
      // اللوحة عربية: أي خط مُعلن يجب أن يكون مسجّلاً في pubspec.
      final families = RegExp(r"fontFamily:\s*'([^']+)'")
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet();
      for (final f in families) {
        expect(pubspec.contains('- family: $f'), isTrue,
            reason: 'الثيم يطلب عائلة "$f" غير المسجّلة في pubspec.yaml');
      }
    });

    test('CI يعيد بناء اللوحة عند تغيير الخطوط المشتركة', () {
      final wf =
          File('../.github/workflows/build-admin-apk.yml').readAsStringSync();
      expect(wf.contains('assets/fonts/**'), isTrue,
          reason: 'workflow بناء APK المدير لا يراقب assets/fonts/** — '
              'تغيير خط Cairo المشترك سيشحن بناءً بأصول قديمة');
    });
  });
}
