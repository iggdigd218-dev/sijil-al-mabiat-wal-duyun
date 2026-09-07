#!/usr/bin/env bash
# تشغيل تطبيق "سجل المبيعات والديون" (nexora_app) — نسخة Linux المبنية.
set -e
cd "$(dirname "$0")"
BIN="build/linux/x64/release/bundle/nexora_app"

if [ ! -f "$BIN" ]; then
  echo "⚠️  النسخة المبنية غير موجودة. ابنيها أولاً عبر: ./build.sh"
  exit 1
fi

# إذا كان هناك شاشة عرض حقيقية شغّل مباشرة؛ وإلا استخدم شاشة افتراضية (Xvfb).
if [ -z "$DISPLAY" ]; then
  echo "لا توجد شاشة عرض — التشغيل عبر شاشة افتراضية Xvfb."
  exec xvfb-run -a "$BIN" "$@"
else
  exec "$BIN" "$@"
fi
