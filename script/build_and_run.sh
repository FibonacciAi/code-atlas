#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
APP_BUNDLE="$ROOT_DIR/dist/Code Atlas.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/CodeAtlas"
# Do not terminate running processes; let the user keep existing windows.
swift build -c release
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
RESOURCE_BUNDLE="$(swift build -c release --show-bin-path)/CodeAtlas_CodeAtlas.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  /usr/bin/ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/CodeAtlas_CodeAtlas.bundle"
fi
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/CodeAtlas" "$APP_BINARY.next"
mv "$APP_BINARY.next" "$APP_BINARY"
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo uncommitted)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodeAtlas</string>
<key>CFBundleIdentifier</key><string>local.codeatlas.explorer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Code Atlas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>AtlasBuildTime</key><string>$BUILD_TIME</string>
<key>AtlasRevision</key><string>$REVISION</string>
<key>AtlasChannel</key><string>local-development</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  --demo) /usr/bin/open -n "$APP_BUNDLE" --args --demo ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x CodeAtlas ;;
  --debug) lldb -- "$APP_BINARY" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "CodeAtlas"' ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  *) echo "usage: $0 [--build-only|--demo|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
