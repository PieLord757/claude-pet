#!/bin/zsh
# Builds ClaudePet.app next to this script. Needs Xcode or the Command Line Tools.
set -e
cd "${0:A:h}"
APP=ClaudePet.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS

compile() { swiftc -O -parse-as-library Sources/main.swift -o $APP/Contents/MacOS/ClaudePet "$@" 2>"${TMPDIR:-/tmp}/claudepet-build.log"; }

# The Command Line Tools sometimes ship a default SDK newer than their compiler.
# Try the default first, then fall back to each installed SDK, newest first.
if ! compile; then
  ok=0
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -t X -k2 -V -r); do
    if SDKROOT=$sdk compile; then ok=1; echo "Built with $sdk"; break; fi
  done
  if (( ! ok )); then cat "${TMPDIR:-/tmp}/claudepet-build.log"; exit 1; fi
fi

# Self-tests: session logic, the LevelDB reader and sprite sheets.
$APP/Contents/MacOS/ClaudePet --self-test

# App icon, drawn from the pet sprite by the app itself.
ICONSET="${TMPDIR:-/tmp}/ClaudePet.iconset"
rm -rf "$ICONSET"
$APP/Contents/MacOS/ClaudePet --render-icon "$ICONSET"
mkdir -p $APP/Contents/Resources
iconutil -c icns "$ICONSET" -o $APP/Contents/Resources/AppIcon.icns

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>local.claudepet</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP >/dev/null 2>&1 || true
echo "Built $PWD/$APP"
