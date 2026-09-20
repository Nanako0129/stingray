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
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/stingray.sh"
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
  python3 "$HERE/stub_server.py" "$1" "$TMP/port" &
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
    printf '%s' "$(mk "$SYNTHETIC")" | bash "$HOOK" >/dev/null 2>"$err" )
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
  [ "$rejected" -eq 0 ] \
    && say ok "D0 all 20 invocations completed a round trip" \
    || say no "D0 $rejected of 20 invocations failed open and were excluded: $(head -c 120 "$TMP/d.err")"
  if python3 "$HERE/latency.py" "$TMP/times" 1.0; then
    say ok "D  shadow p95 within the 1.0s budget"
  else
    say no "D  shadow p95 over the 1.0s budget — active must stay off"
  fi
fi

echo; printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
