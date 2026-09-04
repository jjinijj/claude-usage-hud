#!/bin/bash
# 설치된 소스에서 앱을 다시 빌드한다 (hud rebuild 가 호출).
set -e
DIR="$HOME/Applications/UsageHUD"
APP="$DIR/UsageHUD.app"
command -v swiftc >/dev/null || { echo "swiftc 없음. xcode-select --install"; exit 1; }
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/UsageHUD" "$DIR/UsageHUD.swift" -framework AppKit
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>UsageHUD</string>
  <key>CFBundleDisplayName</key><string>Usage HUD</string>
  <key>CFBundleIdentifier</key><string>local.usagehud</string>
  <key>CFBundleExecutable</key><string>UsageHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force -s - "$APP" 2>/dev/null || true
echo "built: $APP"
