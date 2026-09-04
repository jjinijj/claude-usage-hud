#!/bin/bash
# Usage HUD 설치 — 소스에서 직접 빌드하므로 코드 서명 문제가 없습니다.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Applications/UsageHUD"
BIN="$HOME/.local/bin"
APP="$DEST/UsageHUD.app"
AGENT="$HOME/Library/LaunchAgents/local.usagehud.plist"

command -v swiftc >/dev/null || {
  echo "swiftc 가 없습니다. Xcode Command Line Tools 를 먼저 설치하세요:"
  echo "  xcode-select --install"; exit 1; }

echo "==> 파일 설치: $DEST"
mkdir -p "$DEST" "$BIN"
cp "$REPO/src/stats.py" "$REPO/src/statusline.py" "$REPO/src/UsageHUD.swift" "$DEST/"
[ -f "$DEST/config.json" ] || cp "$REPO/config.example.json" "$DEST/config.json"
cp "$REPO/bin/hud" "$BIN/hud"; chmod +x "$BIN/hud"

echo "==> 빌드"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/UsageHUD" "$DEST/UsageHUD.swift" -framework AppKit
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

echo "==> 로그인 시 자동 실행 등록"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.usagehud</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/UsageHUD</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/local.usagehud" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || true

# statusLine 훅은 Claude 의 실제 사용 한도를 받아오는 유일한 통로지만,
# 이미 쓰고 있는 설정이 있으면 절대 덮어쓰지 않는다.
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  EXISTING=$(/usr/bin/python3 -c "import json;print((json.load(open('$SETTINGS')).get('statusLine') or {}).get('command',''))" 2>/dev/null || echo "")
  if [ -z "$EXISTING" ]; then
    echo "==> Claude Code statusLine 훅 등록 (실측 사용량 수신용)"
    cp "$SETTINGS" "$SETTINGS.pre-usagehud"
    /usr/bin/python3 - "$SETTINGS" "$DEST" <<'PY'
import json, sys
p, dest = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["statusLine"] = {"type": "command",
                   "command": "/usr/bin/python3 %s/statusline.py" % dest,
                   "padding": 0}
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
PY
    echo "    백업: $SETTINGS.pre-usagehud"
  elif [ "${EXISTING#*UsageHUD/statusline.py}" != "$EXISTING" ]; then
    echo "==> statusLine 훅 이미 등록됨"
  else
    echo "==> statusLine 이 이미 설정되어 있어 건너뜁니다:"
    echo "    현재: $EXISTING"
    echo "    실측 사용량을 쓰려면 기존 스크립트에서 아래를 호출하세요:"
    echo "      /usr/bin/python3 $DEST/statusline.py"
    echo "    (등록하지 않아도 HUD 는 추정치로 동작합니다)"
  fi
fi

pkill -f "MacOS/UsageHUD" 2>/dev/null || true
sleep 0.5
open "$APP"
echo
echo "설치 완료. HUD 가 화면 우측 상단에 떠 있습니다."
echo "  hud            창 띄우기 / 상태 확인"
echo "  hud now        터미널에 현재 수치 출력"
echo "  hud sessions   Claude 세션 목록"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "  ※ PATH 에 $BIN 을 추가해야 hud 명령을 쓸 수 있습니다:"
     echo "     echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
