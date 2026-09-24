#!/bin/bash
# stingray — a Claude Code Stop hook that pushes the model back to work when a
# turn stops half-done.
#
# Three failure shapes:
#   1 no_action        stopped without doing anything          -> judged by Jev
#   2 broken_promise   declared an action, tools don't cover it -> judged by Jev
#   3 unwatched        promised to watch CI/review, nothing is polling
#                      -> the promise judged by Jev, the background counted here
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
# block(), which nudge() and the language check both call. stingray must never
# make the model do less.
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

# ── Whether a reply promises to watch something ──────────────────────────────
#
# Jev decides, through the watch_claim question in questions.json. The hook no
# longer reads the message itself: it counts what is running in the background,
# which it can do exactly, and asks whether the reply promised to watch
# something, which it cannot.
#
# This replaced a family of regular expressions — verbs, targets, possessives,
# aspect markers — rebuilt five times in one release and still wrong in both
# directions. It read topic, not commitment, so a reply quoting the phrase
# "keep an eye on" blocked its own turn, and it knew a handful of Chinese verbs
# and three English phrases, so "I'll keep monitoring the build" and any
# promise in Japanese or Korean passed unseen.
#
# Measured before adopting it, with the question worded as in questions.json,
# on 59 labelled lines: the 44 of tests/watch-fixture.tsv, already public, among
# them every sentence that once blocked a real turn by mistake, and 15 synthetic
# ones. The lines that promise a watch scored 0.48 and above; the lines that do
# not, 0.18 and below. At τ = 0.5 one line is missed — "keep an eye on the
# review", which has no subject and reads as well as an instruction to the user.
# A first wording asked only about promises and scored "CI 的監看還掛著" at 0.24;
# it now also covers a reply saying a watch it set up is running, which is the
# same claim to shape 3, and that line scores 0.91 while "那是同一輪 CI 的第二個
# 監看，結果與剛才回報的相同" stays at 0.12.
#
# 0.3.1 added to the false criterion a reply that asks the user to act or reply
# and then reads the result itself. A reply that started a debug build, asked
# the user to toggle something a few times and reply, and said it would then
# read the log blocked a real turn while it was waiting on the user, not on
# anything external; replayed under the old wording it scored 0.53–0.58.
# On the 50 lines of watch-fixture.tsv the old wording gets 3 wrong and scores a
# non-promise as high as 0.82. The new one scores the promises 0.68 and above,
# the rest 0.20 and below, with "keep an eye on the review" at the threshold.
#
# What Jev sees is the redacted message, and redaction drops a whole line that
# carries a path. A promise written on the same line as a file path is therefore
# gone before it is judged. The regex read the raw message and saw it; that is
# the one thing given up here, and it is in the README's known limits.

# ── Whether a reply is in the configured language ────────────────────────────
#
# Jev decides, through the wrong_language question in questions.json. What is
# done here is only whether to ask, and what to ask about.
#
# The configured language is the "language" key in Claude Code's settings, read
# in the order Claude Code applies them: the project's settings.local.json, its
# settings.json, then the user's settings.json under CLAUDE_CONFIG_DIR (so an
# account kept in a separate config directory is read from its own file).
#
# This replaced a local rule that counted Han characters against English words
# and blocked under 40%. That rule could only see English: Japanese scored as
# nearly all Han because kana counted on neither side, and Korean or Russian
# scored as nothing at all. Every fix to it moved the edge rather than removing
# it, so the judgement went to the model, as the rest of this hook's language
# judgements already had.
#
# Measured before adopting it, on synthetic replies only — no real transcript was
# sent — with the question worded as it is in questions.json:
#
#   zh-TW replies, 7, including one of identifiers and one quoting English   0.10–0.23
#   English, Japanese (kana-heavy and kanji-heavy), Korean, Russian, 6        0.97–0.98
#   English quoting three Chinese terms                                        0.77
#   Simplified Chinese against a zh-TW setting                                 0.29
#   target English, reply Chinese / target Japanese, reply English      0.95 / 0.98
#
# Two wording choices decided that result. Passing the setting as a bare "zh-TW"
# left a plain Chinese reply at 0.49, on the line; passing a name —
# "繁體中文（台灣，zh-TW）" — moved it to 0.16, so lang_name() turns common codes
# into names. And the question is asked as "the prose is NOT in the language":
# asked positively, the reply quoting Chinese terms scored 0.54 and passed.
# Simplified Chinese is not caught at either wording, and is a known limit.
#
# A reply is asked about only when it has prose to judge: at least 12 units once
# code fences, inline code, URLs, block quotes and path-like tokens are removed.
# Without that, a line of results such as "acceptance 49/0, network 10/0" was
# judged not to be Chinese — 0.94 — which is true and useless. A unit is one
# Han, kana or Hangul character, or one word of two or more letters in any other
# script, so a Korean or Russian reply clears the floor as an English one does.
# Kana, Hangul and non-Latin letters are near absent from the 2,967 zh-TW
# messages this floor was first measured on — in 1, 1 and 3 of them — so the
# floor behaves there as it did when it counted only Han and English words.
#
# The removals follow CommonMark, and each came from a reply it once misjudged:
# fences of three or more backticks or tildes, closed by the same character at
# least as long or by the end of the message, their opener carrying no backtick
# in its info string; inline code at any backtick length, across lines inside a
# paragraph but never across a blank line; URLs as printable ASCII, so Chinese
# written straight after a link is kept.
#
# The harness writes notices of its own into transcripts as assistant text —
# "You've hit your session limit …". The hooks reference says a turn ending on
# an API error fires StopFailure rather than Stop, which would keep them from
# this hook. That is documented, not measured. If one does arrive, it is judged
# once and the re-entry guard stops a second.
prose_units() {  # prose_units <text>; prints how much prose there is to judge
  printf '%s' "$1" | perl -CSD -0777 -ne '
    s/^[ \t]*(`{3,})[^`\n]*\n.*?(?:^[ \t]*\1`*[ \t]*$|\z)/ /gms;
    s/^[ \t]*(~{3,})[^\n]*\n.*?(?:^[ \t]*\1~*[ \t]*$|\z)/ /gms;
    s/(?<!`)(`+)(?!`)(?:(?!\n[ \t]*\n).)*?(?<!`)\1(?!`)/ /gs;
    s{https?://[\x21-\x7e]+|www\.[\x21-\x7e]+}{ }g;
    s/^\s*>.*$/ /mg; s{(?:~|/|\.\.?/)[\w./-]+|\b[\w-]+\.[A-Za-z]{1,5}\b}{ }g;
    my $c = () = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]/g;
    my $w = () = /(?:(?![\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}])\p{L}){2,}/g;
    print $c + $w;'
}
lang_name() {  # lang_name <setting>; a name Jev reads more reliably than a code
  case "$1" in
    zh-TW|zh-Hant-TW) echo "繁體中文（台灣，$1）" ;;
    zh-HK|zh-Hant-HK) echo "繁體中文（香港，$1）" ;;
    zh-Hant)          echo "繁體中文（$1）" ;;
    zh-CN|zh-SG|zh-Hans|zh-Hans-*) echo "簡體中文（$1）" ;;
    zh)               echo "中文（$1）" ;;
    ja|ja-*)          echo "日文（$1）" ;;
    ko|ko-*)          echo "韓文（$1）" ;;
    en|en-*)          echo "英文（$1）" ;;
    *)                echo "$1" ;;   # a name already, or a code left to Jev
  esac
}



# ── Mode. Off by default: with no environment variable set, nothing happens. ──
#
# Separate switches, not one scale. STINGRAY_SHAPE3 and STINGRAY_LANG each turn
# on one check without the two shapes-1-and-2 judgements, which have their own
# calibration bar to clear; that is the "selective" mode. Every check is judged
# by Jev now, so every mode but "off" needs a key and sends the redacted final
# message — shape 3 was the last local one.
#
# STINGRAY_SHADOW wins over all of them: shadow means record, never block.
#
# The selective mode was named "shape3" through v0.1.2 and "local" in v0.1.3 and
# v0.2.0; decision records written by those versions carry those names.
MODE="off"
{ [ "${STINGRAY_SHAPE3:-}" = "1" ] || [ "${STINGRAY_LANG:-}" = "1" ]; } && MODE="selective"
[ "${STINGRAY:-}" = "1" ] && MODE="active"
[ "${STINGRAY_SHADOW:-}" = "1" ] && MODE="shadow"
[ "$MODE" = "off" ] && exit 0

# Shape 3 may block with its own switch, in selective or active mode, when a
# promise to watch has nothing running or scheduled behind it.
shape3_blocks=0
[ "${STINGRAY_SHAPE3:-}" = "1" ] && [ "$MODE" != "shadow" ] && shape3_blocks=1
# Shape 3 is evaluated — recorded, not necessarily blocking — with its own switch
# or in either Jev mode, which is where its calibration records come from. With
# only the language switch on it is not evaluated at all.
shape3_on=0
{ [ "${STINGRAY_SHAPE3:-}" = "1" ] || [ "$MODE" = "active" ] || [ "$MODE" = "shadow" ]; } && shape3_on=1
lang_blocks=0
[ "${STINGRAY_LANG:-}" = "1" ] && [ "$MODE" != "shadow" ] && lang_blocks=1

# The correspondence judgement is a separate switch, off even when shape 3 is
# blocking: when something IS running, whether it is the thing promised is a
# second judgement, with a borrowed threshold and no measurement behind it. It
# records from the first turn; it may block once the bar in the README is met.
watch_judge_blocks=0
[ "${STINGRAY_SHAPE3_JUDGE:-}" = "1" ] && [ "$shape3_blocks" = "1" ] && watch_judge_blocks=1
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
    --arg qh "${qset_hash:-}" --arg secs "${secs:-}" --arg pid "$(j '.prompt_id')" \
    '{ts:$ts,session:$s,prompt_id:$pid,mode:$m,shape:$shape,score:$score,
      would_block:$wb,model:$model,qset_hash:$qh,secs:$secs}')" 2>/dev/null >>"$STATE_DIR/decisions.jsonl" \
    || exit 0
}
# A record that cannot be written is a failure path like any other, and every
# failure path exits 0. 2>/dev/null comes before the redirection on purpose:
# bash applies redirections left to right, so with it after, a failed >> prints
# "Is a directory" to stderr before the silencing takes effect, and that line
# reaches the user as hook output. Measured on bash 3.2.57 — the /bin/bash that
# hooks.json runs on macOS — and on 5.3. Without this, an unwritable decisions.jsonl beside a
# writable block counter still reached block(): the hook blocked while the one
# log that calibration depends on silently lost the decision.
# prompt_id is recorded so that the block budget can later be keyed on it. The
# budget counts every block in a session and never resets, so after MAX_BLOCKS
# successful nudges the hook stops working for the rest of that session. What
# it should bound is a run of blocks at one stop point. Whether a re-entry after
# a block carries the same prompt_id as the turn it re-enters is the fact that
# decides how, and it is not yet measured; these records are how it will be.

# The only exit that blocks. The reason goes to stderr because stdout does not
# reach the model (measured, see header).
block() {  # block <message>; the one exit that blocks
  # If the budget cannot be recorded, do not block. An unrecorded block is an
  # unbounded one: on a re-entry where stop_hook_active is unavailable nothing
  # would count the rounds. Failing to write is a failure path like any other.
  printf '%s\n' "$((blocks + 1))" 2>/dev/null >"$count_file" || exit 0
  printf '%s\n' "$1" >&2
  exit 2
}
nudge() {  # nudge <shape description>
  block "stingray: this turn looks like it stopped half-done ($1).

If the user's earlier instruction already authorised it, finish it now before
ending the turn. If you are waiting on an external result (CI, a PR review),
launch the polling command in the background before ending the turn. If you
genuinely need a decision from the user, say which decision you are blocked on
rather than simply stopping."
}

# ── Language: whether to ask Jev, and about which language ───────────────────
# The judgement is made in the Jev section below. Nothing blocks here.
lang_setting() {  # lang_setting; prints the configured language, or nothing
  lcwd=$(j '.cwd')
  for f in ${lcwd:+"$lcwd/.claude/settings.local.json" "$lcwd/.claude/settings.json"} \
           "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json"; do
    v=$(jq -r '.language // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
}
lang_ask=0; want=""; want_name=""
if [ "${STINGRAY_LANG:-}" = "1" ]; then
  want=$(lang_setting)
  if [ -n "$want" ]; then
    units=$(prose_units "$last")
    case "$units" in ''|*[!0-9]*) ;; *) [ "$units" -ge 12 ] && lang_ask=1 ;; esac
  fi
fi
[ "$lang_ask" = "1" ] && want_name=$(lang_name "$want")

# ── Shape 3: count the background locally, ask Jev about the promise ─────────
# Require an actual array. Neither a missing key nor a null may be read as
# "nothing is running": has() is true for null, and [ .[]? ] over null counts
# zero, so either would turn shape 3 into "block whenever a promise is judged".
# A positive-case test still passes under that defect — it surfaces only as a
# wrong block on ordinary turns, which is why mutants.sh covers it.
#
# Scheduled work counts too. A cron polling the thing it promised to watch is a
# kept promise, and session_crons went unread until a probe showed shape 3
# blocking a turn whose cron was doing exactly the polling it asked for.
shape3_ask=0; watch_ask_match=0; running=-1
if [ "$shape3_on" = "1" ] && \
   [ "$(printf '%s' "$input" | jq '(.background_tasks | type) == "array"' 2>/dev/null)" = "true" ]; then
  running=$(printf '%s' "$input" | jq '
    ([.background_tasks[]? | select(.status=="running")] | length)
    + ((.session_crons // []) | length)' 2>/dev/null)
  case "$running" in ''|*[!0-9]*) running=-1 ;; esac
  if [ "$running" -ge 0 ]; then
    shape3_ask=1
    # With something running, a promise is kept only if that work is what was
    # promised — a build running while the turn promised to follow a PR review
    # satisfies a count and breaks the promise. Asked in the same request.
    [ "$running" -gt 0 ] && watch_ask_match=1
  fi
fi

# ── Judged by Jev ─────────────────────────────────────────────────────────────
# Selective mode stops here when neither of its checks has a question to ask:
# the language, when the reply has too little prose, and shape 3, when the
# background list is missing or unreadable. Then no credential is read and no
# request is made. Without this exit a key sitting in ~/.config would send this
# turn's message with nothing to ask about it.
[ "$MODE" = "selective" ] && [ "$lang_ask" != "1" ] && [ "$shape3_ask" != "1" ] && exit 0
# Shapes 1 and 2 are asked only in active or shadow mode. In selective mode the
# request carries only the questions of the checks switched on.
jev_shapes=0
{ [ "$MODE" = "active" ] || [ "$MODE" = "shadow" ]; } && jev_shapes=1

KEY="${TYPESAFE_API_KEY:-${HOME:+$(cat "$HOME/.config/typesafe/api_key" 2>/dev/null)}}"
if [ -z "$KEY" ]; then
  marker="$STATE_DIR/nokey-$session"
  [ -f "$marker" ] || { echo "(stingray: unavailable — no key; Jev checks skipped)" >&2; : 2>/dev/null >"$marker"; }
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
  # Credential shapes first: an Authorization header or a token-looking field
  # must not survive into the request, and the outgoing scan covers only sk-,
  # GitHub, AWS and PEM. A cron prompt is free text written by the model and can
  # carry a curl command with a header in it.
  perl -0777 -pe '
    s/\bAuthorization\s*:\s*\S+(\s+\S+)?/Authorization: <redacted>/gi;
    s/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{8,}/$1 <redacted>/g;
    s/\bgithub_pat_[A-Za-z0-9_]{20,}/<redacted credential>/g;
    s/("?)(?:api[_-]?key|auth[_-]?token|access[_-]?token|secret|password|passwd|pwd)\1\s*[:=]\s*"?[^"\s,;}]{6,}"?/<redacted credential>/gi;
  ' | perl -0777 -pe '
    s/```.*?```/ /gs;                      # fenced code blocks (paired)
    s/^\s*>.*$/ /mg;                       # block quotes
    s/`[^`\n]{1,200}`/ /g;                 # inline code
    s{https?://[\x21-\x7e]+|www\.[\x21-\x7e]+}{ }g;   # URLs, in place; see prose_units
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
# An absent or non-array background_tasks produces no output here, so the line
# below reports the list as unavailable. It used to iterate with []? and report
# "nothing running or scheduled" — unknown state sent to Jev as confirmed
# inactivity, the same mistake shape 3 guards against with its own type check.
# Observed in tests/network.sh B7, which sends a payload with background_tasks
# deleted and reads the recorded request body: every question's
# instructions.background is "background list unavailable", and with the old
# expression restored it is "nothing running or scheduled".
bg_text=$(printf '%s' "$input" | jq -r '
  if (.background_tasks | type) != "array" then empty else
  [ (.background_tasks[] | "\(.status): \(.description // "(no description)")"),
    ((.session_crons // [])[]? | "scheduled: \(.prompt // "(no prompt)")") ]
  | if length == 0 then "nothing running or scheduled" else join(" | ") end end' 2>/dev/null)
[ -n "$bg_text" ] || bg_text="background list unavailable"
bg_text=$(printf '%s' "$bg_text" | redact_text | tr '\n' ' ')
[ -n "${bg_text// /}" ] || bg_text="background list unavailable"

# watch_mismatch is asked only when something is running, alongside watch_claim:
# with nothing running, the count has already decided that a promise, if one was
# made, has no mechanism behind it. watch_claim and wrong_language carry only
# what they judge — the message, and for the language the language — because
# the tool list and background are no evidence about either.
#
# wrong_language carries the final message and the language, and nothing else:
# the tool list and background are no evidence about language. And the language
# goes on that question only. Adding it to no_action or broken_promise would
# change their input, and the 81.8% they were measured at would no longer be a
# measurement of them.
body=$(jq -cn --arg m "$MODEL" --arg ft "$redacted" --arg tl "$tools" \
  --arg bg "$bg_text" --argjson s3 "$shape3_ask" --argjson wm "$watch_ask_match" \
  --argjson js "$jev_shapes" --argjson la "$lang_ask" --arg lang "$want_name" \
  --slurpfile q "$QUESTIONS" '
  {model: $m,
   state: {source: "the end of one turn in a Claude Code transcript"},
   questions: ($q[0]
     | (if $s3 == 1 then . else del(.watch_claim) end)
     | (if $wm == 1 then . else del(.watch_mismatch) end)
     | (if $js == 1 then . else del(.no_action, .broken_promise) end)
     | (if $la == 1 then . else del(.wrong_language) end)
     | with_entries(
        if .key == "wrong_language"
        then .value.instructions += {final_text: $ft, language: $lang}
        elif .key == "watch_claim"
        then .value.instructions += {final_text: $ft}
        else .value.instructions += {final_text: $ft, tools: $tl, background: $bg} end))}
') || exit 0

# Scan the exact bytes about to be transmitted, not one field of them. The body
# also carries tool names taken from the transcript, background statuses and the
# question text; scanning only the redacted message left those uncovered while
# the README claimed the outgoing bytes were scanned.
if printf '%s' "$body" | grep -qE 'sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
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

# The language first: one block per stop carries one instruction, and a reply
# the user cannot read in their own language is the more basic failure of the
# two. An answer that is absent or outside [0,1] leaves the language unjudged
# rather than failing the rest of the response.
wl=$(jq -r '.answers.wrong_language.noul
  | select(type == "number" and . >= 0 and . <= 1)' "$out" 2>/dev/null)
if [ "$lang_ask" = "1" ] && [ -n "${wl:-}" ]; then
  if awk -v v="$wl" -v t="$TAU" 'BEGIN{exit !(v >= t)}'; then
    if [ "$lang_blocks" = "1" ]; then
      log wrong_language "$wl" true
      block "stingray: this turn's final message is not in the configured language
(settings \"language\": \"$want\"; judged not to be $want_name).

Rewrite that final message in $want_name now. Keep the content as it was, and
leave code blocks, commands, paths and identifiers exactly as they are."
    fi
    log wrong_language "$wl" false
  else
    log language_ok "$wl" false
  fi
fi
# Shape 3. A promise judged at or above τ with nothing running or scheduled
# blocks on shape 3's own switch; with something running it blocks only if the
# correspondence judgement also fires, on STINGRAY_SHAPE3_JUDGE. An answer that
# is absent or outside [0,1] leaves shape 3 unjudged.
wc=$(jq -r '.answers.watch_claim.noul
  | select(type == "number" and . >= 0 and . <= 1)' "$out" 2>/dev/null)
wm=$(jq -r '.answers.watch_mismatch.noul
  | select(type == "number" and . >= 0 and . <= 1)' "$out" 2>/dev/null)
if [ "$shape3_ask" = "1" ] && [ -n "${wc:-}" ]; then
  if ! awk -v v="$wc" -v t="$TAU" 'BEGIN{exit !(v >= t)}'; then
    log watch_none "$wc" false
  elif [ "$running" = "0" ]; then
    if [ "$shape3_blocks" = "1" ]; then
      log unwatched "$wc" true
      nudge "it promises to watch an external result, but nothing is running in the background"
    fi
    log unwatched "$wc" false
  elif [ -n "${wm:-}" ]; then
    if awk -v v="$wm" -v t="$TAU" 'BEGIN{exit !(v >= t)}'; then
      if [ "$watch_judge_blocks" = "1" ]; then
        log unwatched "$wm" true
        nudge "it promises to watch an external result, and nothing that is running corresponds to it"
      fi
      log unwatched "$wm" false
    else
      log watch_ok "$wm" false
    fi
  fi
fi
[ "$jev_shapes" = "1" ] || exit 0

# Both scores must be numbers in [0,1]. A character allowlist would admit "2"
# or "1.2.3", and a score of 2 clears any threshold — malformed input must not
# be able to block.
read -r na bp <<<"$(jq -r '
  [(.answers.no_action.noul), (.answers.broken_promise.noul)]
  | if all(type == "number" and . >= 0 and . <= 1) then @tsv else empty end
' "$out" 2>/dev/null)"
[ -n "${na:-}" ] && [ -n "${bp:-}" ] || {
  echo "(stingray: unavailable — malformed response)" >&2; exit 0; }

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
