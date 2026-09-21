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
# Friction only ever goes up. Every failure path exits 0, leaving behaviour
# identical to not having this plugin installed; the only exit that blocks is
# nudge(). stingray must never make the model do less.
#
# The list of those paths lives in the README and is deliberately not repeated
# here: it was repeated once, went stale in this copy while the README stayed
# right, and a contract stated in two places is only as true as the copy nobody
# reread.
set -u

MODEL="${STINGRAY_JEV_MODEL:-jev-1.13.0}"
ENDPOINT="${STINGRAY_ENDPOINT:-https://api.typesafe.ai/v1/systemone}"
TIMEOUT="${STINGRAY_TIMEOUT:-6}"
TAU="${STINGRAY_TAU:-0.5}"
MAX_BLOCKS="${STINGRAY_MAX_BLOCKS:-3}"
# User input. A non-integer would make the later -ge test error out, and since
# that test is an if condition the hook would continue with no ceiling at all.
case "$MAX_BLOCKS" in ''|*[!0-9]*) MAX_BLOCKS=3 ;; esac
[ "$MAX_BLOCKS" -ge 1 ] 2>/dev/null || MAX_BLOCKS=3
STATE_DIR="${STINGRAY_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/stingray}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUESTIONS="${STINGRAY_QUESTIONS:-$HERE/../questions.json}"

# ── Mode. Off by default: with no environment variable set, nothing happens. ──
#
# Three switches, not one scale. Shape 3 needs no API key and no network, so it
# is usable entirely on its own — STINGRAY_SHAPE3=1 alone enables the hook and
# blocks on shape 3 without turning on the two Jev judgements, which have their
# own calibration bar to clear. Folding it into MODE=active would hand someone
# who asked for the free local check the two that cost money and are not yet
# calibrated.
#
# STINGRAY_SHADOW wins over both: shadow means record, never block.
MODE="off"
[ "${STINGRAY_SHAPE3:-}" = "1" ] && MODE="shape3"
[ "${STINGRAY:-}" = "1" ] && MODE="active"
[ "${STINGRAY_SHADOW:-}" = "1" ] && MODE="shadow"
[ "$MODE" = "off" ] && exit 0

# Shape 3 may block in active (with its own flag) or in shape3-only mode.
shape3_blocks=0
[ "${STINGRAY_SHAPE3:-}" = "1" ] && [ "$MODE" != "shadow" ] && shape3_blocks=1
# The Jev judgements may block only in active mode.
jev_blocks=0
[ "$MODE" = "active" ] && jev_blocks=1

command -v jq >/dev/null 2>&1 || { echo "(stingray: unavailable — jq not found)" >&2; exit 0; }

input=$(cat)
# Read one field out of the hook payload. Returns empty on any jq failure, so a
# missing field and an unreadable one are indistinguishable to the caller. Each
# caller below decides what to do with an empty value; several exit 0 there.
# That is a statement about those branches, not a measured claim about the turn.
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
  # If the budget cannot be recorded, do not block. An unrecorded block is an
  # unbounded one: on a re-entry where stop_hook_active is unavailable nothing
  # would count the rounds. Failing to write is a failure path like any other.
  printf '%s\n' "$((blocks + 1))" >"$count_file" 2>/dev/null || exit 0
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
# The waiting verb takes a suffix in real Chinese — 等著, 等待, 等到 — and the
# outcome word is not always one of the first four tried. Both gaps showed up on
# the very first live shadow run, on "我會等著 CodeRabbit 的審查結果" with nothing
# running in the background: shape 3 should have recorded it and did not.
# Broadening costs almost nothing, because the keyword list after the verb does
# the narrowing. Measured across 19,450 assistant messages from real
# transcripts: the old pattern matched 1,690 lines, the new one 1,699 — nine
# more, which is 0.5% more than the old pattern caught and 0.05% of all
# messages. Both numbers, because "+0.5%" on its own reads as a share of the
# 19,450 and would overstate it tenfold.
WATCH_RE='監看|監控|盯著|盯住|輪詢|持續追蹤|等(著|待|到)? ?(CI|ci|review|Review|審查|CodeRabbit|Copilot|Codex)[^。]{0,12}(回來|回覆|完成|跑完|出來|結果|綠)|poll(ing)?|keep (an eye on|watching|polling)|I.?ll (monitor|watch|poll)'
watch_claimed=0
watch_unresolved=0
if printf '%s' "$last" | grep -qE "$WATCH_RE"; then
  watch_claimed=1
  # Require an actual array. Neither a missing key nor a null may be read as
  # "nothing is running": has() is true for null, and [ .[]? ] over null counts
  # zero, so either would degrade shape 3 into "block whenever the regex
  # matches". A positive-case test still passes under that defect — it surfaces
  # only as a wrong block on ordinary turns, which is why mutants.sh covers it.
  if [ "$(printf '%s' "$input" | jq '(.background_tasks | type) == "array"' 2>/dev/null)" = "true" ]; then
    # Count scheduled work too. A cron polling the thing it promised to watch is
    # a kept promise, and session_crons went unread until a probe showed shape 3
    # blocking a turn whose cron was doing exactly the polling it asked for.
    running=$(printf '%s' "$input" | jq '
      ([.background_tasks[]? | select(.status=="running")] | length)
      + ((.session_crons // []) | length)' 2>/dev/null)
    case "$running" in ''|*[!0-9]*) running=-1 ;; esac
    if [ "$running" = "0" ]; then
      # Nothing at all is running or scheduled. No judgement is needed to know
      # the promise has no mechanism behind it, so this stays arithmetic and
      # needs neither a key nor the network.
      if [ "$shape3_blocks" = "1" ]; then
        log unwatched 1 true
        nudge "it promises to watch an external result, but nothing is running in the background"
      fi
      log unwatched 1 false
    elif [ "$running" -gt 0 ]; then
      # Something is running — but is it watching the thing that was promised?
      # Counting cannot answer that: a build running while the turn promised to
      # follow a PR review satisfies "something is running" and misses the
      # broken promise entirely. Correspondence is a judgement, so it is handed
      # to the Jev section below, which has the message and the work side by
      # side. Without a key that section exits and today's behaviour stands.
      watch_unresolved=1
    fi
  fi
fi

# ── Shapes 1 and 2: judged by Jev ─────────────────────────────────────────────
# Shape-3-only mode stops here: it skips the credential lookup and the request
# entirely. It does not skip the work above — stdin has been read and jq and
# grep have run — so this is not a zero-cost path, only a zero-request one.
# Without this exit a key sitting in ~/.config would send this turn's message
# anyway, and the switch would mean the opposite of what it says.
[ "$MODE" = "shape3" ] && exit 0

KEY="${TYPESAFE_API_KEY:-${HOME:+$(cat "$HOME/.config/typesafe/api_key" 2>/dev/null)}}"
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
# One redaction pipeline, used for every field that leaves. Written once on
# purpose: a second copy of a redactor already drifted from this one here and
# dropped a rule the README still promised.
redact_text() {
  perl -0777 -pe '
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
  ' -- -n="$names"
}

redacted=$(printf '%s' "$last" | redact_text)
redacted=$(printf '%s' "$redacted" | tail -c 2400)   # ~800 CJK characters

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
# What the background work IS, not just how much of it there is. Judging whether
# a promise to watch something is kept needs the two side by side: a build
# running while the turn promised to follow a PR review satisfies "something is
# running" and misses the broken promise entirely.
#
# This is more than the statuses that used to be sent. Descriptions and cron
# prompts are written by the model and carry project names and work detail, so
# they go through the same redaction as the message. Command lines are still
# never sent.
bg_text=$(printf '%s' "$input" | jq -r '
  [ (.background_tasks[]? | "\(.status): \(.description // "(no description)")"),
    ((.session_crons // [])[]? | "scheduled: \(.prompt // "(no prompt)")") ]
  | if length == 0 then "nothing running or scheduled" else join(" | ") end' 2>/dev/null)
[ -n "$bg_text" ] || bg_text="background list unavailable"
bg_text=$(printf '%s' "$bg_text" | redact_text | tr '\n' ' ')
[ -n "${bg_text// /}" ] || bg_text="background list unavailable"

# watch_mismatch is asked only when the turn claimed to watch something AND
# something is running: that is the one case counting cannot settle. Asking it
# otherwise would spend a question on a state the arithmetic already decided.
body=$(jq -cn --arg m "$MODEL" --arg ft "$redacted" --arg tl "$tools" \
  --arg bg "$bg_text" --argjson wm "$watch_unresolved" --slurpfile q "$QUESTIONS" '
  {model: $m,
   state: {source: "the end of one turn in a Claude Code transcript"},
   questions: ($q[0]
     | (if $wm == 1 then . else del(.watch_mismatch) end)
     | with_entries(
        .value.instructions += {final_text: $ft, tools: $tl, background: $bg}))}
') || exit 0

# Scan the exact bytes about to be transmitted, not one field of them. The body
# also carries tool names taken from the transcript, background statuses and the
# question text; scanning only the redacted message left those uncovered while
# the README claimed the outgoing bytes were scanned.
if printf '%s' "$body" | grep -qE 'sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
  echo "(stingray: payload held — secret pattern in outgoing request)" >&2
  exit 0
fi

# The question set is part of the classifier's contract, so its hash is logged
# with every decision: changing one line of criteria moves the whole score
# distribution, and a threshold calibrated under the old wording is void.
#
# Hash questions.json, NOT the request body. The body's questions carry this
# turn's final_text, tools and background, so hashing it yields a value that
# differs every turn — which cannot show a criteria edit, which is the only
# thing it exists to show.
qset_hash=$(jq -cS . "$QUESTIONS" | shasum -a 256 | cut -c1-16)

# The request carries Authorization: Bearer $KEY. Plain HTTP is allowed only to
# loopback, where the local test stubs live; anywhere else it would put the key
# on the wire in cleartext. STINGRAY_ENDPOINT is how that could happen, so the
# check sits here rather than in documentation.
case "$ENDPOINT" in
  https://*) ;;
  http://127.0.0.1[:/]*|http://localhost[:/]*|http://[::1][:/]*|http://127.0.0.1|http://localhost) ;;
  *) echo "(stingray: refusing to send credentials to a non-HTTPS, non-loopback endpoint)" >&2
     exit 0 ;;
esac

out=$(mktemp) || exit 0
trap 'rm -f "$out"' EXIT
meta=$(curl -sS -o "$out" -w '%{http_code} %{time_total}' --max-time "$TIMEOUT" \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d "$body" "$ENDPOINT" 2>/dev/null) || {
    echo "(stingray: unavailable — network/timeout)" >&2; exit 0; }
code=${meta%% *}; secs=${meta#* }
[ "$code" = "200" ] || { echo "(stingray: unavailable — HTTP $code)" >&2; exit 0; }

# Both scores must be numbers in [0,1]. A character allowlist would admit "2"
# or "1.2.3", and a score of 2 clears any threshold — malformed input must not
# be able to block.
read -r na bp <<<"$(jq -r '
  [(.answers.no_action.noul), (.answers.broken_promise.noul)]
  | if all(type == "number" and . >= 0 and . <= 1) then @tsv else empty end
' "$out" 2>/dev/null)"
[ -n "${na:-}" ] && [ -n "${bp:-}" ] || {
  echo "(stingray: unavailable — malformed response)" >&2; exit 0; }

# watch_mismatch only when it was asked. An absent or out-of-range answer leaves
# shape 3 exactly where the arithmetic left it: unresolved, and therefore not
# acted on.
wm=$(jq -r '.answers.watch_mismatch.noul
  | select(type == "number" and . >= 0 and . <= 1)' "$out" 2>/dev/null)
if [ "$watch_unresolved" = "1" ] && [ -n "${wm:-}" ]; then
  if awk -v v="$wm" -v t="$TAU" 'BEGIN{exit !(v >= t)}'; then
    if [ "$shape3_blocks" = "1" ]; then
      log unwatched "$wm" true
      nudge "it promises to watch an external result, and nothing that is running corresponds to it"
    fi
    log unwatched "$wm" false
  else
    log watch_ok "$wm" false
  fi
fi

fired=$(awk -v a="$na" -v b="$bp" -v t="$TAU" 'BEGIN{
  if (a >= t && a >= b) print "no_action";
  else if (b >= t) print "broken_promise";
}')
score=$(awk -v a="$na" -v b="$bp" 'BEGIN{print (a>b?a:b)}')

[ -n "$fired" ] || { log none "$score" false; exit 0; }

if [ "$jev_blocks" = "1" ]; then
  log "$fired" "$score" true
  case "$fired" in
    no_action)       nudge "this turn did nothing at all" ;;
    broken_promise)  nudge "it declared an action that this turn's tool calls do not account for" ;;
  esac
fi
log "$fired" "$score" false
exit 0
