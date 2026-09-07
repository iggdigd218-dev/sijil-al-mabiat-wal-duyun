#!/usr/bin/env bash
# ملاحظة: أدوات البناء خارج مساحة العمل (لا تُحتسب في الحصة):
#   Flutter  -> /opt/flutter   |   pub-cache -> /opt/pub-cache   |   swap -> /swapfile
set -e
export PATH="/opt/flutter/bin:$PATH"
export PUB_CACHE="/opt/pub-cache"
cd "$(dirname "$0")"
exec flutter run -d linux "$@"
