#!/bin/bash
# Acceptance checks for stingray. Every case drives the real hook script with a
# real stdin payload and asserts on the observed exit code and stderr — none of
# them inspect the source.
#
# Every case here is offline: no API key, no network. The network-facing
# fail-open paths live in network.sh.
#
#   ./tests/acceptance.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/stingray.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# stdin the way the harness really sends it, measured on v2.1.278.
mk() {  # mk <last_assistant_message> <background_tasks json> [session-id]
  jq -cn --arg msg "$1" --argjson bg "$2" --arg sid "${3:-test-session-0001}" '{
    session_id: $sid,
    prompt_id: "11111111-2222-3333-4444-555555555555",
    transcript_path: "/nonexistent/transcript.jsonl",
    cwd: "/tmp",
    permission_mode: "default",
    hook_event_name: "Stop",
    stop_hook_active: false,
    last_assistant_message: $msg,
    background_tasks: $bg,
    session_crons: []
  }'
}

# Run one case against the real hook and assert on what was observed, never on
# the source. check <name> <stdin> <want_exit> <want_stderr_substr|-> <env...>;
# pass "-" to require stderr to be empty.
check() {
  local name="$1" stdin="$2" want="$3" want_err="$4"; shift 4
  local err rc
  err="$TMP/err.$$"
  ( export STINGRAY_STATE_DIR="$TMP/state"; for kv in "$@"; do export "${kv?}"; done
    printf '%s' "$stdin" | bash "$HOOK" >/dev/null 2>"$err" )
  rc=$?
  local ok=1
  [ "$rc" = "$want" ] || ok=0
  if [ "$want_err" != "-" ] && ! grep -q "$want_err" "$err"; then ok=0; fi
  if [ "$want_err" = "-" ] && [ -s "$err" ]; then ok=0; fi
  if [ "$ok" = 1 ]; then
    pass=$((pass+1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail+1)); printf '  FAIL  %s (exit %s, want %s)\n        stderr: %s\n' \
      "$name" "$rc" "$want" "$(head -c 200 "$err")"
  fi
}

WATCH_PLAIN='已經送審了，我會盯著 CodeRabbit 的結果，有動靜回報。'
# The declaration shares its line with a relative path. Redaction drops such a
# line whole, so this case fails against an implementation that matches on
# redacted text. A URL here would NOT work: URLs are replaced in place, the line
# survives, and the wrong implementation would pass. Measured, not assumed.
WATCH_PATH='已經送審了，我會盯著 src/main.rs 的測試結果，有動靜回報。'
NEUTRAL='這三個檔案都改好了，測試全過。'
OFFLINE=(TYPESAFE_API_KEY= HOME="$TMP/nohome" STINGRAY_ENDPOINT=http://127.0.0.1:1/unreachable)

echo "stingray acceptance — offline cases"

# 1. Off by default: no env var set, nothing happens at all.
check "1  off by default → no action" "$(mk "$WATCH_PLAIN" '[]')" 0 "-"

# 2. Harness loop guard: stop_hook_active true is an immediate pass.
check "2  stop_hook_active=true → pass" \
  "$(mk "$WATCH_PLAIN" '[]' | jq -c '.stop_hook_active=true')" 0 "-" STINGRAY=1 STINGRAY_SHAPE3=1

# 3. No key, shape-3 positive. The shape-3 branch must not fire for someone who
#    never configured the plugin. This is the case a "bad key" test cannot catch.
#    Behaviour is unchanged AND a visible unavailable marker is printed.
check "3  no key + shape 3 positive → pass, marker shown" "$(mk "$WATCH_PLAIN" '[]')" 0 "no key" \
  STINGRAY_SHADOW=1 TYPESAFE_API_KEY= HOME="$TMP/nohome"

# 4. Same case again, same session: the marker is printed once per session, not
#    once per turn. Depends on case 3 having run against this state dir.
check "4  no key again → silent, still passes" "$(mk "$WATCH_PLAIN" '[]')" 0 "-" \
  STINGRAY_SHADOW=1 TYPESAFE_API_KEY= HOME="$TMP/nohome"

# 5. Active plus shape 3's own flag: this is the only configuration that blocks.
check "5  active + SHAPE3 flag → block" "$(mk "$WATCH_PLAIN" '[]' sess-block-5)" 2 "nothing is running" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${OFFLINE[@]}"

# 6. Active WITHOUT shape 3's flag: shape 3 must not ride in on the Jev gate.
check "6  active without SHAPE3 flag → pass" "$(mk "$WATCH_PLAIN" '[]')" 0 "-" \
  STINGRAY=1 TYPESAFE_API_KEY= HOME="$TMP/nohome"

# 7. The redaction trap. Shape 3's regex must run on the RAW message. Here the
#    declaration shares its line with a path, which redaction drops whole — so
#    an implementation that matched on redacted text finds nothing and fails.
check "7  declaration on a path line → still fires" "$(mk "$WATCH_PATH" '[]' sess-block-7)" 2 "nothing is running" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${OFFLINE[@]}"

# 8. Negative: something IS running, so the promise is kept.
check "8  running background task → pass" \
  "$(mk "$WATCH_PLAIN" '[{"id":"a1","type":"shell","status":"running","description":"poll","command":"gh pr checks"}]')" \
  0 "-" STINGRAY=1 STINGRAY_SHAPE3=1 TYPESAFE_API_KEY= HOME="$TMP/nohome"

# 9. Missing background_tasks key must not be read as "nothing is running".
check "9  background_tasks key absent → pass" \
  "$(mk "$WATCH_PLAIN" '[]' | jq -c 'del(.background_tasks)')" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 TYPESAFE_API_KEY= HOME="$TMP/nohome"

# 10. No monitoring claim at all: shape 3 is silent.
check "10 no watch declaration → pass" "$(mk "$NEUTRAL" '[]')" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 TYPESAFE_API_KEY= HOME="$TMP/nohome"

# 13. Shape 3 standalone. It needs no API key and no network, so STINGRAY_SHAPE3
#     alone must enable the hook and block — without switching on the two Jev
#     judgements, which have their own calibration bar. CodeRabbit proposed
#     fixing the original gap by setting MODE=active from this flag; that would
#     have handed a user who asked for the free local check the two that cost
#     money and are not yet calibrated.
check "13 SHAPE3 alone → block" "$(mk "$WATCH_PLAIN" '[]' sess-block-13)" 2 "nothing is running" \
  STINGRAY_SHAPE3=1 "${OFFLINE[@]}"

# 14. Shadow outranks it. Recording mode never blocks, whatever else is set.
check "14 SHADOW + SHAPE3 → record only" "$(mk "$WATCH_PLAIN" '[]')" 0 "-" \
  STINGRAY_SHADOW=1 STINGRAY_SHAPE3=1 "${OFFLINE[@]}"

# 15. Shape-3-only mode must never reach the Jev request path, even when a key
#     is configured. The endpoint here is unreachable, so any attempt would
#     print a network marker; an empty stderr proves nothing was sent. Without
#     the guard, someone who set only STINGRAY_SHAPE3=1 but happens to have a
#     key on disk would have this turn's message transmitted anyway.
check "15 SHAPE3 alone + key → nothing sent" "$(mk "$NEUTRAL" '[]' sess-15)" 0 "-" \
  STINGRAY_SHAPE3=1 TYPESAFE_API_KEY=would-be-used-if-reached \
  STINGRAY_ENDPOINT=http://127.0.0.1:1/unreachable HOME="$TMP/nohome"

# 16. background_tasks: null must not read as "nothing is running". has() is
#     true for null and [ .[]? ] over null counts zero, so without a type check
#     this blocks — the same defect as a missing key, through a different door.
#     The no-key marker is the expected stderr here: not blocking is the claim,
#     and reaching the key check at all proves shape 3 declined to fire.
check "16 background_tasks null → pass" \
  "$(mk "$WATCH_PLAIN" '[]' sess-16 | jq -c '.background_tasks=null')" 0 "no key" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${OFFLINE[@]}"

# 17. Phrasings the first live shadow run showed were missed. The waiting verb
#     takes a suffix (等著 / 等待) and the outcome word is not always one of the
#     first four that were tried, so each of these was a real positive that
#     shape 3 recorded nothing for.
# One phrase per alternative that was added, so removing any single one of them
# fails a case rather than passing on the strength of its neighbours.
#
# Each phrase must make its own alternative load-bearing. The first attempt at
# the 出來 case was 「等審查結果出來我告訴你」, which contains 結果 — already an
# outcome word — so the pattern matched on that and deleting 出來 changed
# nothing. An ablation found it: remove one alternative, and exactly one case
# must fail.
# Set here, not defaulted inside the loop: ${phrase_n:-0} would inherit an
# exported phrase_n and shift every label and session id.
phrase_n=0
for phrase in \
  "沒問題，我會等著 CodeRabbit 的審查結果。" \
  "我會等待 CodeRabbit 的結果。" \
  "我會等到 review 完成再往下做。" \
  "我會等 CI 跑完再回報。" \
  "等 CodeRabbit 的回覆進來我就處理。" \
  "等 CI 的數字出來我再判斷。" \
  "等審查結果回來我告訴你。"
do
  # A counter, not $RANDOM: a test that varies between runs cannot be replayed,
  # and this suite already has one failure nobody could reproduce. Numbered
  # rather than sliced, because ${var:0:14} counts characters under a UTF-8
  # locale and bytes otherwise, so the label would be cut mid-character on a
  # runner that does not set one.
  phrase_n=$((phrase_n + 1))
  check "17.$phrase_n watch phrasing" "$(mk "$phrase" '[]' "sess-17-$phrase_n")" \
    2 "nothing is running" STINGRAY_SHAPE3=1 "${OFFLINE[@]}"
done

# 11. Block budget, independent of stop_hook_active. Feed the same blocking
#     case four times with stop_hook_active pinned false, as if the harness
#     guard had been reset; the fourth must refuse to block.
echo "  -- block budget --"
BUDGET_STATE="$TMP/budget"; rm -rf "$BUDGET_STATE"
for i in 1 2 3 4; do
  err="$TMP/b.$i"
  ( export STINGRAY_STATE_DIR="$BUDGET_STATE" STINGRAY=1 STINGRAY_SHAPE3=1 "${OFFLINE[@]}"
    printf '%s' "$(mk "$WATCH_PLAIN" '[]')" | bash "$HOOK" >/dev/null 2>"$err" )
  rc=$?
  want=2; [ "$i" = 4 ] && want=0
  if [ "$rc" = "$want" ]; then
    pass=$((pass+1)); printf '  ok    11.%s block #%s → exit %s\n' "$i" "$i" "$rc"
  else
    fail=$((fail+1)); printf '  FAIL  11.%s block #%s → exit %s, want %s\n' "$i" "$i" "$rc" "$want"
  fi
done
if grep -q "block budget" "$TMP/b.4"; then
  pass=$((pass+1)); printf '  ok    11.5 budget message printed\n'
else
  fail=$((fail+1)); printf '  FAIL  11.5 budget message missing: %s\n' "$(head -c 120 "$TMP/b.4")"
fi

# 12. Shadow leaves a record; that log is the only thing calibration can use.
if [ -s "$TMP/state/decisions.jsonl" ] && \
   jq -e 'select(.mode=="shadow" and .shape=="unwatched" and .would_block=="false")' \
      "$TMP/state/decisions.jsonl" >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  ok    12 shadow wrote a decision record\n'
else
  fail=$((fail+1)); printf '  FAIL  12 no shadow record in decisions.jsonl\n'
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
