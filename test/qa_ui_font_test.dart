// (الهوية البصرية — خط Cairo) اختبارات تمنع عودة الواجهة إلى خط النظام.
//
// الخلفية: الشيفرة كانت تستخدم FontWeight.w800 في 94 موضعاً و w900 في 6
// مواضع، بينما pubspec يعلن أوزان Cairo 400/500/600/700 فقط. الوزن غير
// المُعلن لا يملك ملفاً في العائلة، فيحاكيه المحرك اصطناعياً (synthetic
// bold) — وعلى سطح المكتب قد يرتد إلى خط النظام العربي (Noto Sans Arabic)
// فتضيع الهوية البصرية. هذه الحزمة تثبّت المطابقة من الطرفين:
//   ١) كل ملف خط مضمّن هو فعلاً Cairo بالوزن الذي يُعلنه pubspec.
//   ٢) كل وزن يُستخدم في lib/ له ملف مضمّن ومُعلن.
//   ٣) الثيم يربط العائلة نفسها التي يعلنها pubspec (لا انحراف يدوي).
//
// لا تبعيات خارجية: dart:io + flutter_test فقط، وقارئ TTF مصغّر مضمّن.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/theme.dart';

/// وصف موجز لملف TTF — ما يلزم للتحقق من العائلة والوزن والتغطية العربية.
class _TtfInfo {
  final String family; // nameID 1 (أو 16 إن وُجد)
  final String typographicFamily; // nameID 16 — '' إن لم يُسجَّل
  final String postScriptName; // nameID 6
  final String version; // nameID 5
  final int weightClass; // OS/2.usWeightClass
  final int numGlyphs;
  final int arabicGlyphs;
  final bool isVariable;

  const _TtfInfo({
    required this.family,
    required this.typographicFamily,
    required this.postScriptName,
    required this.version,
    required this.weightClass,
    required this.numGlyphs,
    required this.arabicGlyphs,
    required this.isVariable,
  });

  /// اسم العائلة الذي يتعرّف عليه Flutter: Typographic (16) إن وُجد،
  /// وإلا Family (1). Cairo-Medium مثلاً: 1="Cairo Medium" و16="Cairo"
  /// — والمحرك يقرأ 16 فيضمّه لعائلة "Cairo" لا لعائلة مستقلة.
  String get effectiveFamily =>
      typographicFamily.isNotEmpty ? typographicFamily : family;

  @override
  String toString() =>
      '$postScriptName fam=$effectiveFamily w=$weightClass glyphs=$numGlyphs';
}

int _u16(ByteData d, int o) => d.getUint16(o);

int _u32(ByteData d, int o) => d.getUint32(o);

/// قارئ TTF مصغّر: يكتفي بجدول name (للهوية) وOS/2 (للوزن) وcmap (للتغطية)
/// وmaxp (لعدد الحروف) وقائمة الجداول (لاكتشاف الخط المتغيّر fvar).
_TtfInfo _readTtf(File f) {
  final bytes = f.readAsBytesSync();
  final d = ByteData.sublistView(bytes);
  expect(_u32(d, 0), 0x00010000,
      reason: '${f.path} ليس ملف TTF صالحاً (sfnt version خاطئ)');
  final numTables = _u16(d, 4);
  final tables = <String, List<int>>{};
  for (var i = 0; i < numTables; i++) {
    final r = 12 + i * 16;
    final tag = String.fromCharCodes(bytes.sublist(r, r + 4));
    tables[tag] = [_u32(d, r + 8), _u32(d, r + 12)]; // offset, length
  }

  // — جدول name —
  final nameRec = tables['name'];
  expect(nameRec, isNotNull, reason: '${f.path} بلا جدول name');
  final nOff = nameRec![0];
  final count = _u16(d, nOff + 2);
  final strOff = _u16(d, nOff + 4);
  final base = nOff + strOff;
  final names = <int, String>{};
  for (var i = 0; i < count; i++) {
    final r = nOff + 6 + i * 12;
    final pid = _u16(d, r);
    final nid = _u16(d, r + 6);
    final len = _u16(d, r + 8);
    final so = _u16(d, r + 10);
    if (![1, 2, 5, 6, 16, 17].contains(nid)) continue;
    if (names.containsKey(nid)) continue; // أول سجل يكفي للتحقق.
    final raw = bytes.sublist(base + so, base + so + len);
    String s;
    if (pid == 0 || pid == 3) {
      final cu = <int>[];
      for (var k = 0; k + 1 < raw.length; k += 2) {
        cu.add((raw[k] << 8) | raw[k + 1]);
      }
      s = String.fromCharCodes(cu);
    } else {
      s = String.fromCharCodes(raw);
    }
    names[nid] = s.trim();
  }

  // — OS/2.usWeightClass —
  final os2 = tables['OS/2'];
  expect(os2, isNotNull, reason: '${f.path} بلا جدول OS/2');
  final weightClass = _u16(d, os2![0] + 4);

  // — maxp.numGlyphs —
  final maxp = tables['maxp'];
  expect(maxp, isNotNull, reason: '${f.path} بلا جدول maxp');
  final numGlyphs = _u16(d, maxp![0] + 4);

  // — cmap: عدد المحارف العربية المدعومة —
  var arabic = 0;
  final cmap = tables['cmap'];
  if (cmap != null) {
    final cOff = cmap[0];
    final nSub = _u16(d, cOff + 2);
    final covered = <int>{};
    for (var i = 0; i < nSub; i++) {
      final r = cOff + 4 + i * 8;
      final subOff = cOff + _u32(d, r + 4);
      final format = _u16(d, subOff);
      // نكتفي بالصيغتين الشائعين 4 و12 (BMP + full Unicode).
      int segCount;
      if (format == 4) {
        segCount = _u16(d, subOff + 6) ~/ 2;
        final endOff = subOff + 14;
        for (var s = 0; s < segCount; s++) {
          final end = _u16(d, endOff + s * 2);
          final start = _u16(d, endOff + segCount * 2 + 2 + s * 2);
          for (var c = start; c <= end && c < 0x10000; c++) {
            if (_isArabic(c)) covered.add(c);
          }
        }
      } else if (format == 12) {
        final nGroups = _u32(d, subOff + 12);
        for (var g = 0; g < nGroups; g++) {
          final gr = subOff + 16 + g * 12;
          final start = _u32(d, gr);
          final end = _u32(d, gr + 4);
          if (end - start > 0x10000) continue;
          for (var c = start; c <= end; c++) {
            if (_isArabic(c)) covered.add(c);
          }
        }
      }
    }
    arabic = covered.length;
  }

  return _TtfInfo(
    family: names[1] ?? '',
    typographicFamily: names[16] ?? '',
    postScriptName: names[6] ?? '',
    version: names[5] ?? '',
    weightClass: weightClass,
    numGlyphs: numGlyphs,
    arabicGlyphs: arabic,
    isVariable: tables.containsKey('fvar'),
  );
}

bool _isArabic(int c) =>
    (c >= 0x0600 && c <= 0x06FF) || // Arabic
    (c >= 0x0750 && c <= 0x077F) || // Arabic Supplement
    (c >= 0x08A0 && c <= 0x08FF) || // Arabic Extended-A
    (c >= 0xFB50 && c <= 0xFDFF) || // Presentation Forms-A
    (c >= 0xFE70 && c <= 0xFEFF); // Presentation Forms-B

/// الوزن الرقمي لأي صيغة FontWeight (w### أو bold أو normal).
/// `FontWeight.bold` == w700 و`FontWeight.normal` == w400 في Flutter.
int _weightValue({String? digits, required bool bold, required bool normal}) {
  if (digits != null) return int.parse(digits);
  if (bold) return 700;
  if (normal) return 400;
  return 0;
}

/// الأوزان المعلنة لعائلة في pubspec.yaml: {الوزن: مسار الأصل}.
/// الأصل بلا سطر `weight:` يُعدّ وزناً 400 (سلوك Flutter نفسه —
/// Tajawal-Regular مثلاً مُعلن بلا وزن).
Map<int, String> _declaredWeights(String pubspec, String family) {
  final block = RegExp(
    // البنية في pubspec: `- family: X` ثم `fonts:` ثم بنود `- asset:` بمسافة
    // بادئة أعمق، كلٌّ يتبعه `weight:` اختياري (غيابه = 400).
    r'-\s+family:\s*' + family + r'\s*\n(?:[ \t]*fonts:[ \t]*\n)?'
        r'((?:\s{6,}-\s+asset:[^\n]*\n(?:\s+weight:\s*\d+\s*\n)?)*)',
  ).firstMatch(pubspec);
  expect(block, isNotNull,
      reason: 'عائلة $family غير مسجّلة في pubspec.yaml (قسم flutter/fonts)');
  final out = <int, String>{};
  final body = block!.group(1)!;
  final entries =
      RegExp(r'-\s+asset:\s*(\S+)[^\n]*\n(?:[ \t]*weight:[ \t]*(\d+)[ \t]*\n)?')
          .allMatches(body);
  for (final e in entries) {
    out[int.tryParse(e.group(2) ?? '') ?? 400] = e.group(1)!;
  }
  return out;
}

/// الأوزان المستخدمة فعلاً في lib/ (مجموعة مرتبة).
///
/// المسح نصّي مقصود: يقرأ الشيفرة كما هي بلا تحليل AST، فيبقى الاختبار
/// خفيفاً وبلا تبعيات، ويلتقط أي `FontWeight` جديد يُضاف في أي ملف.
Set<int> _usedWeights(Directory lib) {
  final used = <int>{};
  final pattern = RegExp(
    r'FontWeight\.(?:w([0-9]{3})|(bold)|(normal))',
  );
  final files = lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  expect(files, isNotEmpty, reason: 'لم يُعثر على أي ملف dart في lib/');
  for (final f in files) {
    for (final m in pattern.allMatches(f.readAsStringSync())) {
      used.add(_weightValue(
        digits: m.group(1),
        bold: m.group(2) != null,
        normal: m.group(3) != null,
      ));
    }
  }
  return used;
}

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final cairo = _declaredWeights(pubspec, 'Cairo');

  group('أصول خط Cairo المضمّنة', () {
    test('كل أصل مُعلن موجود فعلاً على القرص', () {
      for (final e in cairo.entries) {
        expect(File(e.value).existsSync(), isTrue,
            reason: 'pubspec يعلن ${e.value} (وزن ${e.key}) والملف غير موجود');
      }
    });

    test('كل ملف هو Cairo حقيقي (اسم العائلة) بوزن مطابق لإعلان pubspec', () {
      for (final e in cairo.entries) {
        final info = _readTtf(File(e.value));
        expect(info.effectiveFamily, 'Cairo',
            reason: '${e.value} ليس من عائلة Cairo: $info');
        expect(info.weightClass, e.key,
            reason: 'usWeightClass في ${e.value} (${info.weightClass}) '
                'لا يطابق الوزن المُعلن في pubspec (${e.key})');
        expect(info.isVariable, isFalse,
            reason: '${e.value} خط متغيّر (fvar) — يُضمَّن مثيل ثابت '
                'حتى لا يختلف الرسم بين المحركات');
      }
    });

    test('الأوزان 800 و900 مضمّنة (كانت مستخدمة بلا ملفات)', () {
      expect(cairo.containsKey(800), isTrue,
          reason: 'لا يوجد Cairo بوزن 800 — الشيفرة تستخدم FontWeight.w800 '
              'في عشرات المواضع (العناوين والمبالغ المالية)');
      expect(cairo.containsKey(900), isTrue,
          reason: 'لا يوجد Cairo بوزن 900 — الشيفرة تستخدم FontWeight.w900');
      expect(_readTtf(File(cairo[800]!)).postScriptName, 'Cairo-ExtraBold');
      expect(_readTtf(File(cairo[900]!)).postScriptName, 'Cairo-Black');
    });

    test('كل الأوزان من نفس إصدار Cairo (لا خلط بين إصدارين)', () {
      final versions = <String, Set<String>>{};
      for (final e in cairo.entries) {
        versions.putIfAbsent(_readTtf(File(e.value)).version, () => {})
            .add(e.value);
      }
      expect(versions.length, 1,
          reason: 'أوزان Cairo من إصدارات مختلفة — سيختلف التصميم بين وزن '
              'وآخر: $versions');
    });

    test('التغطية العربية متساوية بين كل الأوزان (لا حروف تسقط عند وزن)', () {
      final counts = <int, int>{};
      for (final e in cairo.entries) {
        final i = _readTtf(File(e.value));
        counts[e.key] = i.arabicGlyphs;
        expect(i.arabicGlyphs, greaterThan(200),
            reason: '${e.value} يغطي ${i.arabicGlyphs} محرفاً عربياً فقط');
      }
      expect(counts.values.toSet().length, 1,
          reason: 'التغطية العربية متفاوتة بين الأوزان: $counts — وزن سيُظهر '
              'مربعات/ارتداداً لخط النظام في بعض الحروف');
    });
  });

  group('مطابقة الاستخدام مع الإعلان', () {
    test('كل FontWeight مستخدم في lib/ له ملف Cairo مضمّن', () {
      final used = _usedWeights(Directory('lib'));
      final missing = used.difference(cairo.keys.toSet()).toList()..sort();
      expect(missing, isEmpty,
          reason: 'أوزان مستخدمة في lib/ بلا ملف Cairo مُعلن في pubspec '
              '(سيُحاكى اصطناعياً أو يرتد لخط النظام): $missing');
    });

    test('لا أوزان مضمّنة ميتة (تضخيم بلا داعٍ لحجم التطبيق)', () {
      final used = _usedWeights(Directory('lib'));
      // 400 مستثنى: لا يُكتب `FontWeight.w400` صراحة في العادة لأنه الوزن
      // الضمني لكل TextStyle — وهو أصل العائلة (Cairo Regular) الذي تُرسم
      // به أغلب النصوص، فحذفه يكسر الواجهة كلها.
      final declared = cairo.keys.toSet()..remove(400);
      final unused = declared.difference(used).toList()..sort();
      expect(unused, isEmpty,
          reason: 'أوزان مضمّنة لا تستخدمها الشيفرة — أزلها أو استخدمها: '
              '$unused');
    });
  });

  group('ربط الثيم بالعائلة', () {
    test('uiFontFamily يطابق العائلة المسجّلة في pubspec حرفياً', () {
      expect(uiFontFamily, 'Cairo');
      expect(pubspec.contains('- family: ${uiFontFamily!}'), isTrue,
          reason: 'الثيم يطلب عائلة "${uiFontFamily}" غير المسجّلة في '
              'pubspec.yaml — المحرك سيرتد إلى خط النظام');
    });

    test('ThemeData يربط الخط على الشجرتين الفاتحة والداكنة', () {
      final src = File('lib/core/theme.dart').readAsStringSync();
      expect(RegExp(r'fontFamily:\s*uiFontFamily').hasMatch(src), isTrue,
          reason: 'theme.dart لا يمرر fontFamily إلى ThemeData');
      // textTheme يُبنى بأنماط بلا عائلة صريحة — ThemeData يطبّق عليها
      // fontFamily داخلياً عبر TextTheme.apply، فتُرث Cairo كاملةً.
      expect(src.contains('fontFamily: uiFontFamily'), isTrue);
      expect(AppTheme.light().fontFamily, 'Cairo');
      expect(AppTheme.dark().fontFamily, 'Cairo');
      expect(AppTheme.light().textTheme.titleLarge?.fontFamily, 'Cairo',
          reason: 'textTheme لم يرث Cairo — سيتراجع إلى خط النظام');
      expect(AppTheme.dark().textTheme.bodyMedium?.fontFamily, 'Cairo');
    });

    test('خط PDF (Tajawal) ما زال مضمّناً ومسجّلاً — لا كسر لشبكة التقارير',
        () {
      final tajawal = _declaredWeights(pubspec, 'Tajawal');
      expect(tajawal, isNotEmpty);
      for (final p in tajawal.values) {
        expect(File(p).existsSync(), isTrue,
            reason: 'reports_screen/voucher_doc يحمّلان $p بالمسار');
      }
      for (final p in [
        'assets/fonts/Tajawal-Regular.ttf',
        'assets/fonts/Tajawal-Bold.ttf',
      ]) {
        expect(File(p).existsSync(), isTrue,
            reason: 'مسار rootBundle.load في PDF يعتمد على $p');
      }
    });
  });
}
