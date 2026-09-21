#!/bin/bash
# Run the WATCH_RE fixture against a candidate regex.
#
#   ./stingray-watch-fixture-run.sh                 # the shipping WATCH_RE
#   ./stingray-watch-fixture-run.sh --target 12     # bare keyword + target within N chars
#   ./stingray-watch-fixture-run.sh --regex '...'   # anything else
#
# The regex is read out of hooks/stingray.sh rather than copied here. A fixture
# carrying its own copy of the thing it tests is how a mutation walks past a
# green run -- this repository has been bitten by that shape before.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${STINGRAY_HOOK:-$HERE/../hooks/stingray.sh}"
FIXTURE="${1:-}"; case "$FIXTURE" in --*|"") FIXTURE="$HERE/watch-fixture.tsv" ;; *) shift ;; esac

BARE='監看|監控|盯著|盯住|輪詢|持續追蹤|poll(ing)?'
TARGET='CI|ci|review|Review|審查|PR|CodeRabbit|Copilot|Codex|build|建置|部署|deploy|workflow|job|pipeline'

RE=""
case "${1:-}" in
  --regex)  RE="$2" ;;
  --target) RE="(${BARE})[^。]{0,$2}(${TARGET})|等(著|待|到)? ?(CI|ci|review|Review|審查|CodeRabbit|Copilot|Codex)[^。]{0,12}(回來|回覆|完成|跑完|出來|結果|綠)|keep (an eye on|watching|polling)|I.?ll (monitor|watch|poll)" ;;
  *)        # WATCH_RE is assembled from WATCH_TARGET and WATCH_VERB in the hook,
            # so take those three assignments and evaluate them here rather than
            # keeping a second copy. Only lines matching the three names are read.
            defs=$(grep -E "^WATCH_(TARGET|VERB|RE)=" "$HOOK")
            [ "$(printf '%s\n' "$defs" | grep -c .)" = 3 ] || {
              echo "expected 3 WATCH_* assignments in $HOOK, found:" >&2
              printf '%s\n' "$defs" >&2; exit 2; }
            eval "$defs"
            RE="$WATCH_RE"
            [ -n "$RE" ] || { echo "WATCH_RE evaluated empty" >&2; exit 2; } ;;
esac

pass=0; fail=0; short_missed=0
while IFS=$'\t' read -r expect origin text; do
  case "$expect" in ''|'#'*) continue ;; esac
  if printf '%s' "$text" | grep -qE "$RE"; then got=watch; else got=quiet; fi
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
  elif [ "$origin" = "short" ]; then
    # Expected cost of the target-keyword shape, reported but not failed.
    short_missed=$((short_missed + 1))
    printf 'COST  %s\n      %s\n' "$origin" "$text"
  else
    fail=$((fail + 1))
    printf 'FAIL  expected=%s got=%s  (%s)\n      %s\n' "$expect" "$got" "$origin" "$text"
  fi
done < "$FIXTURE"

echo "$pass passed, $fail failed, $short_missed short-form promises dropped"
[ "$fail" -eq 0 ]
