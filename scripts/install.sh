#!/usr/bin/env bash
# Builds a release bundle and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release
DEST="/Applications/LinkPool.app"
if pgrep -x LinkPool >/dev/null 2>&1; then
  osascript -e 'tell application id "com.nytsai.linkpool" to quit' >/dev/null 2>&1 || true
  sleep 0.5
fi
rm -rf "$DEST"
cp -R dist/LinkPool.app "$DEST"
open "$DEST"
echo "已安装到 $DEST"
