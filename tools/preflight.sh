#!/bin/bash
# 푸시 전 안전 점검. 하나라도 걸리면 0 이 아닌 값으로 끝난다.
# 사용: ./tools/preflight.sh   (또는 git pre-push 훅으로 자동 실행)
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=1; }

SECRETS='sk-ant-[A-Za-z0-9_-]{20}|sk-[A-Za-z0-9]{32}|gh[pousr]_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[A-Za-z0-9-]{10}'
PRIVATE='jjinstalk@|jjinsword|/Users/[a-z]'

echo "== 1. 커밋될 파일 내용"
BLOBS=$(git rev-list --all --objects | awk '{print $1}' \
  | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null | awk '$2=="blob"{print $1}')
BODY=$(echo "$BLOBS" | xargs -n50 git cat-file --batch 2>/dev/null)
[ "$(echo "$BODY" | grep -cE "$SECRETS")" = 0 ] && ok "자격증명·토큰 패턴 없음" || bad "자격증명 패턴 발견"
[ "$(echo "$BODY" | grep -cE "$PRIVATE")" = 0 ] && ok "개인 이메일·계정·절대경로 없음" || bad "개인정보 발견"

echo "== 2. 커밋 메타데이터"
# 허용: 개인 noreply(...@users.noreply.github.com) 와 GitHub 웹 커밋의 커미터(noreply@github.com)
REAL=$(git log --all --pretty=format:'%ae%n%ce' \
  | grep -vE 'users\.noreply\.github\.com$|^noreply@github\.com$' | sort -u)
[ -z "$REAL" ] && ok "모든 커밋이 noreply 주소" \
  || { bad "실제 이메일이 커밋에 남아 있음:"; echo "$REAL" | sed 's/^/      /'; }
[ "$(git log --all --pretty=format:'%s%n%b' | grep -cE "$SECRETS|$PRIVATE")" = 0 ] \
  && ok "커밋 메시지 깨끗" || bad "커밋 메시지에 민감 정보"

echo "== 3. 코드 동작"
SCAN="src bin build.sh install.sh uninstall.sh tools/make-icon.swift"
NET=$(grep -rniE "URLSession|URLRequest|dataTask|NWConnection|urllib|requests\.|curl |wget " $SCAN 2>/dev/null | grep -v DOCTYPE | wc -l | tr -d ' ')
[ "$NET" = 0 ] && ok "외부 통신 코드 없음" || bad "네트워크 호출 발견 ($NET 건)"
CRED=$(grep -rniE "keychain|security find|\.credentials|auth\.json|access_?token|refresh_?token" $SCAN 2>/dev/null | wc -l | tr -d ' ')
[ "$CRED" = 0 ] && ok "자격증명 접근 없음" || bad "자격증명 접근 발견 ($CRED 건)"

echo "== 4. 프로세스 종료 가드"
UNGUARDED=0
grep -n "kill(s.pid, SIGTERM)" src/UsageHUD.swift >/dev/null && \
  { grep -B20 "kill(s.pid, SIGTERM)" src/UsageHUD.swift | grep -q "s.killable" || UNGUARDED=1; }
grep -q 's.get("killable")' bin/hud || UNGUARDED=1
grep -q '\$0.killable' src/UsageHUD.swift || UNGUARDED=1
[ "$UNGUARDED" = 0 ] && ok "모든 종료 경로에 프로세스 검증" || bad "검증 없는 종료 경로 존재"

echo "== 5. 추적 파일"
UNEXPECTED=$(git ls-files | grep -vE '^(\.gitignore|\.githooks/.*|LICENSE|README\.md|config\.example\.json|install\.sh|uninstall\.sh|build\.sh|assets/AppIcon\.icns|bin/hud|src/.*|tools/.*)$' | wc -l | tr -d ' ')
[ "$UNEXPECTED" = 0 ] && ok "예상 밖 파일 없음" || { bad "예상 밖 파일:"; git ls-files | grep -vE '^(\.gitignore|\.githooks/.*|LICENSE|README\.md|config\.example\.json|install\.sh|uninstall\.sh|build\.sh|assets/AppIcon\.icns|bin/hud|src/.*|tools/.*)$' | sed 's/^/      /'; }
[ "$(git ls-files | grep -cE '\.(ceiling|toolstats|ratelimits|diskscan)\.json|UsageHUD\.app/')" = 0 ] \
  && ok "캐시·빌드 산출물 미포함" || bad "캐시 파일이 추적되고 있음"

echo
[ "$FAIL" = 0 ] && echo "모든 점검 통과 — 푸시해도 안전합니다." || echo "점검 실패 — 위 항목을 먼저 해결하세요."
exit $FAIL
