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
    printf '%s' "$stdin" | "$HOOK_SH" "$HOOK" >/dev/null 2>"$err" )
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
WATCH_PATH='已經送審了，我會盯著 src/main.rs 的 CI 結果，有動靜回報。'
NEUTRAL='這三個檔案都改好了，測試全過。'
OFFLINE=(TYPESAFE_API_KEY= HOME="$TMP/nohome" STINGRAY_ENDPOINT=http://127.0.0.1:1/unreachable)

# Shape 3 is judged by Jev, so the cases that need it answered run against a
# stub on this machine: CLAIMS answers "a promise to watch was made" and nothing
# else, ZEROS answers every question with 0. Neither reads the message — whether
# a given sentence is a promise is measured live, in watch-fixture.sh.
start_stub() {  # start_stub <mode> <name>; sets <name>_PORT
  local pf="$TMP/port-$2"
  python3 "$HERE/stub_server.py" "$1" "$pf" "$TMP/captured-$2" &
  STUB_PIDS="${STUB_PIDS:-} $!"
  for _ in $(seq 1 50); do [ -s "$pf" ] && break; sleep 0.1; done
  eval "$2_PORT=\$(cat "$pf")"
}
trap 'kill $STUB_PIDS 2>/dev/null; rm -rf "$TMP"' EXIT
start_stub claimonly CLAIM; start_stub record ZERO
CLAIMS=(TYPESAFE_API_KEY=dummy HOME="$TMP/nohome" STINGRAY_ENDPOINT="http://127.0.0.1:$CLAIM_PORT/v1/systemone")
ZEROS=(TYPESAFE_API_KEY=dummy HOME="$TMP/nohome" STINGRAY_ENDPOINT="http://127.0.0.1:$ZERO_PORT/v1/systemone")

echo "stingray acceptance — offline cases (hook runs on $HOOK_SH $HOOK_SH_VERSION)"

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
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 6. Active WITHOUT shape 3's flag: shape 3 must not ride in on the Jev gate.
check "6  active without SHAPE3 flag → pass" "$(mk "$WATCH_PLAIN" '[]' sess-6)" 0 "-" \
  STINGRAY=1 "${CLAIMS[@]}"

# 7. Retired with the regex. It required a promise written on a line carrying a
#    path to fire, which held because the regex read the raw message. Jev reads
#    the redacted one, where that line is gone; the loss is in the README's
#    known limits rather than asserted here, since offline the stub cannot tell.

# 8. Negative: something IS running, so the promise is kept.
check "8  running background task → pass" \
  "$(mk "$WATCH_PLAIN" '[{"id":"a1","type":"shell","status":"running","description":"poll","command":"gh pr checks"}]')" \
  0 "-" STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 9. Missing background_tasks key must not be read as "nothing is running".
check "9  background_tasks key absent → pass" \
  "$(mk "$WATCH_PLAIN" '[]' sess-9 | jq -c 'del(.background_tasks)')" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 8.1–8.3. A handoff to another Claude session is a mechanism too: SendMessage
#     to it, and no <cross-session-message> back from it yet. The records below
#     have the shapes read from a real transcript (hooks/handoffs.jq).
ho_send() {  # ho_send <tool_use id> <to> <tool_result text>
  jq -cn --arg id "$1" --arg to "$2" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:"SendMessage",input:{to:$to,message:"please report back when the PR is open"}}]}}'
  jq -cn --arg id "$1" --arg t "$3" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:$t}]}]}}'
}
ho_reply() {  # ho_reply <from-name>
  jq -cn --arg n "$1" '{type:"attachment",attachment:{type:"queued_command",prompt:("<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"" + $n + "\" from-mode=\"prompting\">\nPR opened.\n</cross-session-message>")}}'
}
HO_CROSS='{"success":true,"message":"“please report back” → win-94 (another Claude session)"}'
HO_SUB='{"success":true,"message":"Message queued for delivery to a8a80a1b at its next tool round."}'
ho_send toolu_H1 win-94 "$HO_CROSS" >"$TMP/ho-pending.jsonl"
{ ho_send toolu_H1 win-94 "$HO_CROSS"; ho_reply win-94; } >"$TMP/ho-answered.jsonl"
ho_send toolu_H3 a8a80a1b "$HO_SUB" >"$TMP/ho-subagent.jsonl"
HANDED='已交給 Windows session，等它回報 PR 開好，我再接著寫 #45 的更新。'
ho_mk() { mk "$HANDED" '[]' "$2" | jq -c --arg t "$1" '.transcript_path = $t'; }

check "8.1 handoff awaiting a reply → pass" "$(ho_mk "$TMP/ho-pending.jsonl" sess-h1)" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"
check "8.2 handoff already answered → block" "$(ho_mk "$TMP/ho-answered.jsonl" sess-h2)" 2 "nothing is running" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"
check "8.3 message to a subagent is not a handoff → block" "$(ho_mk "$TMP/ho-subagent.jsonl" sess-h3)" 2 "nothing is running" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 8.4. A message that quotes the answer tag mid-text is not an answer. Matched
#     anywhere, the quote below ended a handoff still waiting.
{ ho_send toolu_H1 win-94 "$HO_CROSS"
  jq -cn '{type:"user",message:{role:"user",content:"這段是什麼：<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"win-94\"> 我看不懂"}}'
} >"$TMP/ho-quoted.jsonl"
check "8.4 a quoted answer tag does not end a handoff → pass" "$(ho_mk "$TMP/ho-quoted.jsonl" sess-h4)" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 8.5. A scan that fails leaves the count unknown. The truncated record below is
#     the kind a transcript still being written can end on; with the handoffs
#     read as none, shape 3 blocked.
{ ho_send toolu_H1 win-94 "$HO_CROSS"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMessage"'; } >"$TMP/ho-broken.jsonl"
check "8.5 unreadable handoff scan → shape 3 unknown, pass" "$(ho_mk "$TMP/ho-broken.jsonl" sess-h5)" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 10. No monitoring claim at all: shape 3 is silent.
check "10 no watch declaration → pass" "$(mk "$NEUTRAL" '[]' sess-10)" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${ZEROS[@]}"

# 13. Shape 3 standalone. It needs no API key and no network, so STINGRAY_SHAPE3
#     alone must enable the hook and block — without switching on the two Jev
#     judgements, which have their own calibration bar. CodeRabbit proposed
#     fixing the original gap by setting MODE=active from this flag; that would
#     have handed a user who asked for the free local check the two that cost
#     money and are not yet calibrated.
check "13 SHAPE3 alone → block" "$(mk "$WATCH_PLAIN" '[]' sess-block-13)" 2 "nothing is running" \
  STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 14. Shadow outranks it. Recording mode never blocks, whatever else is set.
check "14 SHADOW + SHAPE3 → record only" "$(mk "$WATCH_PLAIN" '[]' sess-14)" 0 "-" \
  STINGRAY_SHADOW=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 15. SHAPE3 alone now asks Jev — the check that used to be local sends the
#     redacted final message, and with an unreachable endpoint that shows as the
#     network marker.
check "15 SHAPE3 alone + key → asked" "$(mk "$NEUTRAL" '[]' sess-15)" 0 "network/timeout" \
  STINGRAY_SHAPE3=1 TYPESAFE_API_KEY=would-be-used-if-reached \
  STINGRAY_ENDPOINT=http://127.0.0.1:1/unreachable HOME="$TMP/nohome"

# 15.1 But not when there is nothing to ask. With the background list missing,
#     shape 3 has no count to act on, so selective mode must exit before reading
#     a key or sending anything. Without that exit a key on disk would send the
#     message with no question to put to it.
check "15.1 SHAPE3 alone, background unreadable → nothing sent" \
  "$(mk "$WATCH_PLAIN" '[]' sess-15-1 | jq -c 'del(.background_tasks)')" 0 "-" \
  STINGRAY_SHAPE3=1 TYPESAFE_API_KEY=would-be-used-if-reached \
  STINGRAY_ENDPOINT=http://127.0.0.1:1/unreachable HOME="$TMP/nohome"

# 16. background_tasks: null must not read as "nothing is running". has() is
#     true for null and [ .[]? ] over null counts zero, so without a type check
#     this blocks — the same defect as a missing key, through a different door.
#     The stub answers that a promise was made, so only the type check stands
#     between this turn and a block.
check "16 background_tasks null → pass" \
  "$(mk "$WATCH_PLAIN" '[]' sess-16 | jq -c '.background_tasks=null')" 0 "-" \
  STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 17. Retired with the regex: one phrasing per alternative of the old pattern.
#     Which phrasings Jev reads as a promise is measured live instead, on the
#     labelled lines of watch-fixture.tsv.

# 18. A cron doing the polling is a kept promise. session_crons went unread
#     until a probe showed shape 3 blocking a turn whose cron was polling
#     exactly the thing the turn promised to watch.
check "18 cron is polling → pass" \
  "$(jq -cn --arg m "$WATCH_PLAIN" '{session_id:"sess-18",prompt_id:"p",
      transcript_path:"/nonexistent/t.jsonl",cwd:"/tmp",permission_mode:"default",
      hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m,
      background_tasks:[],
      session_crons:[{id:"c1",schedule:"*/5 * * * *",prompt:"poll CodeRabbit"}]}')" \
  0 "-" STINGRAY_SHAPE3=1 "${CLAIMS[@]}"

# 19. Without a key shape 3 does not run, and says so once per session. It used
#     to run its count locally with no key at all; it is judged by Jev now, like
#     every other check. The correspondence judgement lives in network.sh.
check "19 unrelated task, no key → pass" \
  "$(mk "$WATCH_PLAIN" '[{"id":"b1","type":"shell","status":"running","description":"build","command":"make"}]' sess-19)" \
  0 "no key" STINGRAY_SHAPE3=1 "${OFFLINE[@]}"

# 11. Block budget, independent of stop_hook_active. Feed the same blocking
#     case four times with stop_hook_active pinned false, as if the harness
#     guard had been reset; the fourth must refuse to block.
echo "  -- block budget --"
BUDGET_STATE="$TMP/budget"; rm -rf "$BUDGET_STATE"
for i in 1 2 3 4; do
  err="$TMP/b.$i"
  ( export STINGRAY_STATE_DIR="$BUDGET_STATE" STINGRAY=1 STINGRAY_SHAPE3=1 "${CLAIMS[@]}"
    printf '%s' "$(mk "$WATCH_PLAIN" '[]')" | "$HOOK_SH" "$HOOK" >/dev/null 2>"$err" )
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

# ── Language ──────────────────────────────────────────────────────────────────
# Jev judges the language, so offline the only thing to test is whether it is
# asked. The probe is a key with an unreachable endpoint: a turn that is asked
# about prints the network marker, and a turn that is not leaves stderr empty.
# The answer itself, and the request body, are tested in network.sh.
CFG_ZH="$TMP/cfg-zh"; CFG_NONE="$TMP/cfg-none"; mkdir -p "$CFG_ZH" "$CFG_NONE"
printf '{"language":"zh-TW"}\n' >"$CFG_ZH/settings.json"
printf '{}\n' >"$CFG_NONE/settings.json"
ASKS=(TYPESAFE_API_KEY=would-be-used-if-reached STINGRAY_ENDPOINT=http://127.0.0.1:1/unreachable HOME="$TMP/nohome")
ENGLISH='Done. I changed the timeout in the config and ran the whole suite, and every case passed on both runners, so the branch is ready for review whenever you are.'
CHINESE='改好了。我把設定檔裡的 timeout 調整過，整套測試在 macOS 與 ubuntu 兩邊都通過，這個分支可以送審了。'
CODE='const retries = readConfig().network.retries ?? defaultRetries; for (const attempt of range(retries)) { const response = await fetch(endpoint, { method: "POST", body: payload, signal: controller.signal }); if (response.ok) return parse(response); await sleep(backoff(attempt)); } throw new Error("request failed after every retry");'

# L01. A reply with prose is asked about — any reply, not only a foreign one.
#     That is what STINGRAY_LANG now costs: this turn's redacted final message
#     leaves the machine for one question, as it does for shapes 1 and 2.
check "L01 zh-TW reply with prose → asked" "$(mk "$CHINESE" '[]' sess-L01)" 0 "network/timeout" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"

# L02. No language configured, nothing to ask about.
check "L02 no language set → not asked" "$(mk "$ENGLISH" '[]' sess-L02)" 0 "-" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_NONE" "${ASKS[@]}"

# L03. Without a key the check does not run, and says so once per session.
check "L03 no key → not asked, marker shown" "$(mk "$ENGLISH" '[]' sess-L03)" 0 "no key" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${OFFLINE[@]}"

# L04. A line of results has no prose to judge. Asked anyway, Jev scored this
#     shape at 0.94 "not Chinese", which is true and useless.
check "L04 results line without prose → not asked" \
  "$(mk 'acceptance 49/0, network 10/0, mutants 4/0, fixture 44/0.' '[]' sess-L04)" 0 "-" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"

# L05–L06. Code is not prose. A two-character reply around a large block of
#     English code has nothing to judge, however the block is fenced; counting
#     the code would clear the floor and send it.
TILDE="$(printf '%s\n~~~js\n%s\n~~~\n' '好了。' "$CODE")"
check "L05 short reply around a ~~~ block → not asked" "$(mk "$TILDE" '[]' sess-L05)" 0 "-" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"
# The block has a blank line inside it, so only the fence rule can remove it:
# the inline-code rule stops at a blank line, and without one it removed this
# block by itself and the case could not tell whether the fence rule worked.
LONGFENCE="$(printf '%s\n````md\n```js\n%s\n\n%s\n```\n````\n' '好了。' "$CODE" "$CODE")"
check "L06 short reply around a \`\`\`\` block → not asked" "$(mk "$LONGFENCE" '[]' sess-L06)" 0 "-" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"

# L07–L09. Every script counts toward the floor. The first version counted only
#     Han and English words, so a Korean or Russian reply measured as nothing and
#     would never have been asked about — the same blind spot the local rule had.
check "L07 Korean reply → asked" \
  "$(mk '설정을 변경하고 전체 테스트를 실행했습니다. 두 플랫폼 모두 통과했으니 리뷰를 요청해도 됩니다.' '[]' sess-L07)" 0 "network/timeout" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"
check "L08 Russian reply → asked" \
  "$(mk 'Я изменил настройки и запустил все тесты, оба окружения прошли успешно, можно отправлять на ревью.' '[]' sess-L08)" 0 "network/timeout" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"
check "L09 Japanese reply → asked" \
  "$(mk '設定を変更して全テストを実行しました。両方の環境で成功したので、レビューに出せます。' '[]' sess-L09)" 0 "network/timeout" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${ASKS[@]}"

# L10. LANG alone does not switch shape 3 on: a watch promise with nothing
#     running is not blocked, and nothing is recorded for shape 3. The no-key
#     marker is expected — the language question is wanted and has no key.
check "L10 LANG alone leaves shape 3 off → pass" "$(mk "$WATCH_PLAIN" '[]' sess-L10)" 0 "no key" \
  STINGRAY_LANG=1 CLAUDE_CONFIG_DIR="$CFG_ZH" "${OFFLINE[@]}"
if jq -e 'select(.session=="sess-L10")' "$TMP/state/decisions.jsonl" >/dev/null 2>&1; then
  fail=$((fail+1)); printf '  FAIL  L10.1 shape 3 recorded a decision with only LANG on\n'
else
  pass=$((pass+1)); printf '  ok    L10.1 nothing recorded for shape 3\n'
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
