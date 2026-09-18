#!/usr/bin/env python3
"""فحص أصول الخطوط ومطابقتها للاستخدام — بلا Flutter وبلا تبعيات بايثون.

يكرر منطق حزمتي الاختبار (test/qa_ui_font_test.dart و
admin_app/test/qa_admin_font_test.dart) خارج دارت، فيعمل في أي بيئة
حتى تلك المحجوبة عن pub.dev/storage.googleapis.com حيث يتعذّر تشغيل
`flutter test`. يقرأ ملفات TTF نفسها (جداول name وOS/2 وcmap وmaxp)
فيتحقق من الهوية الحقيقية للخط لا من اسم الملف فحسب.

الاستخدام:
    python3 scripts/verify_fonts.py            # تقرير مفصّل
    python3 scripts/verify_fonts.py --quiet    # الأخطاء فقط، ورمز خروج
"""
from __future__ import annotations

import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CAIRO_WEIGHTS = {400, 500, 600, 700, 800, 900}

PAT_FAMILY_BLOCK = (
    r'-\s+family:\s*(%s)\s*\n(?:[ \t]*fonts:[ \t]*\n)?'
    r'((?:\s{6,}-\s+asset:[^\n]*\n(?:\s+weight:\s*\d+\s*\n)?)*)'
)
PAT_ASSET = r'-\s+asset:\s*(\S+)[^\n]*\n(?:[ \t]*weight:[ \t]*(\d+)[ \t]*\n)?'
PAT_FONTWEIGHT = r'FontWeight\.(?:w([0-9]{3})|(bold)|(normal))'


# ───────────────────────── قارئ TTF مصغّر ─────────────────────────
def _is_arabic(c: int) -> bool:
    return (
        0x0600 <= c <= 0x06FF          # Arabic
        or 0x0750 <= c <= 0x077F       # Arabic Supplement
        or 0x08A0 <= c <= 0x08FF       # Arabic Extended-A
        or 0xFB50 <= c <= 0xFDFF       # Presentation Forms-A
        or 0xFE70 <= c <= 0xFEFF       # Presentation Forms-B
    )


def _u16(data: bytes, off: int) -> int:
    """قراءة 16-bit بلا تجاوز نهاية الملف (0 عند الاقتطاع)."""
    chunk = data[off:off + 2]
    return struct.unpack('>H', chunk)[0] if len(chunk) == 2 else 0


def _u32(data: bytes, off: int) -> int:
    chunk = data[off:off + 4]
    return struct.unpack('>I', chunk)[0] if len(chunk) == 4 else 0


def read_ttf(path: str) -> dict:
    """يقرأ ما يلزم للتحقق من هوية الخط: العائلة والوزن والتغطية والإصدار."""
    with open(path, 'rb') as fh:
        data = fh.read()
    if len(data) < 12:
        raise ValueError(f'{path}: أقصر من ترويسة sfnt')
    if _u32(data, 0) != 0x00010000:
        raise ValueError(f'{path}: ليس TTF صالحاً (sfnt version خاطئ)')

    num_tables = _u16(data, 4)
    tables: dict[str, tuple[int, int]] = {}
    for i in range(num_tables):
        rec = 12 + i * 16
        tag = data[rec:rec + 4].decode('latin1')
        off, length = _u32(data, rec + 8), _u32(data, rec + 12)
        tables[tag] = (off, length)

    # جدول name → الهوية
    names: dict[int, str] = {}
    if 'name' in tables:
        off = tables['name'][0]
        count, str_off = _u16(data, off + 2), _u16(data, off + 4)
        base = off + str_off
        for i in range(count):
            rec = off + 6 + i * 12
            pid = _u16(data, rec)
            nid = _u16(data, rec + 6)
            length, so = _u16(data, rec + 8), _u16(data, rec + 10)
            if nid not in (1, 2, 5, 6, 16, 17) or nid in names:
                continue
            raw = data[base + so:base + so + length]
            if pid in (0, 3):
                text = raw.decode('utf-16-be', 'replace')
            else:
                text = raw.decode('latin1', 'replace')
            names[nid] = text.strip()

    weight_class = _u16(data, tables['OS/2'][0] + 4) if 'OS/2' in tables else 0
    num_glyphs = _u16(data, tables['maxp'][0] + 4) if 'maxp' in tables else 0

    arabic: set[int] = set()
    if 'cmap' in tables:
        c_off = tables['cmap'][0]
        n_sub = _u16(data, c_off + 2)
        for i in range(n_sub):
            rec = c_off + 4 + i * 8
            sub = c_off + _u32(data, rec + 4)
            fmt = _u16(data, sub)
            if fmt == 4:
                seg_count = _u16(data, sub + 6) // 2
                end_off = sub + 14
                start_off = end_off + seg_count * 2 + 2
                for s in range(seg_count):
                    end = _u16(data, end_off + s * 2)
                    start = _u16(data, start_off + s * 2)
                    for c in range(start, min(end, 0xFFFF) + 1):
                        if _is_arabic(c):
                            arabic.add(c)
            elif fmt == 12:
                n_groups = _u32(data, sub + 12)
                for g in range(min(n_groups, 10000)):
                    gr = sub + 16 + g * 12
                    start, end = _u32(data, gr), _u32(data, gr + 4)
                    if end - start > 0x10000:
                        continue
                    for c in range(start, end + 1):
                        if _is_arabic(c):
                            arabic.add(c)

    return {
        'path': path,
        'family': names.get(16) or names.get(1) or '',
        'family_raw': names.get(1, ''),
        'postscript': names.get(6, ''),
        'version': names.get(5, ''),
        'weight': weight_class,
        'glyphs': num_glyphs,
        'arabic': len(arabic),
        'variable': 'fvar' in tables,
    }


# ───────────────────────── قراءة pubspec ─────────────────────────
def declared_weights(pubspec_text: str, family: str, base_dir: str) -> dict[int, str]:
    """{الوزن: مسار الأصل} لعائلة في pubspec. الأصل بلا weight = 400."""
    m = re.search(PAT_FAMILY_BLOCK % re.escape(family), pubspec_text)
    if not m:
        return {}
    out: dict[int, str] = {}
    for e in re.finditer(PAT_ASSET, m.group(2)):
        weight = int(e.group(2) or 400)
        asset = e.group(1)
        out[weight] = asset if os.path.isabs(asset) else os.path.normpath(
            os.path.join(base_dir, asset))
    return out


def used_weights(lib_dir: str) -> set[int]:
    used: set[int] = set()
    for root, _, files in os.walk(lib_dir):
        for name in files:
            if not name.endswith('.dart'):
                continue
            with open(os.path.join(root, name), encoding='utf-8') as fh:
                for m in re.finditer(PAT_FONTWEIGHT, fh.read()):
                    digits, bold, normal = m.group(1), m.group(2), m.group(3)
                    used.add(int(digits) if digits else (700 if bold else (400 if normal else 0)))
    return used


# ───────────────────────── الفحوص ─────────────────────────
class Report:
    def __init__(self, quiet: bool):
        self.quiet = quiet
        self.failures: list[str] = []
        self.passes = 0

    def check(self, condition: bool, message: str) -> bool:
        if condition:
            self.passes += 1
            if not self.quiet:
                print(f'  ✅ {message}')
        else:
            self.failures.append(message)
            print(f'  ❌ {message}')
        return condition

    def section(self, title: str) -> None:
        if not self.quiet:
            print(f'\n── {title} ──')


def verify_main_app(rep: Report) -> None:
    with open(os.path.join(ROOT, 'pubspec.yaml'), encoding='utf-8') as fh:
        pubspec = fh.read()
    cairo = declared_weights(pubspec, 'Cairo', ROOT)

    rep.section('التطبيق الرئيسي — أصول Cairo')
    if not rep.check(bool(cairo), 'عائلة Cairo مسجّلة في pubspec.yaml'):
        return
    infos: dict[int, dict] = {}
    for weight in sorted(cairo):
        path = cairo[weight]
        if not rep.check(os.path.exists(path), f'الأصل موجود: {os.path.relpath(path, ROOT)}'):
            continue
        info = read_ttf(path)
        infos[weight] = info
        short = os.path.basename(path)
        rep.check(info['family'] == 'Cairo', f'{short}: عائلة Cairo حقيقية (nameID 16/1 = {info["family"]})')
        rep.check(info['weight'] == weight,
                  f'{short}: usWeightClass {info["weight"]} == الوزن المُعلن {weight}')
        rep.check(not info['variable'], f'{short}: مثيل ثابت (لا fvar) — رسم متطابق بين المحركات')

    rep.section('التطبيق الرئيسي — اكتمال الأوزان')
    missing_declared = sorted(CAIRO_WEIGHTS - set(cairo))
    rep.check(not missing_declared,
              f'كل أوزان Cairo 400–900 مُعلنة (الناقص: {missing_declared or "لا شيء"})')
    used = used_weights(os.path.join(ROOT, 'lib'))
    missing_files = sorted(used - set(cairo))
    rep.check(not missing_files,
              f'كل FontWeight مستخدم في lib/ {sorted(used)} له ملف مضمّن (الناقص: {missing_files or "لا شيء"})')
    # 400 ضمني لكل TextStyle فلا يُشترط ذكره صراحة في الشيفرة.
    dead = sorted((set(cairo) - {400}) - used)
    rep.check(not dead, f'لا أوزان مضمّنة ميتة (عدا 400 الضمني): {dead or "لا شيء"}')

    if infos:
        rep.section('التطبيق الرئيسي — تجانس الخط')
        versions = {i['version'] for i in infos.values()}
        rep.check(len(versions) == 1, f'إصدار Cairo واحد لكل الأوزان: {sorted(versions)}')
        arabic = {w: i['arabic'] for w, i in sorted(infos.items())}
        rep.check(len(set(arabic.values())) == 1 and min(arabic.values()) > 200,
                  f'التغطية العربية متساوية بين الأوزان: {sorted(set(arabic.values()))} محرفاً')

    rep.section('التطبيق الرئيسي — ربط الثيم')
    with open(os.path.join(ROOT, 'lib/core/theme.dart'), encoding='utf-8') as fh:
        theme = fh.read()
    rep.check(re.search(r"uiFontFamily\s*=>\s*'Cairo'", theme) is not None,
              "uiFontFamily => 'Cairo'")
    rep.check(re.search(r'fontFamily:\s*uiFontFamily', theme) is not None,
              'ThemeData يستقبل fontFamily: uiFontFamily')
    rep.check('- family: Cairo' in pubspec, 'العائلة المطلوبة في الثيم مسجّلة في pubspec')

    rep.section('التطبيق الرئيسي — خط PDF (Tajawal)')
    tajawal = declared_weights(pubspec, 'Tajawal', ROOT)
    rep.check(bool(tajawal), f'Tajawal مسجّل: {sorted(tajawal)}')
    for name in ('Tajawal-Regular.ttf', 'Tajawal-Bold.ttf'):
        path = os.path.join(ROOT, 'assets/fonts', name)
        rep.check(os.path.exists(path),
                  f'{name} موجود (يحمّله reports_screen/voucher_doc عبر rootBundle)')


def verify_admin_app(rep: Report) -> None:
    admin = os.path.join(ROOT, 'admin_app')
    with open(os.path.join(admin, 'pubspec.yaml'), encoding='utf-8') as fh:
        pubspec = fh.read()
    cairo = declared_weights(pubspec, 'Cairo', admin)

    rep.section('لوحة المدير — أصول Cairo المشتركة')
    if not rep.check(bool(cairo), 'عائلة Cairo مسجّلة في admin_app/pubspec.yaml'):
        return
    for weight in sorted(cairo):
        path = cairo[weight]
        rep.check(os.path.exists(path),
                  f'الأصل المشترك موجود: {os.path.relpath(path, ROOT)}')

    shared = re.findall(r'-\s+asset:\s*(\S+)', pubspec)
    rep.check(all(a.startswith('../assets/fonts/') for a in shared),
              f'كل الأصول مشتركة بمسار نسبي (لا نسخ مكرّر): {len(shared)} أصول')

    used = used_weights(os.path.join(admin, 'lib'))
    missing = sorted(used - set(cairo))
    rep.check(not missing,
              f'كل FontWeight مستخدم في admin_app/lib {sorted(used)} له وزن مُعلن (الناقص: {missing or "لا شيء"})')

    rep.section('لوحة المدير — الثيم')
    with open(os.path.join(admin, 'lib/main.dart'), encoding='utf-8') as fh:
        src = fh.read()
    rep.check("fontFamily: 'Cairo'" in src, "main.dart يربط fontFamily: 'Cairo'")
    rep.check("fontFamily: 'Roboto'" not in src,
              'لا طلب لـ Roboto — بلا محارف عربية فكان يُسقط الواجهة إلى خط النظام')
    for family in set(re.findall(r"fontFamily:\s*'([^']+)'", src)):
        rep.check(f'- family: {family}' in pubspec, f'العائلة "{family}" مسجّلة في pubspec')

    rep.section('لوحة المدير — CI')
    with open(os.path.join(ROOT, '.github/workflows/build-admin-apk.yml'), encoding='utf-8') as fh:
        wf = fh.read()
    rep.check('assets/fonts/**' in wf,
              'build-admin-apk.yml يراقب assets/fonts/** (الخط مشترك بمسار نسبي)')


def main(argv: list[str]) -> int:
    quiet = '--quiet' in argv
    if not quiet:
        print('═' * 66)
        print(' فحص أصول الخطوط — سجل المبيعات والديون (بلا Flutter)')
        print('═' * 66)
    rep = Report(quiet)
    verify_main_app(rep)
    verify_admin_app(rep)
    print()
    if rep.failures:
        print(f'⛔ {len(rep.failures)} فشل من {rep.passes + len(rep.failures)} فحصاً:')
        for f in rep.failures:
            print(f'   • {f}')
        return 1
    print(f'🎉 {rep.passes} فحصاً كلها ناجحة')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
