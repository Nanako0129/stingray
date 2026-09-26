#!/usr/bin/env bash
# Check that Git marketplace installation selects the Codex adapter, then
# exercise that adapter against the local Jev stand-in without a real key.
set -euo pipefail

unset STINGRAY STINGRAY_SHADOW STINGRAY_LANG
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "codex-hook: missing $tool" >&2; exit 1; }
done

version=$(jq -r .version "$ROOT/.claude-plugin/plugin.json")
jq -e --arg version "$version" '
  .name == "stingray" and .version == $version and
  .hooks == "./hooks/hooks.codex.json" and
  (.description | type == "string" and length > 0)
' "$ROOT/.codex-plugin/plugin.json" >/dev/null

# Codex must not fall back to Claude's hooks/hooks.json. The explicit path in
# the Codex manifest overrides default hook discovery for this plugin.
jq -e '
  .hooks.Stop[0].hooks[0] |
  .type == "command" and
  .command == "/bin/bash \"${PLUGIN_ROOT}/hooks/stingray-codex.sh\"" and
  .commandWindows == "sh.exe \"${PLUGIN_ROOT}/hooks/stingray-codex.sh\""
' "$ROOT/hooks/hooks.codex.json" >/dev/null
[ ! -e "$ROOT/plugin.json" ] || { echo "codex-hook: root plugin.json overrides compatibility manifest" >&2; exit 1; }

tmp=$(mktemp -d)
cleanup() {
  [ -z "${stub_pid:-}" ] || kill "$stub_pid" 2>/dev/null || true
  [ -z "${allow_stub_pid:-}" ] || kill "$allow_stub_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

python3 "$ROOT/tests/stub_server.py" claimonly "$tmp/port" &
stub_pid=$!
for _ in $(seq 1 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
[ -s "$tmp/port" ] || { echo "codex-hook: stub did not start" >&2; exit 1; }
export STINGRAY_STATE_DIR="$tmp/state" STINGRAY_SHAPE3=1 TYPESAFE_API_KEY=dummy
export STINGRAY_ENDPOINT="http://127.0.0.1:$(cat "$tmp/port")/v1/systemone"

payload() {
  jq -cn --arg msg "$1" --argjson background "$2" '{
    session_id: "codex-hook-test", turn_id: "turn-1", transcript_path: null,
    cwd: "/tmp", hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: $msg
  } + (if $background == null then {} else {background_tasks: $background, session_crons: []} end)'
}

# Absent background state is unknown: no false "nothing is running" block.
out=$(payload "I'll keep monitoring the CI build until it finishes." null |
  bash "$ROOT/hooks/stingray-codex.sh")
[ -z "$out" ] || { echo "codex-hook: missing background state was treated as empty" >&2; exit 1; }

out=$(payload "I'll keep monitoring the CI build until it finishes." '[]' |
  bash "$ROOT/hooks/stingray-codex.sh")
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("stopped half-done"))' >/dev/null

# Codex supplies PLUGIN_DATA as a native Windows path. The adapter must convert
# it before shell tools use it, while still reaching the blocking decision.
windows_data="$tmp/windows-plugin-data"
out=$(payload "I'll keep monitoring the CI build until it finishes." '[]' |
  env -u STINGRAY_STATE_DIR PLUGIN_DATA='C:\Codex\plugins\data\stingray' \
    POSIX_PLUGIN_DATA="$windows_data" bash -c '
      uname() { echo MINGW64_NT-10.0; }
      cygpath() { printf "%s\n" "$POSIX_PLUGIN_DATA"; }
      mktemp() {
        [ "${TMPDIR:-}" = "$POSIX_PLUGIN_DATA" ] || return 1
        command mktemp "$@"
      }
      . "$1"
    ' _ "$ROOT/hooks/stingray-codex.sh")
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("stopped half-done"))' >/dev/null
[ -s "$windows_data/decisions.jsonl" ] || {
  echo "codex-hook: Windows plugin-data path was not used" >&2; exit 1; }

# A finished report with known background state must pass through with no
# response. The hook fails open, so empty output alone would also pass if the
# request never happened: require that it reached the stub and was scored.
python3 "$ROOT/tests/stub_server.py" record "$tmp/allow-port" "$tmp/allow-captured" &
allow_stub_pid=$!
for _ in $(seq 1 50); do
  [ -s "$tmp/allow-port" ] && break
  sleep 0.1
done
[ -s "$tmp/allow-port" ] || { echo "codex-hook: allow stub did not start" >&2; exit 1; }
export STINGRAY_ENDPOINT="http://127.0.0.1:$(cat "$tmp/allow-port")/v1/systemone"
export STINGRAY_STATE_DIR="$tmp/allow-state"
out=$(payload "The CI build finished successfully; all checks passed." '[]' |
  bash "$ROOT/hooks/stingray-codex.sh")
[ -z "$out" ] || { echo "codex-hook: completed report was blocked" >&2; exit 1; }
[ -s "$tmp/allow-captured" ] || { echo "codex-hook: completed report was never sent" >&2; exit 1; }
jq -e 'select(.shape == "watch_none")' "$tmp/allow-state/decisions.jsonl" >/dev/null || {
  echo "codex-hook: completed report was not scored" >&2; exit 1; }

echo "codex-hook: OK (v$version)"
