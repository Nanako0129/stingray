#!/bin/bash
# Network-facing acceptance for stingray.
#
# Cases A and B use a local stub server, so they prove the fail-open paths
# without a single byte leaving the machine. Cases C and D talk to the real
# endpoint, and deliberately use a SYNTHETIC assistant message — never real
# transcript content — so that running the test suite is not itself a data
# disclosure.
#
#   ./tests/network.sh          # A and B only
#   ./tests/network.sh --live   # also C (bad key) and D (latency, needs a key)
set -u
# Every case drives the hook with the environment it means to test. A shell
# that actually runs the plugin exports STINGRAY_* too, and those leak into the
# cases that deliberately set none — measured 2026-09-21: with STINGRAY=1 and
# STINGRAY_SHAPE3_JUDGE=1 exported, this suite reported 7 failures and
# network.sh 1, all spurious. Derive the list from the environment rather than
# spelling it out, so a switch added later is covered without editing this.
for v in $(env | sed -n 's/^\(STINGRAY[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/stingray.sh"
. "$HERE/hook-shell.sh"
TMP="$(mktemp -d)"
pass=0; fail=0
SYNTHETIC='我現在就把設定檔的逾時值改掉，然後跑一次測試確認。'

# Stop any stub still listening and remove the scratch directory. Runs on
# every exit path, including a failed case, so a hung stub from one run
# cannot be inherited by the next.
cleanup() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Build one Stop hook stdin payload, shaped as the harness really sends it.
# mk <last_assistant_message>
mk() {
  jq -cn --arg msg "$1" '{
    session_id: "net-test-0001", prompt_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    transcript_path: "/nonexistent/t.jsonl", cwd: "/tmp", permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: $msg, background_tasks: [], session_crons: []
  }'
}

# Record one case outcome. say ok|no <description>; anything but "ok" fails the
# run, so a new case cannot pass by forgetting to report.
say() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok    %s\n' "$2";
        else fail=$((fail+1)); printf '  FAIL  %s\n' "$2"; fi; }

# Start the local stand-in and wait for it to publish its port.
# start_stub hang|401|record — hang accepts and never answers, 401 answers 401,
# record captures request bodies. Sets $PORT.
start_stub() {
  rm -f "$TMP/port"          # a stale port file would silently reuse a dead stub
  # An outfile is always passed: record mode needs one, and without it serve()
  # raised, sent nothing, and the hook fell back to exit 0 — which one case was
  # asserting, so it passed for a reason unrelated to what it claimed.
  python3 "$HERE/stub_server.py" "$1" "$TMP/port" "$TMP/captured-$1" &
  STUB_PID=$!
  for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  PORT=$(cat "$TMP/port")
}

# Drive the real hook with one synthetic Stop payload, capturing stderr.
# run_hook <errfile> <env assignments...>; the caller reads $? for the exit code.
# Synthetic text on purpose: running the suite must not disclose a transcript.
run_hook() {
  local err="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    printf '%s' "$(mk "$SYNTHETIC")" | "$HOOK_SH" "$HOOK" >/dev/null 2>"$err" )
}

echo "stingray network acceptance"

# ── A. Timeout. A hung endpoint must not hold the turn open. Claude Code's
#      default hook timeout is 600s, so this is the guard that matters.
start_stub hang
start=$(python3 -c 'import time;print(time.time())')
run_hook "$TMP/a.err" STINGRAY_STATE_DIR="$TMP/s1" STINGRAY=1 TYPESAFE_API_KEY=dummy \
  STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone" STINGRAY_TIMEOUT=3
rc=$?
elapsed=$(python3 -c "import time;print(round(time.time()-$start,2))")
kill "$STUB_PID" 2>/dev/null; STUB_PID=
{ [ "$rc" = 0 ] && grep -q "network/timeout" "$TMP/a.err"; } \
  && say ok "A  hung endpoint → exit 0 after ${elapsed}s (STINGRAY_TIMEOUT=3), marker printed" \
  || say no "A  hung endpoint → exit $rc after ${elapsed}s; stderr: $(head -c 120 "$TMP/a.err")"
awk -v e="$elapsed" 'BEGIN{exit !(e < 4.5)}' \
  && say ok "A2 wall clock ${elapsed}s stayed inside that timeout" \
  || say no "A2 wall clock ${elapsed}s overran that timeout"

# ── A3. The same drill at the SHIPPED default. A lowered timeout proves the
#        mechanism; only this shows what a user actually pays when the endpoint
#        hangs. That cost sits outside the 1.0s latency budget, so it is
#        measured and printed rather than assumed away.
start_stub hang
start=$(python3 -c 'import time;print(time.time())')
run_hook "$TMP/a3.err" STINGRAY_STATE_DIR="$TMP/s1b" STINGRAY=1 TYPESAFE_API_KEY=dummy \
  STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
rc=$?
elapsed3=$(python3 -c "import time;print(round(time.time()-$start,2))")
kill "$STUB_PID" 2>/dev/null; STUB_PID=
DEFAULT_TIMEOUT=6
if [ "$rc" != 0 ]; then
  say no "A3 hang at the default timeout → exit $rc, want 0"
elif ! grep -q "network/timeout" "$TMP/a3.err"; then
  say no "A3 hang at the default timeout → no network/timeout marker; stderr: $(head -c 120 "$TMP/a3.err")"
elif ! awk -v e="$elapsed3" -v t="$DEFAULT_TIMEOUT" 'BEGIN{exit !(e >= t-1 && e <= t+2)}'; then
  # A floor as well as a ceiling. Without the floor this case passes on an
  # immediate exit, which is the one outcome it exists to rule out.
  say no "A3 elapsed ${elapsed3}s is outside [${DEFAULT_TIMEOUT}-1, ${DEFAULT_TIMEOUT}+2] — it did not reach the shipped timeout"
else
  say ok "A3 hang at the default timeout → exit 0 after ${elapsed3}s, marker present — worst case a user pays"
fi

# ── B. HTTP error (401) from a local stub: fail open, no block.
start_stub 401
run_hook "$TMP/b.err" STINGRAY_STATE_DIR="$TMP/s2" STINGRAY=1 TYPESAFE_API_KEY=bad-key \
  STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
{ [ "$rc" = 0 ] && grep -q "HTTP 401" "$TMP/b.err"; } \
  && say ok "B  HTTP 401 → exit 0, unavailable marker" \
  || say no "B  HTTP 401 → exit $rc; stderr: $(head -c 120 "$TMP/b.err")"

# ── B2. Does the latency sampler's own guard work? Point it at the 401 stub so
#        every invocation fails open in milliseconds — exactly the situation
#        that used to report a beautiful p95 with no classifier response behind
#        it. Zero timings must be accepted. A guard that cannot be shown to
#        fail is the defect it was added to fix.
start_stub 401
accepted=0
LOGB="$TMP/s2b/decisions.jsonl"
for _ in 1 2 3; do
  before=$( [ -f "$LOGB" ] && wc -l <"$LOGB" || echo 0 )
  run_hook "$TMP/b2.err" STINGRAY_STATE_DIR="$TMP/s2b" STINGRAY_SHADOW=1 \
    TYPESAFE_API_KEY=bad-key STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
  after=$( [ -f "$LOGB" ] && wc -l <"$LOGB" || echo 0 )
  if [ "$after" -gt "$before" ] && \
     [ -n "$(tail -1 "$LOGB" 2>/dev/null | jq -r 'select((.secs // "") != "") | .secs')" ]; then
    accepted=$((accepted+1))
  fi
done
kill "$STUB_PID" 2>/dev/null; STUB_PID=
[ "$accepted" -eq 0 ] \
  && say ok "B2 latency sampler rejects fail-open invocations (0 of 3 accepted)" \
  || say no "B2 latency sampler accepted $accepted of 3 fail-open invocations — p95 would be fiction"

# ── B3. A 200 carrying a score of 2. A character allowlist accepts it and 2
#        clears any threshold, so malformed input would block. It must not.
start_stub badscore
run_hook "$TMP/b3.err" STINGRAY_STATE_DIR="$TMP/s3b" STINGRAY=1 TYPESAFE_API_KEY=dummy \
  STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
{ [ "$rc" = 0 ] && grep -q "malformed response" "$TMP/b3.err"; } \
  && say ok "B3 score outside [0,1] → exit 0, reported malformed" \
  || say no "B3 score outside [0,1] → exit $rc; stderr: $(head -c 140 "$TMP/b3.err")"

# ── B4. Correspondence. Something IS running, but not the thing that was
#        promised. Counting cannot tell those apart — this is the case that used
#        to pass silently because a build satisfied "something is running".
mk_watch() {  # mk_watch <background_tasks json>
  jq -cn --argjson bg "$1" '{
    session_id: "net-watch-'"$RANDOM"'", prompt_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    transcript_path: "/nonexistent/t.jsonl", cwd: "/tmp", permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: "我會盯著 CodeRabbit 的結果，有動靜回報。",
    background_tasks: $bg, session_crons: []
  }'
}
start_stub mismatch
( export STINGRAY_STATE_DIR="$TMP/s4b" STINGRAY_SHAPE3=1 STINGRAY_SHAPE3_JUDGE=1 STINGRAY=1 TYPESAFE_API_KEY=dummy \
         STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
  mk_watch '[{"id":"b1","type":"shell","status":"running","description":"build","command":"make"}]' \
    | "$HOOK_SH" "$HOOK" >/dev/null 2>"$TMP/b4.err" )
rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
{ [ "$rc" = 2 ] && grep -q "corresponds to it" "$TMP/b4.err"; } \
  && say ok "B4 running work that does not correspond → blocked on the judgement" \
  || say no "B4 unrelated running work → exit $rc; stderr: $(head -c 140 "$TMP/b4.err")"

# ── B5. The same shape with the judgement going the other way must not block.
#        Only watch_mismatch scores high under this stub, so a pass here proves
#        nothing else is quietly doing the blocking.
start_stub record
( export STINGRAY_STATE_DIR="$TMP/s5b" STINGRAY_SHAPE3=1 STINGRAY=1 TYPESAFE_API_KEY=dummy \
         STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
  mk_watch '[{"id":"b1","type":"shell","status":"running","description":"poll CodeRabbit","command":"gh pr checks"}]' \
    | "$HOOK_SH" "$HOOK" >/dev/null 2>"$TMP/b5.err" )
rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
# Not blocking is also what a crashed stub produces, so require evidence that a
# scored response actually came back: a decision record carrying a measured secs.
# Require the watch_ok record specifically. A timed record for no_action or
# broken_promise would also appear if watch_mismatch were never asked, so
# accepting any record lets this pass on a hook that dropped the question.
b5_ok=$(jq -r 'select(.shape == "watch_ok" and (.secs // "") != "") | .shape' \
  "$TMP/s5b/decisions.jsonl" 2>/dev/null | head -1)
{ [ "$rc" = 0 ] && [ "$b5_ok" = "watch_ok" ]; } \
  && say ok "B5 corresponding work → not blocked, and watch_mismatch was answered" \
  || say no "B5 corresponding work → exit $rc, watch_ok record=${b5_ok:-none}; stderr: $(head -c 140 "$TMP/b5.err")"

# ── B6. The correspondence judgement must not block without its own switch.
#        Shape 3's claim is that it blocks only when the answer is certain, and
#        a model answer with a borrowed threshold is not certain. Same stub as
#        B4, same inputs, only STINGRAY_SHAPE3_JUDGE removed.
start_stub mismatch
( export STINGRAY_STATE_DIR="$TMP/s6b" STINGRAY_SHAPE3=1 STINGRAY=1 TYPESAFE_API_KEY=dummy \
         STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
  mk_watch '[{"id":"b1","type":"shell","status":"running","description":"build","command":"make"}]' \
    | "$HOOK_SH" "$HOOK" >/dev/null 2>"$TMP/b6.err" )
rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
b6_rec=$(jq -r 'select(.shape == "unwatched") | .would_block' "$TMP/s6b/decisions.jsonl" 2>/dev/null | head -1)
{ [ "$rc" = 0 ] && [ "$b6_rec" = "false" ]; } \
  && say ok "B6 judgement without its own switch → recorded, not blocked" \
  || say no "B6 judgement without its switch → exit $rc, would_block=${b6_rec:-none}"

# ── B7. An absent background_tasks is not an empty one. The context sent to Jev
#        described it as "nothing running or scheduled", turning unknown state
#        into confirmed inactivity. Read the body that actually left the hook.
rm -f "$TMP/captured-record"
start_stub record
( export STINGRAY_STATE_DIR="$TMP/s7b" STINGRAY_SHADOW=1 TYPESAFE_API_KEY=dummy \
         STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
  mk "$SYNTHETIC" | jq -c 'del(.background_tasks)' | "$HOOK_SH" "$HOOK" >/dev/null 2>"$TMP/b7.err" )
kill "$STUB_PID" 2>/dev/null; STUB_PID=
b7_bg=$(jq -r '[.questions[].instructions.background] | unique | join("|")' "$TMP/captured-record" 2>/dev/null | head -1)
[ "$b7_bg" = "background list unavailable" ] \
  && say ok "B7 absent background_tasks → sent as unavailable, not as empty" \
  || say no "B7 absent background_tasks → background sent as: ${b7_bg:-<no request captured>}"

# ── L. The language, judged by Jev. Each case reads what the stub received, not
#       only the exit code: which questions went out, and what they carried.
mkl() {  # mkl <message> <session> [cwd]
  jq -cn --arg msg "$1" --arg sid "$2" --arg cwd "${3:-/tmp}" '{
    session_id: $sid, prompt_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    transcript_path: "/nonexistent/t.jsonl", cwd: $cwd, permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: $msg, background_tasks: [], session_crons: []
  }'
}
LCFG="$TMP/lcfg"; mkdir -p "$LCFG"; printf '{"language":"zh-TW"}\n' >"$LCFG/settings.json"
LEN='Done. I changed the timeout in the config and ran the whole suite, and every case passed on both runners, so the branch is ready for review.'
LZH='改好了。我把設定檔裡的 timeout 調整過，整套測試在 macOS 與 ubuntu 兩邊都通過，這個分支可以送審了。'
run_lang() {  # run_lang <state dir> <stdin> <env...>; stderr to <state dir>.err
  local st="$1" in="$2"; shift 2
  ( export STINGRAY_STATE_DIR="$st" CLAUDE_CONFIG_DIR="$LCFG" TYPESAFE_API_KEY=dummy \
           STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
    for kv in "$@"; do export "${kv?}"; done
    printf '%s' "$in" | "$HOOK_SH" "$HOOK" >/dev/null 2>"$st.err" )
}

# L1. Judged not to be the configured language → blocked, naming the language.
start_stub wronglang
run_lang "$TMP/l1" "$(mkl "$LEN" net-l1)" STINGRAY_LANG=1; rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
{ [ "$rc" = 2 ] && grep -q "not in the configured language" "$TMP/l1.err" && grep -q "繁體中文（台灣，zh-TW）" "$TMP/l1.err"; } \
  && say ok "L1 judged wrong language → blocked, naming 繁體中文（台灣，zh-TW）" \
  || say no "L1 judged wrong language → exit $rc; stderr: $(head -c 160 "$TMP/l1.err")"

# L2. LANG alone asks the language question and nothing else, and that question
#     carries the message and the language name only — no tool list, no
#     background.
rm -f "$TMP/captured-record"; start_stub record
run_lang "$TMP/l2" "$(mkl "$LZH" net-l2)" STINGRAY_LANG=1; rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
l2=$(jq -c '{q: (.questions | keys), i: (.questions.wrong_language.instructions | keys), l: .questions.wrong_language.instructions.language}' "$TMP/captured-record" 2>/dev/null | head -1)
[ "$rc" = 0 ] && [ "$l2" = '{"q":["wrong_language"],"i":["final_text","language","question"],"l":"繁體中文（台灣，zh-TW）"}' ] \
  && say ok "L2 LANG alone → one question, carrying final_text and the language name only" \
  || say no "L2 LANG alone → exit $rc, sent: ${l2:-<no request captured>}"

# L3. With shapes 1 and 2 on as well, all three go in one request — and the
#     language stays on its own question. On no_action it would change the input
#     the 81.8% was measured on.
rm -f "$TMP/captured-record"; start_stub record
run_lang "$TMP/l3" "$(mkl "$LZH" net-l3)" STINGRAY=1 STINGRAY_LANG=1; rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
l3=$(jq -c '{q: (.questions | keys), na: (.questions.no_action.instructions | has("language"))}' "$TMP/captured-record" 2>/dev/null | head -1)
[ "$l3" = '{"q":["broken_promise","no_action","wrong_language"],"na":false}' ] \
  && say ok "L3 STINGRAY + LANG → one request, language only on wrong_language" \
  || say no "L3 STINGRAY + LANG → sent: ${l3:-<no request captured>}"

# L4. The project's settings.local.json outranks the user file, and a code the
#     hook knows is sent as a name.
LPROJ="$TMP/lproj"; mkdir -p "$LPROJ/.claude"; printf '{"language":"en"}\n' >"$LPROJ/.claude/settings.local.json"
rm -f "$TMP/captured-record"; start_stub record
run_lang "$TMP/l4" "$(mkl "$LZH" net-l4 "$LPROJ")" STINGRAY_LANG=1
kill "$STUB_PID" 2>/dev/null; STUB_PID=
l4=$(jq -r '.questions.wrong_language.instructions.language' "$TMP/captured-record" 2>/dev/null | head -1)
[ "$l4" = "英文（en）" ] \
  && say ok "L4 project setting outranks the user's, sent as 英文（en）" \
  || say no "L4 project setting → language sent: ${l4:-<no request captured>}"

# L5. Shadow records the judgement and never blocks.
start_stub wronglang
run_lang "$TMP/l5" "$(mkl "$LEN" net-l5)" STINGRAY_SHADOW=1 STINGRAY_LANG=1; rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
l5=$(jq -r 'select(.shape == "wrong_language") | .would_block' "$TMP/l5/decisions.jsonl" 2>/dev/null | head -1)
{ [ "$rc" = 0 ] && [ "$l5" = "false" ]; } \
  && say ok "L5 SHADOW + LANG → recorded, not blocked" \
  || say no "L5 SHADOW + LANG → exit $rc, would_block=${l5:-none}"

# L6. A decision record that cannot be written is a failure path: not blocked.
mkdir -p "$TMP/l6/decisions.jsonl"
start_stub wronglang
run_lang "$TMP/l6" "$(mkl "$LEN" net-l6)" STINGRAY_LANG=1; rc=$?
kill "$STUB_PID" 2>/dev/null; STUB_PID=
{ [ "$rc" = 0 ] && [ ! -s "$TMP/l6.err" ]; } \
  && say ok "L6 unwritable decision log → not blocked, nothing printed" \
  || say no "L6 unwritable decision log → exit $rc; stderr: $(head -c 120 "$TMP/l6.err")"

# L7. Nothing to judge, nothing sent.
rm -f "$TMP/captured-record"; start_stub record
run_lang "$TMP/l7" "$(mkl 'acceptance 49/0, network 10/0, mutants 4/0, fixture 44/0.' net-l7)" STINGRAY_LANG=1
kill "$STUB_PID" 2>/dev/null; STUB_PID=
[ ! -s "$TMP/captured-record" ] \
  && say ok "L7 no prose → no request" \
  || say no "L7 no prose → a request was sent: $(head -c 120 "$TMP/captured-record")"

if [ "${1:-}" != "--live" ]; then
  echo; printf 'passed %d, failed %d  (live cases skipped; pass --live)\n' "$pass" "$fail"
  [ "$fail" = 0 ]; exit
fi

# ── C. Real endpoint, invalid key. Proves the whole chain falls back against the
#      service that will actually be in front of it. Synthetic message only.
run_hook "$TMP/c.err" STINGRAY_STATE_DIR="$TMP/s3" STINGRAY=1 \
  TYPESAFE_API_KEY=sk-invalid-0000000000000000
rc=$?
{ [ "$rc" = 0 ] && grep -qE "HTTP (401|403)" "$TMP/c.err"; } \
  && say ok "C  real endpoint + invalid key → exit 0 ($(tr -d '\n' < "$TMP/c.err"))" \
  || say no "C  real endpoint + invalid key → exit $rc; stderr: $(head -c 160 "$TMP/c.err")"

# ── D. Latency in SHADOW, the mode people actually run. Measured at the hook
#      position, not with a bare curl: what matters is what the turn waits for.
echo "  -- latency, shadow mode, 20 runs --"
if [ -z "${TYPESAFE_API_KEY:-}" ] && [ ! -s "$HOME/.config/typesafe/api_key" ]; then
  say no "D  latency not measured — no key configured. A keyless run returns in ~0.01s and would report a fake number."
else
  : >"$TMP/times"
  LOG="$TMP/s4/decisions.jsonl"
  rejected=0
  for _ in $(seq 1 20); do
    before=$( [ -f "$LOG" ] && wc -l <"$LOG" || echo 0 )
    s=$(python3 -c 'import time;print(time.time())')
    run_hook "$TMP/d.err" STINGRAY_STATE_DIR="$TMP/s4" STINGRAY_SHADOW=1
    elapsed_one=$(python3 -c "import time;print(round(time.time()-$s,3))")
    after=$( [ -f "$LOG" ] && wc -l <"$LOG" || echo 0 )
    # A completed round trip appends exactly one record carrying a measured
    # secs. A fail-open appends none and returns in milliseconds; counting it
    # would report a passing p95 with no classifier response behind it.
    if [ "$after" -gt "$before" ] && \
       [ -n "$(tail -1 "$LOG" | jq -r 'select((.secs // "") != "") | .secs')" ]; then
      printf '%s\n' "$elapsed_one" >>"$TMP/times"
    else
      rejected=$((rejected+1))
    fi
  done
  # What must hold is that the p95 is computed only from real round trips and
  # that enough of them remain to mean anything — not that every single request
  # succeeded. A transient fail-open is excluded from the sample (above) and
  # reported here; p95 over 19 samples is still a p95, which is why latency.py
  # takes the nearest rank rather than assuming n=20.
  #
  # Zero tolerance was the first version. It turns one network blip into a red
  # suite, and a suite that goes red for reasons unrelated to the code stops
  # being read. 15 is the floor for a usable sample, not a number chosen to make
  # a failing run pass.
  #
  # Honest note, 2026-09-21: one --live run reported 8 passed / 1 failed and was
  # not reproduced in five subsequent runs, so which case failed is unknown.
  # This change is about the threshold's design and is NOT known to be the fix
  # for that run. If it recurs, capture the full output before re-running.
  accepted=$(( 20 - rejected ))
  if [ "$accepted" -ge 15 ]; then
    if [ "$rejected" -eq 0 ]; then
      say ok "D0 all 20 invocations completed a round trip"
    else
      say ok "D0 $accepted of 20 completed a round trip; $rejected excluded from the sample"
    fi
  else
    say no "D0 only $accepted of 20 completed a round trip — too few to measure: $(head -c 120 "$TMP/d.err")"
  fi
  if python3 "$HERE/latency.py" "$TMP/times" 1.0; then
    say ok "D  shadow p95 within the 1.0s budget"
  else
    say no "D  shadow p95 over the 1.0s budget — active must stay off"
  fi
fi

echo; printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
