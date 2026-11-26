#!/usr/bin/env bash
# Builds a self-contained LinkPool.app in dist/. No external dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clangcache"

swift build -c "$CONFIG" --disable-sandbox

APP="dist/LinkPool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/LinkPool" "$APP/Contents/MacOS/LinkPool"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/LinkPool"

# Ad-hoc signature keeps Gatekeeper quiet for a locally built app.
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成 $APP"
