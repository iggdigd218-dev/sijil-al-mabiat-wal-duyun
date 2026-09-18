#!/usr/bin/env bash
# تنظيف مخلفات البناء والأصول المولّدة — يستعيد حصة مساحة العمل
# (سقف البيئة 128 MB / 10,000 ملف) دون المساس بأي ملف متتبَّع في git.
#
# الاستخدام:  bash scripts/clean_flutter_env.sh [--dry-run]
set -euo pipefail

cd "$(dirname "$0")/.."          # جذر المستودع
ROOT="$PWD"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# ما يُحذف: مخرجات بناء وأدوات مولّدة فقط — لا مصادر ولا أصول.
TARGETS=(
  "build"
  ".dart_tool"
  ".flutter-plugins"
  ".flutter-plugins-dependencies"
  "admin_app/build"
  "admin_app/.dart_tool"
  "admin_app/.flutter-plugins"
  "admin_app/.flutter-plugins-dependencies"
  "windows/flutter/ephemeral"
  "linux/flutter/ephemeral"
  "macos/Flutter/ephemeral"
)
# ملاحظة: qa/preview **لا يُحذف** — index.html فيه متتبَّع في git (عارض
# noVNC الذي يستخدمه qa/prepare_preview.sh). ما يُولَّد داخله لاحقاً هو
# الرابطان الرمزيان core وvendor، فيُنظَّفان انتقائياً أدناه.
SYMLINK_TARGETS=(
  "qa/preview/core"
  "qa/preview/vendor"
)

size_of() { du -sh "$1" 2>/dev/null | cut -f1; }
count_of() { find "$1" -type f 2>/dev/null | wc -l; }

echo "🧹 تنظيف بيئة العمل: $ROOT"
[ "$DRY" = 1 ] && echo "   (وضع المعاينة — لن يُحذف شيء)"
echo

freed=0; removed_files=0
for t in "${TARGETS[@]}"; do
  [ -e "$t" ] || continue
  s=$(size_of "$t"); n=$(count_of "$t")
  if [ "$DRY" = 1 ]; then
    echo "   سيُحذف  $t  ($s / $n ملف)"
  else
    rm -rf "$t"
    echo "   حُذف    $t  ($s / $n ملف)"
  fi
  removed_files=$((removed_files + n)); freed=1
done

# روابط رمزية مولّدة داخل مجلد متتبَّع — تُفكّ دون حذف ما حولها.
for l in "${SYMLINK_TARGETS[@]}"; do
  [ -L "$l" ] || continue
  if [ "$DRY" = 1 ]; then
    echo "   سيُفك   $l  (رابط رمزي مولّد)"
  else
    rm -f "$l"
    echo "   فُكّ    $l  (رابط رمزي مولّد)"
  fi
  freed=1
done

[ "$freed" = 0 ] && echo "   لا مخلفات بناء — البيئة نظيفة أصلاً."
echo

# ── تقرير الحصة بعد التنظيف ──
echo "── الحصة الحالية ──"
printf "   المستودع (بدون .git): %s\n" "$(du -sh --exclude=.git . | cut -f1)"
printf "   عدد الملفات (بدون .git): %s\n" "$(find . -path ./.git -prune -o -type f -print | wc -l)"
printf "   السقف: 128 MB / 10,000 ملف\n"

# ── حارس: أي ملف متتبَّع في git يجب ألا يكون قد أُتلف ──
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo
  deleted_tracked=$(git ls-files --deleted | wc -l)
  if [ "$deleted_tracked" != 0 ]; then
    echo "⛔ تحذير: $deleted_tracked ملفاً متتبَّعاً في git صار مفقوداً:"
    git ls-files --deleted | sed 's/^/      /'
    echo "   استرجعها بـ: git checkout -- <المسار>"
    exit 1
  fi
  echo "✅ لم يُحذف أي ملف متتبَّع في git."
fi
