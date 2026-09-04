#!/bin/bash
# Usage HUD 제거 — Claude 대화 기록이나 설정 백업은 건드리지 않습니다.
set -e
launchctl bootout "gui/$(id -u)/local.usagehud" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.usagehud.plist"
pkill -f "MacOS/UsageHUD" 2>/dev/null || true
rm -rf "$HOME/Applications/UsageHUD"
rm -f "$HOME/.local/bin/hud"
defaults delete local.usagehud 2>/dev/null || true

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "UsageHUD/statusline.py" "$SETTINGS" 2>/dev/null; then
  /usr/bin/python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
if "UsageHUD/statusline.py" in ((d.get("statusLine") or {}).get("command", "")):
    d.pop("statusLine", None)
    json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
    print("  statusLine 훅 제거됨")
PY
fi
echo "제거 완료."
