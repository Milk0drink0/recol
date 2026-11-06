#!/bin/zsh
# Builds build/Recol.app from mac/ (native shell) and recol/index.html (the UI).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Recol.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

echo "→ compiling"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  -framework Cocoa -framework WebKit \
  mac/main.swift -o "$APP/Contents/MacOS/Recol"

cp mac/Info.plist "$APP/Contents/Info.plist"
cp recol/index.html "$APP/Contents/Resources/web/index.html"
cp -R recol/plugins "$APP/Contents/Resources/web/plugins"          # example plugins (seeded into the user's plugins folder)
cp ai/recol-mcp.py "$APP/Contents/Resources/recol-mcp.py"            # MCP server for AI apps
mkdir -p "$APP/Contents/Resources/docs" && cp AI.md PLUGINS.md "$APP/Contents/Resources/docs/"

if [[ ! -f build/AppIcon.icns || mac/make-icon.swift -nt build/AppIcon.icns ]]; then
  echo "→ drawing icon"
  swift mac/make-icon.swift build/icon-1024.png
  ICONSET=build/AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity if you've made one (see README), so macOS keeps Recol's
# Accessibility permission across rebuilds. Otherwise fall back to an ad-hoc signature.
IDENTITY="${RECOL_SIGN_IDENTITY:-Recol Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" --identifier app.recol.Recol "$APP" >/dev/null 2>&1 && echo "→ signed as \"$IDENTITY\" (permissions persist)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "→ ad-hoc signed (Accessibility resets on every rebuild — see README)"
fi
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true   # refresh the Services menu
echo "✓ built $APP"
