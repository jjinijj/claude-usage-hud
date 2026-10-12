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
NETPAT="URLSession|URLRequest|dataTask|NWConnection|urllib|requests\.|curl |wget "
CREDPAT="keychain|security find|\.credentials|auth\.json|access_?token|refresh_?token"

# 서버에 사용률을 묻는 기능(옵트인) 때문에 stats.py 의 OAUTH 구간에서만
# 통신·자격증명 접근을 허용한다. 그 바깥에 생기면 잡아낸다.
OUT=$(grep -rniE "$NETPAT|$CREDPAT" $SCAN 2>/dev/null | grep -v DOCTYPE | grep -v "^src/stats.py:" | wc -l | tr -d ' ')
[ "$OUT" = 0 ] && ok "OAUTH 구간 밖에는 통신·자격증명 접근 없음" \
                || { bad "허용 구간 밖에서 발견 ($OUT 건):"; \
                     grep -rniE "$NETPAT|$CREDPAT" $SCAN 2>/dev/null | grep -v DOCTYPE | grep -v "^src/stats.py:" | sed 's/^/      /'; }

B=$(grep -n "OAUTH-BEGIN" src/stats.py | cut -d: -f1)
E=$(grep -n "OAUTH-END"   src/stats.py | cut -d: -f1)
if [ -z "$B" ] || [ -z "$E" ]; then
  bad "stats.py 에 OAUTH-BEGIN/END 표식이 없습니다"
else
  STRAY=$(grep -nE "$NETPAT|$CREDPAT" src/stats.py | cut -d: -f1 \
          | awk -v b="$B" -v e="$E" '$1<b || $1>e' | wc -l | tr -d ' ')
  [ "$STRAY" = 0 ] && ok "stats.py 의 통신·자격증명 접근이 OAUTH 구간 안에만 있음 ($B~$E 행)" \
                   || { bad "OAUTH 구간 밖에 흩어진 호출 ($STRAY 건):"; \
                        grep -nE "$NETPAT|$CREDPAT" src/stats.py \
                        | awk -F: -v b="$B" -v e="$E" '$1<b || $1>e' | sed 's/^/      /'; }
fi

# 토큰이 디스크·로그로 새지 않는지. 쓰기 호출과 토큰 변수가 같은 줄에 있으면 의심.
LEAK=$(grep -nE "(open\(|write\(|json\.dump|print\(|stderr)" src/stats.py \
       | grep -E "\btok\b|accessToken|refreshToken" | grep -v "_scrub" | wc -l | tr -d ' ')
[ "$LEAK" = 0 ] && ok "토큰을 파일·로그로 내보내는 코드 없음" \
                || { bad "토큰 유출 의심 ($LEAK 건):"; \
                     grep -nE "(open\(|write\(|json\.dump|print\(|stderr)" src/stats.py \
                     | grep -E "\btok\b|accessToken|refreshToken" | grep -v "_scrub" | sed 's/^/      /'; }

# 예외 메시지에 토큰이 섞일 수 있다. OAUTH 구간에서 stderr/print 로 나가는 줄은
# 반드시 _scrub( 을 거쳐야 한다. 이름만 비슷한 함수로는 통과하지 못하게 호출형으로 본다.
if [ -n "$B" ] && [ -n "$E" ]; then
  RAW=$(sed -n "${B},${E}p" src/stats.py | grep -nE "stderr|print\(" | grep -v "_scrub(" | wc -l | tr -d ' ')
  [ "$RAW" = 0 ] && ok "OAUTH 구간의 출력이 모두 _scrub() 를 거침" \
                 || { bad "토큰이 섞일 수 있는 출력 ($RAW 건):"; \
                      sed -n "${B},${E}p" src/stats.py | grep -nE "stderr|print\(" | grep -v "_scrub(" | sed 's/^/      /'; }
  grep -qE "^def _scrub\(" src/stats.py && ok "_scrub 정의 있음" || bad "_scrub 정의가 사라졌습니다"
fi

echo "== 4. 프로세스 종료 가드"
UNGUARDED=0
grep -n "kill(s.pid, SIGTERM)" src/UsageHUD.swift >/dev/null && \
  { grep -B20 "kill(s.pid, SIGTERM)" src/UsageHUD.swift | grep -q "s.killable" || UNGUARDED=1; }
grep -q 's.get("killable")' bin/hud || UNGUARDED=1
grep -q '\$0.killable' src/UsageHUD.swift || UNGUARDED=1
[ "$UNGUARDED" = 0 ] && ok "모든 종료 경로에 프로세스 검증" || bad "검증 없는 종료 경로 존재"

echo "== 5. 추적 파일"
# 저장소에 있어야 할 파일 목록. 두 군데서 쓰므로 한 곳에만 둔다.
ALLOWED='^(\.gitignore|\.githooks/.*|LICENSE|README\.md|config\.example\.json|install\.sh|uninstall\.sh|build\.sh|assets/(AppIcon\.icns|(char-[a-z]|mascot)\.png|src/char-[a-z]\.webp)|bin/hud|src/.*|tools/.*)$'
UNEXPECTED=$(git ls-files | grep -vE "$ALLOWED" | wc -l | tr -d ' ')
[ "$UNEXPECTED" = 0 ] && ok "예상 밖 파일 없음" || { bad "예상 밖 파일:"; git ls-files | grep -vE "$ALLOWED" | sed 's/^/      /'; }
[ "$(git ls-files | grep -cE '\.(ceiling|toolstats|ratelimits|diskscan|oauthusage)\.json|UsageHUD\.app/')" = 0 ] \
  && ok "캐시·빌드 산출물 미포함" || bad "캐시 파일이 추적되고 있음"

echo
[ "$FAIL" = 0 ] && echo "모든 점검 통과 — 푸시해도 안전합니다." || echo "점검 실패 — 위 항목을 먼저 해결하세요."
exit $FAIL
