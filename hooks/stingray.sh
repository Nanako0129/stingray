#!/bin/bash
# stingray — a Claude Code Stop hook that pushes the model back to work when a
# turn stops half-done.
#
# Three failure shapes:
#   1 no_action        stopped without doing anything          -> judged by Jev
#   2 broken_promise   declared an action, tools don't cover it -> judged by Jev
#   3 unwatched        promised to watch CI/review, nothing is polling
#                                                              -> computed, no Jev
#
# Shape 3 is deliberately NOT sent to a model: both halves are exact values (a
# declaration regex and the hook's own background_tasks field). Turning a
# certainty into a probability is a downgrade.
#
# Stop hook contract, measured on Claude Code v2.1.278 (2026-09-21), not read
# off the docs — the docs are wrong on three counts:
#   · To block, exit 2 AND write the reason to *stderr*. A hookSpecificOutput
#     JSON object on stdout never reaches the model.
#   · stdin carries stop_hook_active (undocumented); it is true on re-entry,
#     so loop protection is built in.
#   · stdin carries no stop_reason / scratchpad_dir / effort (docs say it does).
#   · hooks.json without an explicit timeout defaults to 600s.
#
# Friction only ever goes up. Every failure path — no key, timeout, HTTP error,
# malformed response, low score — exits 0, leaving behaviour identical to not
# having this plugin installed. stingray must never make the model do less.
set -u

MODEL="${STINGRAY_JEV_MODEL:-jev-1.13.0}"
ENDPOINT="${STINGRAY_ENDPOINT:-https://api.typesafe.ai/v1/systemone}"
TIMEOUT="${STINGRAY_TIMEOUT:-6}"
TAU="${STINGRAY_TAU:-0.5}"
MAX_BLOCKS="${STINGRAY_MAX_BLOCKS:-3}"
STATE_DIR="${STINGRAY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/stingray}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUESTIONS="${STINGRAY_QUESTIONS:-$HERE/../questions.json}"

# ── Mode. Off by default: with no environment variable set, nothing happens. ──
MODE="off"
[ "${STINGRAY_SHADOW:-}" = "1" ] && MODE="shadow"
[ "${STINGRAY:-}" = "1" ] && MODE="active"
[ "$MODE" = "off" ] && exit 0

command -v jq >/dev/null 2>&1 || { echo "(stingray: unavailable — jq not found)" >&2; exit 0; }

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# ── Loop protection ───────────────────────────────────────────────────────────
# First guard: built into the harness. True when re-entering after a block.
[ "$(j '.stop_hook_active')" = "true" ] && exit 0

# Second guard, independent of the first. Should stop_hook_active ever be reset
# — by compaction, a subagent boundary, or some path nobody has observed — one
# session still blocks at most MAX_BLOCKS times. A single boolean is a single
# point of failure, and its failure direction is an infinite loop.
session=$(j '.session_id')
[ -n "$session" ] && [ "$session" != "null" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
count_file="$STATE_DIR/blocks-$session"
blocks=$(cat "$count_file" 2>/dev/null || echo 0)
case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
  echo "(stingray: block budget $MAX_BLOCKS reached for this session)" >&2
  exit 0
fi

last=$(j '.last_assistant_message')
[ -n "$last" ] && [ "$last" != "null" ] || exit 0

log() {   # log <shape> <score> <would_block>
  printf '%s\n' "$(jq -cn \
    --arg ts "$(date -u +%FT%TZ)" --arg s "$session" --arg m "$MODE" \
    --arg shape "$1" --arg score "$2" --arg wb "$3" --arg model "$MODEL" \
    --arg qh "${qset_hash:-}" --arg secs "${secs:-}" \
    '{ts:$ts,session:$s,mode:$m,shape:$shape,score:$score,would_block:$wb,
      model:$model,qset_hash:$qh,secs:$secs}')" >>"$STATE_DIR/decisions.jsonl" 2>/dev/null
}

# The only exit that blocks. The reason goes to stderr because stdout does not
# reach the model (measured, see header).
nudge() {  # nudge <shape description>
  echo "$((blocks + 1))" >"$count_file" 2>/dev/null
  cat >&2 <<EOF
stingray: this turn looks like it stopped half-done ($1).

If the user's earlier instruction already authorised it, finish it now before
ending the turn. If you are waiting on an external result (CI, a PR review),
launch the polling command in the background before ending the turn. If you
genuinely need a decision from the user, say which decision you are blocked on
rather than simply stopping.
EOF
  exit 2
}

# ── Shape 3: computed locally. No model call, no API key required. ────────────
# The declaration regex runs on the RAW message, before redaction and before
# truncation. Redaction exists only to shrink what leaves the machine, and it
# drops whole lines carrying a path or a filename — and a promise to watch
# something routinely shares its line with one ("I'll watch the CI on
# src/main.rs"). Measured, not assumed: a URL alone does NOT drop the line,
# because URLs are replaced in place; a path does. tests/acceptance.sh case 7
# uses a path for exactly that reason — a URL there would pass even against an
# implementation that (wrongly) matched on redacted text.
WATCH_RE='監看|監控|盯著|盯住|輪詢|持續追蹤|等 ?(CI|ci|review|Review|審查|CodeRabbit|Copilot|Codex)[^。]{0,12}(回來|完成|結果|綠)|poll(ing)?|keep (an eye on|watching|polling)|I.?ll (monitor|watch|poll)'
if printf '%s' "$last" | grep -qE "$WATCH_RE"; then
  # A missing background_tasks key must NOT be read as "nothing is running".
  # That would degrade shape 3 into "block whenever the regex matches", and a
  # positive-case test would still pass — the defect would only surface as a
  # wrong block in normal turns.
  if [ "$(printf '%s' "$input" | jq 'has("background_tasks")' 2>/dev/null)" = "true" ]; then
    running=$(printf '%s' "$input" | jq '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)
    case "$running" in ''|*[!0-9]*) running=-1 ;; esac
    if [ "$running" = "0" ]; then
      if [ "$MODE" = "active" ] && [ "${STINGRAY_SHAPE3:-}" = "1" ]; then
        log unwatched 1 true
        nudge "it promises to watch an external result, but nothing is running in the background"
      fi
      # Shadow, or active but shape 3 has not cleared its own bar: record only.
      log unwatched 1 false
    fi
  fi
fi

# ── Shapes 1 and 2: judged by Jev ─────────────────────────────────────────────
KEY="${TYPESAFE_API_KEY:-$(cat "$HOME/.config/typesafe/api_key" 2>/dev/null)}"
if [ -z "$KEY" ]; then
  marker="$STATE_DIR/nokey-$session"
  [ -f "$marker" ] || { echo "(stingray: unavailable — no key; shapes 1/2 skipped)" >&2; : >"$marker"; }
  exit 0
fi
[ -s "$QUESTIONS" ] || { echo "(stingray: unavailable — questions.json not found)" >&2; exit 0; }

# Redaction: keep prose, drop everything else. Order matters — blocks first,
# then whole lines, then single tokens. Truncation happens AFTER redaction: the
# other way round, taking the last N bytes cuts a code fence in half, the pair
# no longer matches, and the whole block leaks.
#
# Project names to mask. Derived, not hardcoded: the directory you are in and
# the repository the remote points at. STINGRAY_REDACT_WORDS adds any others
# (comma separated) — sibling projects you happen to mention by name are not
# discoverable from here, so that list is the only way to cover them.
hook_cwd=$(j '.cwd')
names="$(basename "${hook_cwd:-}" 2>/dev/null)"
if [ -d "${hook_cwd:-}" ]; then
  origin=$(git -C "$hook_cwd" remote get-url origin 2>/dev/null)
  [ -n "$origin" ] && names="$names,$(basename "${origin%.git}")"
fi
[ -n "${STINGRAY_REDACT_WORDS:-}" ] && names="$names,$STINGRAY_REDACT_WORDS"

# Known ceiling, measured on 50 real messages through this exact pipeline rather
# than assumed: it does NOT reach "no private content". Line ranges into private
# files, internal component names, work-volume figures and third-party
# quotations survive. Project names other than the ones derived above survive.
# See README.
redacted=$(printf '%s' "$last" | perl -0777 -pe '
  s/```.*?```/ /gs;                      # fenced code blocks (paired)
  s/^\s*>.*$/ /mg;                       # block quotes
  s/`[^`\n]{1,200}`/ /g;                 # inline code
  s{https?://\S+|www\.\S+}{ }g;          # URLs (replaced in place, line survives)
' | perl -ne '
  next if m{(?:/Users/|/private/|/home/|~/|[A-Za-z]:\\)[^\s"'"'"'`,)]+};  # absolute paths
  next if m{\b[\w.-]+/[\w./-]+\.[A-Za-z0-9]{1,6}\b};                      # relative paths
  next if m{\b[\w-]+\.(?:rs|swift|py|ts|tsx|js|jsx|sh|json|toml|ya?ml|lock|md|c|h|cpp|go|rb|java|kt)\b};
  print;
' | perl -0777 -pe '
  s/\b[0-9a-f]{7,40}\b/ /g;              # commit SHAs
  s/(?:#\d+|\bPR\s*\d+|\bissue\s*\d+)/ /gi;
' | perl -0777 -pse '
  for my $w (grep { length > 2 } split /\s*,\s*/, ($n // "")) {
    my $q = quotemeta $w; s/\b$q\b/<project>/gi;
  }
  s/[ \t]{2,}/ /g; s/\n{3,}/\n\n/g;
' -- -n="$names")
redacted=$(printf '%s' "$redacted" | tail -c 2400)   # ~800 CJK characters

# Scan the outgoing bytes for secrets. On a hit, send nothing and behave as if
# the plugin were not installed.
if printf '%s' "$redacted" | grep -qE 'sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
  echo "(stingray: payload held — secret pattern in message)" >&2
  exit 0
fi
[ -n "$(printf '%s' "$redacted" | tr -d '[:space:]')" ] || exit 0

# Tool names for this turn, taken from the transcript. When they cannot be read,
# say so in the payload rather than inventing "no tools" — that value decides
# shape 1. See turn-tools.jq for why promptId cannot filter assistant records.
tools="tool list for this turn unavailable"
transcript=$(j '.transcript_path')
prompt_id=$(j '.prompt_id')
if [ -f "$transcript" ] && [ -f "$HERE/turn-tools.jq" ] && [ -n "$prompt_id" ]; then
  t=$(jq -rs --arg pid "$prompt_id" -f "$HERE/turn-tools.jq" "$transcript" 2>/dev/null)
  [ -n "$t" ] && tools="$t"
fi

# Only the statuses leave the machine — never a background task's description or
# command line.
bg_status=$(printf '%s' "$input" | jq -c '[.background_tasks[]?.status] // []' 2>/dev/null)
[ -n "$bg_status" ] || bg_status='[]'

body=$(jq -cn --arg m "$MODEL" --arg ft "$redacted" --arg tl "$tools" \
  --argjson bg "$bg_status" --slurpfile q "$QUESTIONS" '
  {model: $m,
   state: {source: "the end of one turn in a Claude Code transcript"},
   questions: ($q[0] | with_entries(
     .value.instructions += {final_text: $ft, tools: $tl, background: ($bg|tostring)}))}
') || exit 0

# The question set is part of the classifier's contract, so its hash is logged
# with every decision: changing one line of criteria moves the whole score
# distribution, and a threshold calibrated under the old wording is void.
qset_hash=$(printf '%s' "$body" | jq -cS '.questions' | shasum -a 256 | cut -c1-16)

out=$(mktemp) || exit 0
trap 'rm -f "$out"' EXIT
meta=$(curl -sS -o "$out" -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "$body" "$ENDPOINT" 2>/dev/null) || {
    echo "(stingray: unavailable — network/timeout)" >&2; exit 0; }
code=${meta%% *}; secs=${meta#* }
[ "$code" = "200" ] || { echo "(stingray: unavailable — HTTP $code)" >&2; exit 0; }

read -r na bp <<<"$(jq -r '[(.answers.no_action.noul // -1),
                            (.answers.broken_promise.noul // -1)] | @tsv' "$out" 2>/dev/null)"
case "$na$bp" in *[!0-9.\	-]*|'') echo "(stingray: unavailable — malformed response)" >&2; exit 0 ;; esac

fired=$(awk -v a="$na" -v b="$bp" -v t="$TAU" 'BEGIN{
  if (a >= t && a >= b) print "no_action";
  else if (b >= t) print "broken_promise";
}')
score=$(awk -v a="$na" -v b="$bp" 'BEGIN{print (a>b?a:b)}')

[ -n "$fired" ] || { log none "$score" false; exit 0; }

if [ "$MODE" = "active" ]; then
  log "$fired" "$score" true
  case "$fired" in
    no_action)       nudge "this turn did nothing at all" ;;
    broken_promise)  nudge "it declared an action that this turn's tool calls do not account for" ;;
  esac
fi
log "$fired" "$score" false
exit 0
