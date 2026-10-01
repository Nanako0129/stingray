#!/usr/bin/env bash
# Check that Grok plugin installation selects the Grok adapter, then exercise
# that adapter against the local Jev stand-in without a real key. HOME, GROK_HOME
# and TMPDIR are temporary; every fixture is synthetic.
#
#   GROK_HOOK_MUTANT=<name> bash tests/grok-hook.sh
#
# runs the suite against a copy with one guard removed, and must then fail:
# deny (denylist never read), background (command line kept), questions
# (STINGRAY_QUESTIONS passed on), anchor (no start reads as "no tools"), ups
# (UserPromptSubmit runs the adapter).
set -euo pipefail

for v in ${!STINGRAY@} TYPESAFE_API_KEY GROK_PLUGIN_DATA XDG_STATE_HOME CLAUDE_CONFIG_DIR; do
  unset "$v"
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "grok-hook: missing $tool" >&2; exit 1; }
done

tmp=$(mktemp -d)
stubs=()
cleanup() {
  for p in ${stubs[@]+"${stubs[@]}"}; do kill "$p" 2>/dev/null || true; done
  chmod -R u+rwx "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
die() { echo "grok-hook: $*" >&2; exit 1; }

# The tree under test: the repository, or a copy with one guard removed.
R=$ROOT
mutate() {  # mutate <file> <anchor> <replacement>; the anchor must be present
  ANCHOR="$2" REPLACEMENT="$3" python3 - "$R/$1" <<'PY' || exit 3
import os, pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
anchor, replacement = os.environ["ANCHOR"], os.environ["REPLACEMENT"]
if anchor not in text:
    sys.exit(f"grok-hook: mutant anchor not found: {anchor!r}")
path.write_text(text.replace(anchor, replacement, 1))
PY
}
if [ -n "${GROK_HOOK_MUTANT:-}" ]; then
  R="$tmp/root"
  mkdir -p "$R"
  cp -R "$ROOT/.claude-plugin" "$ROOT/.grok-plugin" "$ROOT/hooks" "$ROOT/questions.json" "$R/"
  # shellcheck disable=SC2016  # the anchors are literal source text
  case "$GROK_HOOK_MUTANT" in
    deny) mutate hooks/stingray-grok.sh 'deny="$deny/stingray-deny"' 'deny="$deny/stingray-deny.mutant"' ;;
    background) mutate hooks/stingray-grok.sh '{status, description: "\(.type) task"}' '{status, description}' ;;
    questions) mutate hooks/stingray-grok.sh 'unset STINGRAY_QUESTIONS' ':' ;;
    anchor) mutate hooks/stingray-grok.sh '| select(.s) | .n' '| .n' ;;
    ups) mutate hooks/hooks.grok.json "\"/bin/sh -c 'cat >/dev/null'\"" \
           '"/bin/bash \"${GROK_PLUGIN_ROOT}/hooks/stingray-grok.sh\""' ;;
    *) echo "grok-hook: unknown mutant $GROK_HOOK_MUTANT" >&2; exit 3 ;;
  esac
  echo "grok-hook: mutant $GROK_HOOK_MUTANT"
fi
ADAPTER="$R/hooks/stingray-grok.sh"

# ── Manifest and hook registration ───────────────────────────────────────────
version=$(jq -r .version "$R/.claude-plugin/plugin.json")
jq -e --arg version "$version" '
  .name == "stingray" and .version == $version and
  .hooks == "./hooks/hooks.grok.json" and
  (.description | type == "string" and length > 0)
' "$R/.grok-plugin/plugin.json" >/dev/null || die "manifest name, version or hooks path"

# Grok must not fall back to Claude's hooks/hooks.json. UserPromptSubmit is a
# no-op that only makes Grok log the turn-start record; it is not the adapter.
jq -e '
  (.hooks | keys) == ["Stop", "UserPromptSubmit"] and
  (.hooks.Stop[0].hooks[0] |
    .type == "command" and .timeout == 10 and
    .command == "/bin/bash \"${GROK_PLUGIN_ROOT}/hooks/stingray-grok.sh\"") and
  (.hooks.UserPromptSubmit[0].hooks[0] |
    .type == "command" and .timeout == 5 and
    .command == "/bin/sh -c '"'"'cat >/dev/null'"'"'")
' "$R/hooks/hooks.grok.json" >/dev/null || die "hooks.grok.json shape (UserPromptSubmit must not run the adapter)"

# ── Isolated environment and loopback stubs ──────────────────────────────────
export HOME="$tmp/home" GROK_HOME="$tmp/grok" TMPDIR="$tmp/tmp"
export STINGRAY_STATE_DIR="$tmp/state"
mkdir -p "$HOME" "$GROK_HOME" "$TMPDIR" "$tmp/fx"

stub() {  # stub <mode> <name> [capture file]; the port goes to $tmp/<name>.port
  python3 "$ROOT/tests/stub_server.py" "$1" "$tmp/$2.port" ${3:+"$3"} &
  stubs+=($!)
  for _ in $(seq 1 50); do [ -s "$tmp/$2.port" ] && break; sleep 0.1; done
  [ -s "$tmp/$2.port" ] || die "stub $1 did not start"
}
CAP="$tmp/captured"
: >"$CAP"
stub record rec "$CAP"
REC="http://127.0.0.1:$(cat "$tmp/rec.port")/v1/systemone"
stub claimonly claim
CLAIM="http://127.0.0.1:$(cat "$tmp/claim.port")/v1/systemone"

# run <endpoint> <payload> [env args ...]; sets rc and writes $tmp/out, $tmp/err.
# Refuses anything but a loopback endpoint, so no case can reach a real service.
run() {
  local ep=$1 p=$2 a; shift 2
  case "$ep" in http://127.0.0.1:[0-9]*/*) ;; *) die "refusing non-loopback endpoint '$ep'" ;; esac
  for a in "$@"; do case "$a" in STINGRAY_ENDPOINT=*) die "endpoint override in a case" ;; esac; done
  rc=0
  printf '%s' "$p" | env "$@" STINGRAY_ENDPOINT="$ep" TYPESAFE_API_KEY=dummy \
    /bin/bash "$ADAPTER" >"$tmp/out" 2>"$tmp/err" || rc=$?
}
sent() { wc -l <"$CAP" | tr -d ' '; }
body() { tail -n 1 "$CAP"; }
quiet() { [ "$rc" = 0 ] && [ ! -s "$tmp/out" ]; }

WS="$HOME/work/quokkaproj"
DEN="$HOME/work/denied"
mkdir -p "$WS" "$DEN/sub" "$DEN-x" "$HOME/work/slashy" "$HOME/work/crlf" \
  "$HOME/work/real1" "$HOME/work/real2" "$HOME/work/other"
ln -s real1 "$HOME/work/link1"
ln -s real2 "$HOME/work/link2"
printf '%s\n' "# one absolute path per line" "$DEN" "$HOME/work/slashy/" \
  "$HOME/work/link1" "$HOME/work/real2" "$HOME/work/crlf"$'\r' >"$GROK_HOME/stingray-deny"

PID=prompt-0001
TP=""
MSG="I updated the quokkaproj configuration and reran the checks; everything passes now."
pl() {  # pl [jq filter]; a Grok stop payload
  jq -nc --arg ws "$WS" --arg tp "$TP" --arg m "$MSG" --arg pid "$PID" '
    {hookEventName: "stop", reason: "end_turn", sessionId: "sess-0001", promptId: $pid,
     cwd: $ws, workspaceRoot: $ws, permissionMode: "default", stopHookActive: false,
     transcriptPath: $tp, lastAssistantMessage: $m, backgroundTasks: [], sessionCrons: []}
    | '"${1:-.}"
}

# Grok updates.jsonl records: the turn-start hook record and a tool_call.
ups() {
  jq -nc --arg p "$1" '{method: "_x.ai/session/update", params: {sessionId: "sess-0001",
    update: {sessionUpdate: "hook_execution", event_name: "user_prompt_submit", prompt_id: $p}}}'
}
tc() {  # tc <promptId|-> <tool name>
  jq -nc --arg p "$1" --arg n "$2" '{method: "session/update", params: {sessionId: "sess-0001",
    update: {sessionUpdate: "tool_call", toolCallId: "call-1", title: "title-CANARY",
      _meta: {"x.ai/tool": {name: $n}}},
    _meta: (if $p == "-" then {} else {promptId: $p} end)}}'
}
other() { ups prompt-other; tc prompt-other other_before; }
turn() { tc "$PID" search_replace; tc "$PID" run_terminal_command; tc "$PID" use_tool; tc - web_search; }
{ other; ups "$PID"; turn; } >"$tmp/fx/full.jsonl"
{ other; ups "$PID"; } >"$tmp/fx/anchor-only.jsonl"
{ other; turn; } >"$tmp/fx/no-anchor.jsonl"
other >"$tmp/fx/no-pid.jsonl"
FOUR="4 call(s): run_terminal_command, search_replace, use_tool, web_search"
UNAV="tool list for this turn unavailable"
SHADOW=(STINGRAY_SHADOW=1)

# ── Tool list ────────────────────────────────────────────────────────────────
tools_case() {  # tools_case <fixture> <expected tools> <label>
  local before; before=$(sent)
  TP="$tmp/fx/$1" run "$REC" "$(TP="$tmp/fx/$1" pl)" "${SHADOW[@]}"
  quiet && [ "$(sent)" = $((before + 1)) ] || die "$3: not sent (rc=$rc)"
  local t; t=$(body | jq -r '.questions.no_action.instructions.tools')
  [ "$t" = "$2" ] || die "$3: tools '$t', expected '$2'"
}
tools_case full.jsonl "$FOUR" "anchor, other turn's tools before it"
tools_case anchor-only.jsonl "no tools were called" "anchor with no tool_call"
tools_case no-anchor.jsonl "$FOUR" "anchor removed, tool_calls kept"
tools_case no-pid.jsonl "$UNAV" "no record carries this promptId"

# The working directory's name is masked, not sent.
TP="$tmp/fx/full.jsonl" run "$REC" "$(TP="$tmp/fx/full.jsonl" pl)" "${SHADOW[@]}"
body | grep -qF '<project>' || die "project name was not masked"
! body | grep -q quokkaproj || die "project name was sent"
! body | grep -q CANARY || die "tool_call title was sent"

# ── Not sent: other events, other stop reasons, bad ids ──────────────────────
not_sent() {  # not_sent <label> <payload> [VAR=value ...]
  local label=$1 p=$2 before; shift 2
  before=$(sent)
  run "$REC" "$p" "$@" "${SHADOW[@]}"
  quiet && [ "$(sent)" = "$before" ] || die "$label: sent or not quiet (rc=$rc)"
}
is_sent() {  # is_sent <label> <payload> [VAR=value ...]
  local label=$1 p=$2 before; shift 2
  before=$(sent)
  run "$REC" "$p" "$@" "${SHADOW[@]}"
  quiet && [ "$(sent)" = $((before + 1)) ] || die "$label: not sent (rc=$rc)"
}
not_sent "user_prompt_submit event" "$(pl '.hookEventName = "user_prompt_submit"')"
not_sent "pre_tool_use event" "$(pl '.hookEventName = "pre_tool_use" | del(.promptId)')"
not_sent "session-end stop" "$(pl '.reason = "shutdown"')"
not_sent "sessionId with a path" "$(pl '.sessionId = "../x"')"
is_sent "auto-wake promptId" "$(pl '.promptId = "task-completed-0001"')"

# ── Denylist ─────────────────────────────────────────────────────────────────
at() { pl ".workspaceRoot = \"$1\" | .cwd = \"${2:-$1}\""; }
not_sent "denied exact" "$(at "$DEN")"
not_sent "denied subtree" "$(at "$DEN/sub")"
is_sent "sibling of a denied path" "$(at "$DEN-x")"
not_sent "entry with a trailing slash" "$(at "$HOME/work/slashy")"
not_sent "root through a denied symlink" "$(at "$HOME/work/real1")"
not_sent "symlink root to a denied path" "$(at "$HOME/work/link2")"
not_sent "entry with CRLF" "$(at "$HOME/work/crlf")"
not_sent "cwd-only match" "$(at "$WS" "$DEN/sub")"
mkdir -p "$tmp/g-unread" "$tmp/g-dir/stingray-deny" "$HOME/.grok"
: >"$tmp/g-unread/stingray-deny"
chmod 000 "$tmp/g-unread/stingray-deny"
if [ ! -r "$tmp/g-unread/stingray-deny" ]; then
  not_sent "unreadable deny file" "$(at "$WS")" GROK_HOME="$tmp/g-unread"
fi
not_sent "deny path is a directory" "$(at "$WS")" GROK_HOME="$tmp/g-dir"
printf '%s\n' "$HOME/work/other" >"$HOME/.grok/stingray-deny"
not_sent "default deny file under HOME" "$(at "$HOME/work/other")" -u GROK_HOME
is_sent "missing deny file" "$(at "$HOME/work/other")" GROK_HOME="$tmp/g-none"

# ── Background tasks and STINGRAY_QUESTIONS ──────────────────────────────────
is_sent "background task" "$(pl '.backgroundTasks = [{id: "b-1", type: "monitor",
  status: "running", description: "poll-ci-loop --interval 30"}]')"
! body | grep -q poll-ci-loop || die "a background command line was sent"
body | grep -qF 'running: monitor task' || die "background task status was not sent"

jq '. + {grok_canary: (.no_action)}' "$R/questions.json" >"$tmp/canary.json"
is_sent "STINGRAY_QUESTIONS set" "$(pl)" STINGRAY_QUESTIONS="$tmp/canary.json"
body | jq -e '.questions | has("no_action")' >/dev/null || die "questions missing"
! body | grep -q grok_canary || die "STINGRAY_QUESTIONS reached stingray"

# ── Shape 3: block pass-through, and a cron counts as running ────────────────
WATCH="I'll keep monitoring the CI build until it finishes."
run "$CLAIM" "$(MSG=$WATCH pl '.sessionId = "sess-block"')" STINGRAY_SHAPE3=1
if ! { [ "$rc" = 2 ] && [ ! -s "$tmp/out" ] && head -c 9 "$tmp/err" | grep -qx 'stingray:'; }; then
  die "block did not pass through (rc=$rc)"
fi
run "$CLAIM" "$(MSG=$WATCH pl '.sessionId = "sess-cron" | .sessionCrons = [{id: "c-1",
  schedule: "every 5 minutes", recurring: true, prompt: "check the build"}]')" STINGRAY_SHAPE3=1
quiet || die "a turn with a cron was blocked (rc=$rc)"
jq -e 'select(.session == "sess-cron" and .shape == "watch_ok")' "$tmp/state/decisions.jsonl" \
  >/dev/null || die "a cron was not counted as running"

# ── What stingray.sh receives ────────────────────────────────────────────────
# A stand-in records its stdin and environment, writes to stdout (which must not
# reach Grok) and exits 7 with a line on stderr (both must pass through).
mkdir -p "$tmp/cap/hooks"
cp "$ADAPTER" "$tmp/cap/hooks/"
cat >"$tmp/cap/hooks/stingray.sh" <<EOF
cat >"$tmp/cap/payload"
printf '%s\n' "\${STINGRAY_QUESTIONS-unset}" "\${STINGRAY_STATE_DIR-unset}" >"$tmp/cap/env"
tp=\$(jq -r .transcript_path "$tmp/cap/payload")
if [ -f "\$tp" ]; then cp "\$tp" "$tmp/cap/transcript"; else rm -f "$tmp/cap/transcript"; fi
echo '{"decision":"approve"}'
echo "fake-stderr" >&2
exit 7
EOF
cap() {  # cap <payload> [VAR=value ...]
  local p=$1; shift
  rc=0
  printf '%s' "$p" | env "$@" /bin/bash "$tmp/cap/hooks/stingray-grok.sh" >"$tmp/out" 2>"$tmp/err" || rc=$?
}
TP="$tmp/fx/full.jsonl"
cap "$(pl '.backgroundTasks = [{type: "shell", status: "done", description: "x"}]
  | .sessionCrons = [{id: "c-1", prompt: "p"}]')" -u STINGRAY_STATE_DIR \
  GROK_PLUGIN_DATA="$tmp/plugin-data" STINGRAY_QUESTIONS="$tmp/canary.json"
[ "$rc" = 7 ] && [ ! -s "$tmp/out" ] && [ "$(cat "$tmp/err")" = fake-stderr ] ||
  die "stdout, stderr or exit code not handled (rc=$rc)"
[ "$(cat "$tmp/cap/env")" = "unset
$tmp/plugin-data" ] || die "child env: $(tr '\n' ' ' <"$tmp/cap/env")"
jq -e --arg ws "$WS" --arg tp "$TP" --arg m "$MSG" '
  .transcript_path != $tp and (.transcript_path | test("/stingray-grok\\.[^/]+$")) and
  del(.transcript_path) == {session_id: "sess-0001", prompt_id: "prompt-0001", cwd: $ws,
    permission_mode: "default", hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: $m,
    background_tasks: [{status: "done", description: "shell task"}],
    session_crons: [{id: "c-1", prompt: "p"}]}
' "$tmp/cap/payload" >/dev/null || die "payload map: $(cat "$tmp/cap/payload")"
[ -s "$tmp/cap/transcript" ] || die "turn transcript was not written"

TP="$tmp/fx/no-pid.jsonl"
cap "$(pl 'del(.backgroundTasks)')" STINGRAY_STATE_DIR="$tmp/explicit"
[ "$(sed -n 2p "$tmp/cap/env")" = "$tmp/explicit" ] || die "STINGRAY_STATE_DIR was overridden"
jq -e '.transcript_path == "/dev/null/no-transcript" and .background_tasks == null' "$tmp/cap/payload" \
  >/dev/null || die "no-start payload: $(cat "$tmp/cap/payload")"
[ ! -e "$tmp/cap/transcript" ] || die "a transcript was written with no start"

for f in "$TMPDIR"/stingray-grok.*; do
  [ ! -e "$f" ] || die "temporary transcript left behind: $f"
done

echo "grok-hook: OK (v$version)"
