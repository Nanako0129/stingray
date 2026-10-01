#!/bin/bash
# Run the existing Stingray implementation with Grok's Stop payload. Grok's
# payload is camelCase, so it is mapped to the snake_case fields stingray.sh
# reads, and the turn's tool list is rebuilt from Grok's session log.
set -u

# Every failure path exits 0; only stingray's own exit code is passed on.
rc=0 tf=''
trap '[ -z "$tf" ] || rm -f -- "$tf"; exit "$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || {
  echo "(stingray: unavailable — jq not found)" >&2
  exit 0
}

input=$(cat)

# field <key> <var>: one string field, or empty. The trailing "." survives
# $(...), so a value ending in a newline cannot be trimmed into a valid one.
field() {
  local v
  v=$(printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty | strings | . + "."' 2>/dev/null)
  printf -v "$2" '%s' "${v%.}"
}
# valid_id <id>: 1-128 of [A-Za-z0-9_-]; stingray builds a file path from session_id.
valid_id() {
  case "$1" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

ev='' reason='' sid='' pid='' tp='' ws='' cwd=''
# hooks.grok.json registers a no-op on UserPromptSubmit only so that Grok logs
# the turn-start record the tool list below anchors on. Only Stop runs here.
field hookEventName ev
[ "$ev" = "stop" ] || exit 0
field reason reason
[ "$reason" = "end_turn" ] || exit 0
field sessionId sid
valid_id "$sid" || exit 0
field promptId pid
valid_id "$pid" || exit 0

# Denylist: one absolute path per line; the path and its subtree are skipped.
# Both sides are compared resolved (symlinks, case) and as written. A root that
# does not resolve, or a deny file that exists but cannot be read, sends nothing.
field workspaceRoot ws
field cwd cwd
[ -n "$ws$cwd" ] || exit 0
roots=()
for r in "$ws" "$cwd"; do
  [ -n "$r" ] || continue
  case "$r" in /*) ;; *) exit 0 ;; esac
  case "$r" in */../*|*/..|*"
"*) exit 0 ;; esac
  rr=$(CDPATH='' cd -P -- "$r" 2>/dev/null && /bin/pwd -P) || exit 0
  [ -n "$rr" ] || exit 0
  roots+=("$r" "$rr")
done
deny="${GROK_HOME:-${HOME:+$HOME/.grok}}"
[ -n "$deny" ] || exit 0
deny="$deny/stingray-deny"
if [ -e "$deny" ] || [ -L "$deny" ]; then
  [ -f "$deny" ] && [ -r "$deny" ] || exit 0
  { exec 3<"$deny"; } 2>/dev/null || exit 0
  while IFS= read -r line <&3 || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in /*) ;; *) continue ;; esac
    while [ "${line%/}" != "$line" ]; do line=${line%/}; done
    ent_r=$line
    if [ -n "$line" ]; then
      ent_r=$(CDPATH='' cd -P -- "$line" 2>/dev/null && /bin/pwd -P) || ent_r=$line
      while [ "${ent_r%/}" != "$ent_r" ]; do ent_r=${ent_r%/}; done
    fi
    for r in "${roots[@]}"; do
      for e in "$ent_r" "$line"; do
        case "$r" in "$e"|"$e"/*) exit 0 ;; esac
      done
    done
  done
  exec 3<&-
fi

# Tool list, as in turn-tools.jq. Grok's tool hooks carry no promptId, so the
# list comes from transcriptPath (the session's updates.jsonl): start = the
# first record carrying this promptId (the UserPromptSubmit hook record, or the
# turn's first tool_call); names = every tool_call from there to EOF. Streamed,
# as the file grows large. No start or a jq error leaves the list unavailable.
field transcriptPath tp
names=''
if [ -f "$tp" ]; then
  names=$(jq -nc --arg pid "$pid" '
    reduce inputs as $r ({s: false, n: []};
      .s = (.s or $r.params.update.prompt_id == $pid or $r.params._meta.promptId == $pid)
      | if .s and $r.params.update.sessionUpdate == "tool_call"
        then .n += [$r.params.update._meta["x.ai/tool"].name] else . end)
    | select(.s) | .n' "$tp" 2>/dev/null) || names=''
fi
# stingray reads the list from a Claude-shaped transcript, never Grok's file.
path=/dev/null/no-transcript
if [ -n "$names" ]; then
  tf=$(mktemp "${TMPDIR:-/tmp}/stingray-grok.XXXXXX" 2>/dev/null) || tf=''
  if [ -n "$tf" ] && jq -nc --arg p "$pid" --arg n "$names" '
      {type: "user", promptId: $p, message: {content: "grok turn"}},
      ($n | fromjson[] | {type: "assistant", message: {content: [{type: "tool_use", name: .}]}})' \
      >"$tf" 2>/dev/null; then
    path=$tf
  fi
fi

# A background task's description is its command line, which never leaves:
# only its type is kept. An absent backgroundTasks stays null (unknown).
payload=$(printf '%s' "$input" | jq -c --arg tp "$path" '
  {session_id: .sessionId, prompt_id: .promptId, transcript_path: $tp, cwd,
   permission_mode: .permissionMode, hook_event_name: "Stop",
   stop_hook_active: .stopHookActive, last_assistant_message: .lastAssistantMessage,
   background_tasks: (if (.backgroundTasks | type) == "array"
     then [.backgroundTasks[] | {status, description: "\(.type) task"}] else null end),
   session_crons: .sessionCrons}' 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Plugin state belongs outside the immutable install/cache directory.
if [ -n "${GROK_PLUGIN_DATA:-}" ] && [ -z "${STINGRAY_STATE_DIR:-}" ]; then
  export STINGRAY_STATE_DIR="$GROK_PLUGIN_DATA"
fi
unset STINGRAY_QUESTIONS
# Grok honours JSON on stdout over the exit code, so only stderr and rc pass.
printf '%s' "$payload" | /bin/bash "$HERE/stingray.sh" >/dev/null
rc=$?
exit "$rc"
