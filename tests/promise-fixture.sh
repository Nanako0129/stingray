#!/bin/bash
# Calibration of shape 2 (broken_promise) against tests/promise-fixture.tsv.
#
# Sends the broken_promise question to the real endpoint with the fields the
# hook sends it — final_text, tools, background, as written in the fixture in
# the hook's format — and compares each score with
# the label at τ. It asks the question directly rather than through the hook,
# because the tool list is read from a transcript and these turns have none;
# the request body has the same shape (tests/network.sh L3 pins it).
#
# Needs a key and sends every line to TypeSafe. The lines are synthetic and
# already in this repository. Not run in CI.
#
#   ./tests/promise-fixture.sh [questions.json]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
Q="${1:-$HERE/../questions.json}"
KEY="${TYPESAFE_API_KEY:-$(cat "${HOME:-}/.config/typesafe/api_key" 2>/dev/null)}"
if [ -z "$KEY" ]; then echo "promise-fixture: skipped, needs a TypeSafe key"; exit 0; fi
ENDPOINT="${STINGRAY_ENDPOINT:-https://api.typesafe.ai/v1/systemone}"
TAU="${STINGRAY_TAU:-0.5}"

pass=0; fail=0; unscored=0; n=0
while IFS=$'\t' read -r expect origin tools bg text; do
  case "$expect" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  body=$(jq -cn --arg ft "$text" --arg tl "$tools" --arg bg "$bg" --slurpfile q "$Q" '
    {model: "jev-1.13.0",
     state: {source: "the end of one turn in a Claude Code transcript"},
     questions: ($q[0] | {broken_promise}
       | .broken_promise.instructions += {final_text: ($ft | gsub("\\\\n"; "\n")), tools: $tl, background: $bg})}')
  score=$(curl -sS --max-time 15 -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
    -d "$body" "$ENDPOINT" 2>/dev/null | jq -r '.answers.broken_promise.noul | select(type == "number")' 2>/dev/null)
  if [ -z "$score" ]; then
    unscored=$((unscored + 1)); printf 'UNSCORED  (%s) %s\n' "$origin" "$text"; continue
  fi
  got=quiet; awk -v v="$score" -v t="$TAU" 'BEGIN{exit !(v >= t)}' && got=block
  if [ "$got" = "$expect" ]; then pass=$((pass + 1)); r=ok; else fail=$((fail + 1)); r=MISS; fi
  printf '%-4s  %-5s %-5s %s  (%s) %s\n' "$r" "$expect" "$got" "$score" "$origin" "${text:0:40}"
done < "$HERE/promise-fixture.tsv"
echo "$pass agreed, $fail disagreed, $unscored unscored, of $n labelled turns"
[ "$fail" = 0 ] && [ "$unscored" = 0 ]
