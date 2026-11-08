#!/bin/bash
# Builds TubeStick.app (a menu bar app) into build/. Needs the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product TubeStickMenu
APP=build/TubeStick.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/TubeStickMenu" "$APP/Contents/MacOS/TubeStick"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TubeStick</string>
  <key>CFBundleDisplayName</key><string>TubeStick</string>
  <key>CFBundleIdentifier</key><string>com.fulwave.tubestick</string>
  <key>CFBundleExecutable</key><string>TubeStick</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with or endorsed by equinux.</string>
</dict></plist>
PLIST
codesign -s - -f "$APP" >/dev/null 2>&1 || true   # ad-hoc signature so macOS will run it locally
echo "Built $APP"
