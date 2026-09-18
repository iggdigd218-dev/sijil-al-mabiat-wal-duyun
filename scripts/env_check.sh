#!/usr/bin/env bash
# تشخيص جاهزية البيئة قبل محاولة أي بناء أو تشغيل أو معاينة ويب.
#
# وُجد هذا السكريبت بعد محاولة تشغيل معاينة ويب في بيئة حاويات محجوبة
# الشبكة: النتيجة كانت سلسلة إخفاقات غامضة بدل سبب واحد واضح. يفحص
# بالترتيب: SDK ← الشبكة ← الحصة ← قابلية الويب ← أصول الخطوط.
#
# الاستخدام:  bash scripts/env_check.sh
#   --json    إخراج آلي مختصر (للسكربتات / CI)
set -uo pipefail

cd "$(dirname "$0")/.."
JSON=0; [ "${1:-}" = "--json" ] && JSON=1
FAIL=0
ok(){ [ "$JSON" = 1 ] || printf "  ✅ %s\n" "$1"; }
warn(){ [ "$JSON" = 1 ] || printf "  ⚠️  %s\n" "$1"; }
bad(){ [ "$JSON" = 1 ] || printf "  ⛔ %s\n" "$1"; FAIL=$((FAIL+1)); }

probe(){ # probe <url> -> رمز HTTP أو 000
  # curl -w '%{http_code}' يطبع 000 عند الفشل **وينجح** (رمز خروج 0)،
  # فـ `|| echo 000` كان يلصق صفراً ثانياً («000000») ويُنطق حجباً نجاحاً.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${PROBE_TIMEOUT:-12}" "$1" 2>/dev/null) || code=""
  case "$code" in
    ''|*[!0-9]*) echo 000 ;;
    *) echo "$code" ;;
  esac
}

echo "══ 1) Flutter SDK ══"
FLUTTER_BIN=""
for c in /opt/flutter/bin/flutter "$HOME/flutter/bin/flutter" "$(command -v flutter 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { FLUTTER_BIN="$c"; break; }
done
if [ -n "$FLUTTER_BIN" ]; then
  ok "Flutter موجود: $FLUTTER_BIN"
  [ "$JSON" = 1 ] || "$FLUTTER_BIN" --version 2>/dev/null | head -3 | sed 's/^/     /'
else
  bad "لا يوجد Flutter SDK (فُحص /opt/flutter و ~/flutter و PATH)"
  echo "     التثبيت يحتاج storage.googleapis.com — انظر الفحص (2)."
fi

echo
echo "══ 2) الشبكة (شرط تنزيل SDK و pub get) ══"
declare -A HOSTS=(
  ["storage.googleapis.com"]="محرك Flutter + Dart SDK (إلزامي للتثبيت)"
  ["pub.dev"]="فهرس الحزم (إلزامي لـ flutter pub get)"
  ["github.com"]="المستودع + إصدارات التحديث"
)
BLOCKED_CRITICAL=0
for h in storage.googleapis.com pub.dev github.com; do
  code=$(probe "https://$h")
  if [ "$code" = "000" ]; then
    if [ "$h" = "github.com" ]; then warn "$h محجوب — ${HOSTS[$h]}"; else bad "$h محجوب — ${HOSTS[$h]}"; BLOCKED_CRITICAL=1; fi
  else
    ok "$h ($code) — ${HOSTS[$h]}"
  fi
done
if [ "$BLOCKED_CRITICAL" = 1 ]; then
  echo
  echo "     ⮡ النتيجة: لا يمكن تثبيت Flutter ولا تنفيذ pub get في هذه البيئة."
  echo "       البديل المتاح: فحص الأصول/القواعد بسكريبتات بايثون (verify_fonts.py)"
  echo "       والاعتماد على CI في GitHub Actions للتحليل والاختبارات والبناء."
fi

echo
echo "══ 3) حصة مساحة العمل (128 MB / 10,000 ملف) ══"
SIZE_KB=$(du -sk --exclude=.git . | cut -f1)
FILES=$(find . -path ./.git -prune -o -type f -print | wc -l)
printf "   الحجم: %s MB   الملفات: %s\n" "$((SIZE_KB/1024))" "$FILES"
if [ "$SIZE_KB" -gt 110000 ] || [ "$FILES" -gt 9000 ]; then
  bad "قريب من السقف — شغّل scripts/clean_flutter_env.sh"
else
  ok "ضمن السقف بهامش آمن"
fi
for d in build .dart_tool admin_app/build; do
  [ -e "$d" ] && warn "مخلفات بناء موجودة: $d ($(du -sh "$d" | cut -f1))"
done

echo
echo "══ 4) قابلية منصة الويب (معاينة المتصفح) ══"
WEB_OK=1
[ -d web ] || { bad "لا يوجد مجلد web/ — مشروع سطح مكتب/موبايل فقط"; WEB_OK=0; }
IO_COUNT=$(grep -rl "import 'dart:io'" lib 2>/dev/null | wc -l)
if [ "$IO_COUNT" -gt 0 ]; then
  bad "$IO_COUNT ملفاً في lib/ يستورد dart:io — لا يُصرَّف للويب إطلاقاً"
  WEB_OK=0
fi
if grep -q "sqflite_common_ffi" pubspec.yaml; then
  bad "sqflite_common_ffi (FFI) — غير مدعوم على الويب؛ قاعدة البيانات تحتاج sqflite_web/IDB"
  WEB_OK=0
fi
[ "$WEB_OK" = 1 ] && ok "الويب قابل للتصريف" || {
  echo
  echo "     ⮡ النتيجة: flutter run -d web-server سيفشل في مرحلة التصريف،"
  echo "       لا في مرحلة التشغيل. دعم الويب يحتاج عملاً معمارياً (طبقة"
  echo "       تخزين بديلة + عزل dart:io خلف واجهات) وليس ضبط أعلامات."
  echo "       انظر docs/معاينة-الواجهات-بلا-flutter.md للبديل المتاح."
}

echo
echo "══ 5) أصول خط Cairo ══"
if command -v python3 >/dev/null 2>&1; then
  python3 scripts/verify_fonts.py --quiet && ok "أصول الخطوط سليمة" || bad "فشل فحص الخطوط (التفاصيل أعلاه)"
else
  warn "python3 غير متوفر — تعذّر فحص أصول الخطوط"
fi

echo
if [ "$FAIL" = 0 ]; then echo "🎉 البيئة جاهزة"; else echo "⛔ $FAIL مانعاً — راجع البنود أعلاه"; fi
exit "$FAIL"
