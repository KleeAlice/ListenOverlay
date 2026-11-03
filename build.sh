#!/bin/bash
# Builds dist/听见.app with the Command Line Tools (no Xcode).
#   ./build.sh          sign with the persistent local identity (Scripts/sign_app.py), so
#                       macOS keeps 听见's recording permission across updates
#   ./build.sh --adhoc  ad-hoc signature for quick local testing
set -euo pipefail
cd "$(dirname "$0")"
SIGN=stable
[[ "${1:-}" == "--adhoc" ]] && SIGN=adhoc
require_app_stopped() {
  if pgrep -x ListenOverlay >/dev/null; then
    echo '请先退出「听见」，再构建更新；不能覆盖正在运行的应用。' >&2
    exit 1
  fi
}
require_app_stopped
mkdir -p .build dist
STAGING=$(mktemp -d .build/staged-app.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/听见.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos26.0 "${SOURCES[@]}" -o "$APP/Contents/MacOS/ListenOverlay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for file in Resources/*; do
  [[ "$file" == Resources/Info.plist ]] || cp -R "$file" "$APP/Contents/Resources/"
done
if [[ -x Helpers/NowPlaying/build.sh ]]; then Helpers/NowPlaying/build.sh "$APP/Contents/Resources/Helpers/NowPlaying"; fi
if [[ $SIGN == adhoc ]]; then
  codesign --force --deep --sign - "$APP"
else
  /usr/bin/python3 Scripts/sign_app.py "$APP"
fi
codesign --verify --deep --strict "$APP"
require_app_stopped
# Keep the previous build recoverable, but out of dist and without an .app suffix.
if [[ -d 'dist/听见.app' ]]; then
  BACKUP=$(mktemp -d .build/previous-app.XXXXXX)
  mv 'dist/听见.app' "$BACKUP/bundle"
fi
mv "$APP" 'dist/听见.app'
echo '已构建：dist/听见.app'
