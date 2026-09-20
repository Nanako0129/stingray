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
for i in $(seq 0 $((count - 1))); do
  msg=$(jq -r ".[$i]" "$TMP/messages")
  jq -cn --arg m "$msg" --arg cwd "$PWD" '{
    session_id: "payload-audit", prompt_id: "00000000-0000-0000-0000-000000000000",
    transcript_path: "/nonexistent/t.jsonl", cwd: $cwd, permission_mode: "default",
    hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: $m, background_tasks: [], session_crons: []
  }' | ( export STINGRAY_STATE_DIR="$TMP/state" STINGRAY_SHADOW=1 \
                TYPESAFE_API_KEY=local-stub \
                STINGRAY_ENDPOINT="http://127.0.0.1:$PORT/v1/systemone"
         bash "$HOOK" >/dev/null 2>&1 )
done

sent=$(wc -l <"$TMP/captured" 2>/dev/null | tr -d ' ')
echo "captured $sent request(s)"
[ "${sent:-0}" -gt 0 ] || { echo "nothing was sent"; exit 0; }

OUT="${STINGRAY_PAYLOAD_OUT:-$PWD/payload-audit.txt}"
jq -r '.questions | to_entries[0].value.instructions
       | "──────────\nfinal_text:\n\(.final_text)\n\ntools: \(.tools)\nbackground: \(.background)"' \
   "$TMP/captured" >"$OUT"
echo "full captured payloads written to $OUT  (not tracked by git)"
echo
jq -r '.questions | to_entries[0].value.instructions.final_text' "$TMP/captured" >"$TMP/texts"
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
