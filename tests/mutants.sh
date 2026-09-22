#!/bin/bash
# Do the guards still guard?
#
# Two acceptance cases exist to catch one specific implementation mistake each.
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
# break to fail. mutate <name> <case-label> <anchor> <replacement>: the anchor
# must still be present in the hook, so a refactor that moves the code under
# test fails loudly here instead of quietly disarming the mutant.
mutate() {
  local name="$1" want_case="$2" anchor="$3" replacement="$4"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  cp -R "$ROOT/hooks" "$ROOT/tests" "$ROOT/questions.json" "$dir/"

  ANCHOR="$anchor" REPLACEMENT="$replacement" python3 - "$dir/hooks/stingray.sh" <<'PY'
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

# Mutant 1 — shape 3's declaration regex run on redacted text instead of the
# raw message. Case 7 puts the declaration on a line carrying a path, and
# redaction drops such a line whole, so the mutant sees nothing and never fires.
mutate "regex-on-redacted" "7 " \
  'if [ "$shape3_on" = "1" ] && watch_claims "$last"; then' \
  'mutant_redacted=$(printf '"'"'%s'"'"' "$last" | perl -ne '"'"'next if m{\b[\w.-]+/[\w./-]+\.[A-Za-z0-9]{1,6}\b}; print'"'"')
if [ "$shape3_on" = "1" ] && watch_claims "$mutant_redacted"; then'

# Mutant 2 — a missing background_tasks key read as "nothing is running". That
# turns shape 3 into "block whenever the regex matches"; case 9 is the only
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

# Mutant 4 — shape-3-only mode falls through to the Jev request path. This is
# the regression that actually shipped once: the switch promised no request
# while a key on disk made one anyway.
mutate "shape3-reaches-jev" "15" \
  '[ "$MODE" = "local" ] && [ "$lang_ask" != "1" ] && exit 0' \
  ':'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
