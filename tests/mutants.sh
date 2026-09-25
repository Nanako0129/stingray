#!/bin/bash
# Do the guards still guard?
#
# Some acceptance cases exist to catch one specific implementation mistake each.
# A test that cannot fail is worse than no test: it reports a guarantee nobody
# holds. So each mistake is re-introduced into a copy of the hook, and the case
# that exists to catch it must fail.
#
# This is not hypothetical. Case 7's first version used a URL in the
# declaration line and was worthless — URLs are replaced in place, the line
# survives, and the broken implementation passed. It only came out because
# someone built the mutant.
#
#   ./tests/mutants.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# Break the hook on purpose, then require the case that exists to catch that
# break to fail. mutate <name> <case-label> <anchor> <replacement> [file under
# hooks/, default stingray.sh]: the anchor
# must still be present in the hook, so a refactor that moves the code under
# test fails loudly here instead of quietly disarming the mutant.
mutate() {
  local name="$1" want_case="$2" anchor="$3" replacement="$4" file="${5:-stingray.sh}"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cp -R "$ROOT/hooks" "$ROOT/tests" "$ROOT/questions.json" "$dir/"

  ANCHOR="$anchor" REPLACEMENT="$replacement" python3 - "$dir/hooks/$file" <<'PY'
import os, pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor, replacement = os.environ["ANCHOR"], os.environ["REPLACEMENT"]
if anchor not in text:
    sys.exit(f"mutant anchor not found, the hook changed shape: {anchor!r}")
path.write_text(text.replace(anchor, replacement, 1))
PY
  [ $? -eq 0 ] || { fail=$((fail+1)); printf '  FAIL  %s — could not build mutant\n' "$name"; return; }

  local out="$TMP/$name.out"
  bash "$dir/tests/acceptance.sh" >"$out" 2>&1
  if grep -qE "^  FAIL  $want_case" "$out"; then
    pass=$((pass+1)); printf '  ok    %-22s case %s fails, as it must\n' "$name" "$want_case"
  else
    fail=$((fail+1))
    printf '  FAIL  %-22s case %s still passed against a broken hook\n' "$name" "$want_case"
    printf '        (that case cannot catch the mistake it exists for)\n'
  fi
}

echo "stingray mutation checks"

# Mutant 1 — the background count ignored. Every promise judged made would then
# block as if nothing were running, including one kept by a running poll. Case 8
# has a poll running and a stub that judges the promise made, so it fails.
mutate "running-ignored" "8 " \
  'elif [ "$running" = "0" ]; then' \
  'elif true; then'

# Mutant 2 — a missing background_tasks key read as "nothing is running". That
# turns shape 3 into "block whenever a promise is judged"; case 9 is the only
# thing standing between that and a wrong block on ordinary turns.
mutate "absent-key-is-empty" "9 " \
  '[ "$(printf '"'"'%s'"'"' "$input" | jq '"'"'(.background_tasks | type) == "array"'"'"' 2>/dev/null)" = "true" ]' \
  'true'

# Mutant 3 — background_tasks: null read as "nothing is running". has() is true
# for null and [ .[]? ] over null counts zero, so reverting the type check to a
# presence check reopens the same hole through a different door.
mutate "null-is-empty-array" "16" \
  "[ \"\$(printf '%s' \"\$input\" | jq '(.background_tasks | type) == \"array\"' 2>/dev/null)\" = \"true\" ]" \
  "[ \"\$(printf '%s' \"\$input\" | jq 'has(\"background_tasks\")' 2>/dev/null)\" = \"true\" ]"

# Mutant 4 — selective mode sends with nothing to ask. With the background list
# unreadable shape 3 has no count to act on, and the exit before the request
# path is what keeps a key on disk from sending the message anyway. An earlier
# form of this exit is the regression that shipped once: a switch that promised
# no request while a key made one.
mutate "selective-sends-anyway" "15.1" \
  '[ "$MODE" = "selective" ] && [ "$lang_ask" != "1" ] && [ "$shape3_ask" != "1" ] && exit 0' \
  ':'

# Mutants 5–7 — the cross-session handoff. Ignoring handoffs brings back the
# block on a turn that handed its work to another session (8.1); ignoring the
# answer keeps a finished handoff counted as running forever (8.2); counting a
# message to an in-process subagent turns every subagent nudge into cover for
# an empty promise (8.3).
mutate "handoffs-ignored" "8.1" \
  '[ -n "$handoffs" ] && running=$((running + $(printf '"'"'%s\n'"'"' "$handoffs" | grep -c .)))' \
  ':'
mutate "answer-ignored" "8.2" \
  '| select([ $incoming[]' \
  '| select([ $incoming[] | select(false)' \
  handoffs.jq
mutate "subagent-counted" "8.3" \
  '| select($cross | index($snd.id))' \
  '' \
  handoffs.jq
mutate "quote-is-answer" "8.4" \
  'capture("^(?:Another' \
  'capture("(?:Another' \
  handoffs.jq
mutate "failed-scan-is-none" "8.5" \
  'handoffs=""; running=-1' \
  'handoffs=""'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
