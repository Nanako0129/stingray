#!/bin/bash
# Show exactly what stingray would send, by capturing the bytes the shipped hook
# really puts on the wire — against a local recording server, so nothing leaves
# the machine.
#
#   ./tests/show-payload.sh [N]       # default 20 of your own recent turns
#
# Run this before enabling the plugin. Reading a redaction function tells you
# what someone intended to remove; this tells you what is actually in the
# request. A separate copy of the redactor would drift from the shipped one —
# that drift is how a rule went missing while the docs still promised it.
#
# It also counts leak categories in the captured bytes. Treat those counts as a
# floor, never a clearance: they can only find categories someone thought of,
# and prose carries things nobody enumerated.
set -u
N="${1:-20}"
# Every case drives the hook with the environment it means to test. A shell
# that actually runs the plugin exports STINGRAY_* too, and those leak into the
# cases that deliberately set none — measured 2026-09-21: with STINGRAY=1 and
# STINGRAY_SHAPE3_JUDGE=1 exported, this suite reported 7 failures and
# network.sh 1, all spurious. Derive the list from the environment rather than
# spelling it out, so a switch added later is covered without editing this.
for v in $(env | sed -n 's/^\(STINGRAY[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/stingray.sh"
TMP="$(mktemp -d)"
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
trap '[ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

command -v jq >/dev/null || { echo "needs jq"; exit 1; }
[ -d "$PROJECTS" ] || { echo "no transcripts at $PROJECTS"; exit 1; }

python3 "$HERE/stub_server.py" record "$TMP/port" "$TMP/captured" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/port")

# Real closing messages from your own transcripts — the exact field the hook is
# handed as last_assistant_message.
python3 - "$PROJECTS" "$N" >"$TMP/messages" <<'PY'
import glob, json, os, sys
root, want = sys.argv[1], int(sys.argv[2])
out = []
for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl")),
                   key=os.path.getmtime, reverse=True):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    last = ""
    for line in lines:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") != "assistant":
            continue
        for b in (d.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                last = b["text"].strip()
    if len(last) > 120:
        out.append(last)
    if len(out) >= want:
        break
print(json.dumps(out, ensure_ascii=False))
PY

count=$(jq 'length' "$TMP/messages")
echo "driving the real hook with $count of your own closing messages..."
skipped=0
for i in $(seq 0 $((count - 1))); do
  msg=$(jq -r ".[$i]" "$TMP/messages")
  jq -cn --arg m "$msg" --arg cwd "$PWD" '{
    session_id: "payload-audit", prompt_id: "00000000-0000-0000-0000-000000000000",
    transcript_path: "/nonexistent/t.jsonl", cwd: $cwd, permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: $m, background_tasks: [], session_crons: []
  }' >"$TMP/stdin.$i"
  ( export STINGRAY_STATE_DIR="$TMP/state" STINGRAY_SHADOW=1 \
           TYPESAFE_API_KEY=local-stub \
           STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
    bash "$HOOK" <"$TMP/stdin.$i" >/dev/null 2>"$TMP/err.$i" )
  rc=$?
  # Exit status and stderr are the observable contract, so the audit asserts on
  # them rather than discarding them. A turn that drops out silently shrinks the
  # sample while the report still reads as complete.
  if [ "$rc" != 0 ]; then
    printf '  message %s: hook exited %s — %s\n' "$i" "$rc" "$(head -c 140 "$TMP/err.$i")"
    skipped=$((skipped+1))
  elif [ -s "$TMP/err.$i" ]; then
    # A fail-open marker is a legitimate outcome, but it means nothing was sent
    # for this turn, so say which turns are missing from the audit.
    printf '  message %s: not sent — %s\n' "$i" "$(head -c 140 "$TMP/err.$i")"
    skipped=$((skipped+1))
  fi
done
[ "$skipped" -eq 0 ] || echo "($skipped of $count message(s) produced no request; they are absent from the audit below)"

sent=$(wc -l <"$TMP/captured" 2>/dev/null | tr -d ' ')
echo "captured $sent request(s)"
[ "${sent:-0}" -gt 0 ] || { echo "nothing was sent"; exit 0; }

OUT="${STINGRAY_PAYLOAD_OUT:-$PWD/payload-audit.txt}"
# The whole request body, pretty-printed. Not a selected field: a regression
# that serialises file contents or tool arguments into some other key must show
# up here, and it cannot if the report only ever prints the keys someone
# expected to be populated.
jq -r '"──────────", .' "$TMP/captured" >"$OUT"
echo "full captured request bodies written to $OUT  (not tracked by git)"
echo
# Scan every byte that was transmitted, for the same reason.
cp "$TMP/captured" "$TMP/texts"
python3 - "$TMP/texts" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
cats = {
    "fenced code":   r"```",
    "absolute path": r"(?:/Users/|/private/|/home/|~/)[^\s\"'`,)]+",
    "relative path": r"\b[\w.-]+/[\w./-]+\.[A-Za-z0-9]{1,6}\b",
    "filename":      r"\b[\w-]+\.(?:rs|swift|py|ts|tsx|js|jsx|sh|json|toml|ya?ml|lock|md)\b",
    "URL":           r"https?://\S+",
    "commit SHA":    r"\b[0-9a-f]{7,40}\b",
    "issue/PR":      r"(?:#\d+|\bPR\s*\d+)",
    "line range":    r"\bL\d+[–\-]\d+\b",
}
print(f"{'category':<16}{'hits in sent bytes':>20}")
for name, pat in cats.items():
    print(f"{name:<16}{len(re.findall(pat, text)):>20}")
print(f"\n{len(text)} characters total across the captured payloads.")
print("A zero here means this category was not found. It does not mean the")
print("payload is free of private content — read the file above and decide.")
PY
