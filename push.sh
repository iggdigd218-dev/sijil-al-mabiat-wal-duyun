#!/usr/bin/env bash
# رفع كل التعديلات للمستودع البعيد (GitHub main) — يحمي الكود من أي ضياع.
# الاستخدام: ./push.sh "رسالة الـ commit (اختياري)"
set -e
cd "$(dirname "$0")"

MSG="${1:-تحديث: $(date +'%Y-%m-%d %H:%M')}"

git add -A
if git diff --cached --quiet; then
  echo "لا توجد تعديلات لرفعها."
  exit 0
fi

git commit -q -m "$MSG"
git push origin main
echo "✅ تم الرفع على main — سيبدأ بناء APK الجديد تلقائيًا."
echo "   لمتابعة البناء: https://github.com/iggdigd218-dev/sijil-al-mabiat-wal-duyun/actions"
