#!/bin/bash
# Live calibration of shape 3 against the labelled lines in watch-fixture.tsv.
#
# Each line goes through the shipped hook as the final message of a turn with
# nothing running, STINGRAY_SHAPE3=1, against the real endpoint — so what is
# measured is the whole shipping path, redaction included, not the question on
# its own. A line labelled `watch` must be blocked and a line labelled `quiet`
# must not.
#
# Needs a key and sends every line to TypeSafe. The lines are the ones already
# in this repository, so nothing leaves that is not public. Not run in CI.
#
#   ./tests/watch-fixture.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/stingray.sh"
. "$HERE/hook-shell.sh"
KEY="${TYPESAFE_API_KEY:-$(cat "${HOME:-}/.config/typesafe/api_key" 2>/dev/null)}"
if [ -z "$KEY" ]; then echo "watch-fixture: skipped, needs a TypeSafe key"; exit 0; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; unscored=0; n=0
while IFS=$'\t' read -r expect origin text; do
  case "$expect" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  rc=0
  jq -cn --arg m "$text" --arg s "fixture-$n" '{session_id:$s, prompt_id:"p",
      transcript_path:"/nonexistent/t.jsonl", cwd:"/tmp", permission_mode:"default",
      hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:($m | gsub("\\\\n"; "\n")),
      background_tasks:[], session_crons:[]}' \
    | env -i PATH="$PATH" HOME="${HOME:-}" TYPESAFE_API_KEY="$KEY" STINGRAY_SHAPE3=1 \
        STINGRAY_STATE_DIR="$TMP/st" "$HOOK_SH" "$HOOK" >/dev/null 2>&1 || rc=$?
  got=quiet; [ "$rc" = 2 ] && got=watch
  # The hook fails open: a timeout or a broken answer exits 0 just as a quiet
  # verdict does. Count a line only when Jev scored it, or every quiet line
  # would agree with a measurement that never happened.
  score=$(jq -r --arg s "fixture-$n" 'select(.session == $s and (.shape == "watch_none" or .shape == "unwatched")) | .score' \
    "$TMP/st/decisions.jsonl" 2>/dev/null | head -1)
  if [ -z "$score" ]; then
    unscored=$((unscored + 1))
    printf 'UNSCORED  exit=%s (%s)\n      %s\n' "$rc" "$origin" "$text"
  elif [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'MISS  expected=%s got=%s score=%s (%s)\n      %s\n' "$expect" "$got" "$score" "$origin" "$text"
  fi
done < "${1:-$HERE/watch-fixture.tsv}"
echo "$pass agreed, $fail disagreed, $unscored unscored, of $n labelled lines"
[ "$fail" = 0 ] && [ "$unscored" = 0 ]
