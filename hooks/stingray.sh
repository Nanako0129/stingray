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

# ── What counts as a claim to watch something ────────────────────────────────
#
# Every count below is over whole assistant messages evaluated the way this
# function evaluates them, line by line: 2,527 messages from 60 transcripts
# across 54 sessions. Two earlier versions of this comment were wrong about the
# unit. The first counted 31,088, which was the corpus split on newlines. The
# second counted messages but measured them with the newlines replaced by
# spaces, which lets a verb on one line reach a target on the next — something
# grep cannot do, since it is line-oriented and ERE cannot cross a newline.
# Both overstated the shape. These figures come from the real semantics,
# cross-checked against --watch-test on 41 cases with no disagreement.
#
# A claim needs a verb AND a thing being watched. The verbs alone matched topic,
# not commitment: the shipped regex before this change matched 183 messages, 142
# of them on a line whose verb had no narrowing at all, and only 3 of those 142
# carried any first-person marker. The hits included a CV line ("我做過跨 13 個節點的監控
# 平台"), a quoted customer requirement, and a release announcement whose subject
# was a poller that used to hang — that last one blocked a real turn with nothing
# running. Requiring a target takes 183 messages to 52.
#
# The target requirement alone dropped 131 of those 183, and most of a sample
# was genuine: "第 5 輪輪詢中（`bx22jpak0`）。", "監看還架著。". They name no
# target, so widening cannot reach them — 90 recovers 5 of the 131 and starts
# admitting fixture lines that must stay quiet.
#
# WATCH_ASPECT recovers them a different way: a verb followed within 6 characters
# by an aspect marker — 中, 在跑, 在背景, 架著, 掛著, 掛上, 開著, 還在, 仍在 — is
# reporting an activity, whatever else is in the sentence, so it needs no target.
# It takes the rule from 52 messages to 102, recovering 50 of the 131. All 51
# lines it alone matches are of one form, "第 N 輪輪詢中（`b8v4feomf`）", and it
# adds nothing the old bare-verb rule did not already match, so it cannot be
# looser than what it replaces. It leaves the ten sentences that started this —
# the eight nominalisations, "無限迴圈…根本未進入輪詢", "pgrep 無 poll 程序" —
# all quiet.
#
# It is a whitelist, and the objection that killed the noun blocklist applies:
# whitelists accrete too. The argument for this one is that Chinese aspect
# marking is a closed set while nouns are open. That is a claim about the
# language, not a measurement, and it is the part of this rule most likely to
# need a word added later. It needed one immediately: the list as first written
# had 掛著 and not 掛上, so "那支 PR 的輪詢已經掛上了" came out quiet. Adding it
# matched no further message in the corpus, which is the test a new word has to
# pass — a word that widens the rule on real text is a different proposal and
# belongs with its own measurement.
#
# Neither side of that trade generalises. 176 of the old 183 hits and 51 of the
# new 52 come from a single session out of 54 — an auto-loop that reports polling
# status every turn. What this corpus establishes is how the rules behave on that
# habit, not on everyone.
#
# The window is 20. Message hits by window: 20 gives 52, 30 gives 53, 40 gives
# 55, 90 gives 57 — and every width from 30 up also matches a fixture line that
# must stay quiet. So 20 is where the curve stops paying. It is wide enough for
# the real reason messages need width, a commit sha or a URL between the verb
# and its object, as in "輪詢最新 head（7758156）的自動審查結果".
#
# `poll` is bracketed by non-identifier characters so a filename does not read
# as a promise: poll-coderabbit.sh matched the bare form on its own name.
#
# Reverse order — target first, then verb — catches the progressive form the
# forward shape cannot see: "Codex 輪詢中", "監看已在背景掛上". Like everything
# else here its evidence is one session, so it is kept because the possessive
# rule makes it cheap, not because the corpus settles it.
#
# The reverse order also reads "CI 的輪詢器壞了" as a promise, because there the
# verb is a noun. A possessive or demonstrative immediately before the verb marks
# that case: on eight constructed sentences of the shape it catches 8 of 8, and
# it removes no real hit from the corpus. (On the line-split corpus it appeared
# to cost 2; that was an artefact of the same unit error.)
#
# A nominalised watch that is genuinely in progress — "CI 的監看還掛著" — is
# refused by the possessive rule and reached by WATCH_ASPECT instead, which is
# what the aspect marker is for. Those sentences are in tests/watch-fixture.tsv
# as `nom-cost`, expected watch, and they fail if either half is removed.
#
# A possessive or a demonstrative immediately before the verb marks it as a noun
# — "CI 的輪詢器壞了" is about a poller, not a promise to watch one. That refusal
# is written into WATCH_FWD and WATCH_REV as a character class rather than as a
# second pattern applied afterwards, and the difference is not stylistic. Three
# defects on this branch were the same mistake: an exclusion evaluated separately
# withdrew a hit it was not describing.
#
#   whole-text greps   "Codex 輪詢中" cancelled by "CI 的輪詢器壞了" on another
#                      line, in either order
#   compared by line   "那支輪詢器剛修好，我會盯著 CI 的結果" cancelled inside
#                      one line, the promise killed by the clause before it
#   inside the match   cannot happen: there is nothing to withdraw
#
# All three were found by the session reviewing this branch, the last two in
# sentences it had written about this branch. The invariant they converge on is
# that an exclusion may only refuse the hit it describes, and the only way to
# hold it with grep is to make the refusal part of the hit.
#
# It also settles the case that started this: "CI 的輪詢器壞了" and "這個 PR 的
# 輪詢邏輯有 bug" on one line, where 輪詢 at the end of the first reaches PR at
# the start of the second. Both verbs carry a possessive, so neither is a hit,
# and there is no combination left to make. Measured: 99 corpus messages against
# 102 under the withdrawal version, and the three it drops are one sentence
# repeated — "那是同一輪 CI 的第二個監看，結果與剛才回報的相同" — a completed
# watch reported in the past tense.
#
# What no arrangement of this reaches: quoting a promise reads as making one.
# "他說丟掉的那類：第 5 輪輪詢中、監看還架著" matches, correctly by the rule and
# wrongly by intent, and telling those apart is semantics. Whoever maintains this
# regex gets blocked by it while discussing it. redact_text does not run before
# shape 3, so examples inside code fences take part in the match as well.
#
# "Round 2 輪詢中", "輪詢在背景" and "輪詢中" were the cost of the target
# requirement and are recovered by the aspect branch; they stay in the fixture
# under `short` so that removing that branch fails rather than quietly shrinks
# the rule. What remains uncovered is a targetless promise with no aspect marker
# either — "推送、重建、輪詢第十二輪。" — and nothing here reaches it.
#
# Last, the honest limit on all of the above. 176 of the old 183 hits and 51 of
# the new 102 come from one session out of 54, an auto-loop reporting poll status
# every turn. Outside it the whole corpus holds 7 hits under the old rule and 1
# under this one. Every comparison in this comment is therefore a statement about
# that session's writing, and the numbers should not be read as settling how any
# of these shapes behave in general.
WATCH_TARGET='CI|ci|review|Review|審查|PR|pull request|CodeRabbit|Copilot|Codex|build|建置|部署|deploy|workflow|job|pipeline'
WATCH_VERB='監看|監控|盯著|盯住|輪詢|持續追蹤|(^|[^A-Za-z0-9_-])poll(ing)?([^A-Za-z0-9_-]|$)'
# Not a possessive or a demonstrative, as the one or two characters right before
# the verb. Spelled into the match so the refusal can never be applied to some
# other hit afterwards.
#
# 支, 段 and 個 count only after 那 or 這. As first written the class refused all
# three outright, which also refused them as measure words: "我開了三個監看盯 CI"
# and "每支輪詢都會盯 PR" came out quiet. Measured on the corpus, the bare form
# guarded against 0 demonstratives (那／這 + 支段個 + verb never occurs) while it
# could refuse 5 lines, 2 of them genuine claims. Found by the session reviewing
# the previous release.
WATCH_PRE='([^。的支段個]|[^那這。][支段個])'
WATCH_FWD="(^|${WATCH_PRE})(${WATCH_VERB})[^。]{0,20}(${WATCH_TARGET})|等(著|待|到)? ?(CI|ci|review|Review|審查|CodeRabbit|Copilot|Codex)[^。]{0,12}(回來|回覆|完成|跑完|出來|結果|綠)|keep (an eye on|watching|polling)|I.?ll (monitor|watch|poll)"
WATCH_REV="(${WATCH_TARGET})(${WATCH_VERB})|(${WATCH_TARGET})[^。]{0,19}${WATCH_PRE}(${WATCH_VERB})"
WATCH_ASPECT="(${WATCH_VERB})[^。]{0,6}(中|在跑|在背景|架著|掛著|掛上|開著|還在|仍在)"

# The one place that decides. tests/watch-fixture.sh drives this through
# --watch-test rather than rebuilding the condition, because a second copy of a
# decision is how a change gets tested against its own mirror image.
watch_claims() {  # watch_claims <text>; 0 = claims to watch something
  printf '%s' "$1" | grep -qE "$WATCH_ASPECT" && return 0
  printf '%s' "$1" | grep -qE "$WATCH_FWD" && return 0
  printf '%s' "$1" | grep -qE "$WATCH_REV" && return 0
  return 1
}

# ── What counts as a reply in the wrong language ─────────────────────────────
#
# The configured language is the "language" key in Claude Code's settings, read
# in the order Claude Code applies them: the project's settings.local.json, its
# settings.json, then the user's settings.json under CLAUDE_CONFIG_DIR (so an
# account kept in a separate config directory is read from its own file).
#
# Only Chinese targets are checked, because the test is a script test: prose that
# should be Han and is not. Other languages return "not wrong" and nothing
# happens. Simplified versus Traditional is not distinguished either.
#
# Code fences, inline code, URLs, block quotes and path-like tokens are removed
# first — they are English in every language and say nothing about the prose.
# Fences are removed the way CommonMark closes them: three or more backticks or
# tildes, closed by a line of the same character at least as long, or by the end
# of the message. A regex for paired ``` alone left a ~~~ block, or a ```` block
# holding ```, in the prose sample, where its English could block a zh-TW reply.
# Across the 2,967 messages below, 0 lines open a ~~~ fence and 0 open a ````
# one; the false-block direction is why they are handled anyway.
#
# Inline code is removed at any backtick length — a run closed by a run of the
# same length, as CommonMark closes it. Only single backticks were removed
# before, so a zh-TW reply quoting commands in double backticks kept their
# English and was blocked: measured, 8 Han to 16 words.
#
# A URL is removed as printable ASCII only. \S+ ran on through Chinese written
# straight after it with no space between, as Chinese is: a reply citing a PR
# link lost the rest of its sentence and kept 6 of its Han characters. The same
# rule was in redact_text and is fixed there too, where it had been removing
# prose from what is sent to Jev while claiming to replace URLs in place.
#
# A backtick opener's info string may not contain a backtick, as in CommonMark.
# Without that, a first line reading ```js``` opened a "fence" that ran to the
# next ``` line and removed the English prose in between: a whole English reply
# came out as 1 Han and 0 words, and passed. The paired fallback /```.*?```/ is
# gone for the same reason — it spans lines and eats whatever lies between two
# stray triple backticks. Same-line ```code``` is left to the inline-code rule.
#
# What is left is counted as Han characters against Latin words of two letters or
# more, and the reply is wrong when fewer than 40% of those are Han, provided
# there are at least 12 of them together. The floor keeps "OK", "LGTM" and a
# terse status line from being judged at all.
#
# Measured with these two functions, not a reimplementation, over 2,967 real
# assistant messages from sessions configured for zh-TW. The floor was chosen by
# what each value catches against how close it lets a zh-TW reply come:
#
#   floor   English model replies caught   lowest zh-TW score   margin
#     20                  3                       63%              23
#     12                  7                       60%              20
#      8                 13                       45%               5
#
# 20 was the first value; a review pointed at the short English replies it
# skipped ("Now build and test on the Windows machine:"). 8 catches all 13 of
# them but lets terse zh-TW status lines — "#92 全綠、Codex CLEAN。merge 後推
# tag。", 50% — sit five points from the line, and a false block is the
# direction this hook exists not to take. At 12, 2,834 messages are judged, no
# zh-TW reply scores under 60%, and the ones under 40% are all English: the 7
# model replies (one quoting 「超前」「保留」「超支」, at 25%) and 6 notices
# written by the harness itself. The English side of the line rests on those 7.
#
# The harness notices — "You've hit your session limit …", "API Error:
# Connection lost mid-response …" — are recorded in transcripts as assistant
# text. The hooks reference says a turn that ends on an API error fires
# StopFailure, with error types including rate_limit and billing_error, which
# would keep them away from a Stop hook. That is documented, not measured, and
# the same reference has been wrong about Stop before. If one does arrive it is
# blocked once and the re-entry guard stops a second.
lang_share() {  # lang_share <text>; prints "<han> <latin words>" for the prose
  printf '%s' "$1" | perl -CSD -0777 -ne '
    s/^[ \t]*(`{3,})[^`\n]*\n.*?(?:^[ \t]*\1`*[ \t]*$|\z)/ /gms;
    s/^[ \t]*(~{3,})[^\n]*\n.*?(?:^[ \t]*\1~*[ \t]*$|\z)/ /gms;
    s/(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)/ /g;
    s{https?://[\x21-\x7e]+|www\.[\x21-\x7e]+}{ }g;
    s/^\s*>.*$/ /mg; s{(?:~|/|\.\.?/)[\w./-]+|\b[\w-]+\.[A-Za-z]{1,5}\b}{ }g;
    my $h = () = /\p{sc=Han}/g; my $w = () = /[A-Za-z]{2,}/g; print "$h $w";'
}
lang_wrong() {  # lang_wrong <language> <text>; 0 = the prose is not in <language>
  case "$1" in zh*|ZH*) ;; *) return 1 ;; esac
  read -r lh lw <<EOF
$(lang_share "$2")
EOF
  case "$lh$lw" in ''|*[!0-9]*) return 1 ;; esac
  [ $((lh + lw)) -ge 12 ] || return 1
  [ $((lh * 100)) -lt $((40 * (lh + lw))) ]
}

# Fixture entry point. Answers for one line and exits; reads no stdin, writes no
# state, makes no request.
if [ "${1:-}" = "--watch-test" ]; then
  watch_claims "${2:-}" && { echo watch; exit 0; }
  echo quiet; exit 0
fi
# Same contract for the language rule: --lang-test <language> <text>.
if [ "${1:-}" = "--lang-test" ]; then
  lang_wrong "${2:-}" "${3:-}" && { echo wrong; exit 0; }
  echo ok; exit 0
fi


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
#
# STINGRAY_LANG is the second local check and shares the mode: with either local
# switch alone, nothing leaves the machine. The mode was called "shape3" until
# the language check joined it; decision records written before carry that name.
MODE="off"
{ [ "${STINGRAY_SHAPE3:-}" = "1" ] || [ "${STINGRAY_LANG:-}" = "1" ]; } && MODE="local"
[ "${STINGRAY:-}" = "1" ] && MODE="active"
[ "${STINGRAY_SHADOW:-}" = "1" ] && MODE="shadow"
[ "$MODE" = "off" ] && exit 0

# Shape 3 may block in active (with its own flag) or in shape3-only mode. This
# covers only the certain case: a promise with nothing running or scheduled
# behind it, which arithmetic settles.
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
# blocking. It is a model answer with a borrowed threshold and no measurement
# behind it, and shape 3's whole claim was that it blocks only when the answer
# is certain. Folding it in would have removed that quietly. It records from the
# first turn; it may block once the bar in the README is met.
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

# ── Language: computed locally. No model call, no API key required. ───────────
# First, because a reply the user cannot read in their own language is the more
# basic failure, and one block per stop can only carry one instruction.
lang_setting() {  # lang_setting; prints the configured language, or nothing
  lcwd=$(j '.cwd')
  for f in ${lcwd:+"$lcwd/.claude/settings.local.json" "$lcwd/.claude/settings.json"} \
           "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json"; do
    v=$(jq -r '.language // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
}
if [ "${STINGRAY_LANG:-}" = "1" ]; then
  want=$(lang_setting)
  if [ -n "$want" ] && lang_wrong "$want" "$last"; then
    if [ "$lang_blocks" = "1" ]; then
      log wrong_language 1 true
      block "stingray: this turn's final message is not in the configured language
(settings \"language\": \"$want\"; the prose outside code is mostly not $want).

Rewrite that final message in $want now. Keep the content as it was, and leave
code blocks, commands, paths and identifiers exactly as they are."
    fi
    log wrong_language 1 false
  fi
fi

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
watch_claimed=0
watch_unresolved=0
if [ "$shape3_on" = "1" ] && watch_claims "$last"; then
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
[ "$MODE" = "local" ] && exit 0

KEY="${TYPESAFE_API_KEY:-${HOME:+$(cat "$HOME/.config/typesafe/api_key" 2>/dev/null)}}"
if [ -z "$KEY" ]; then
  marker="$STATE_DIR/nokey-$session"
  [ -f "$marker" ] || { echo "(stingray: unavailable — no key; shapes 1/2 skipped)" >&2; : 2>/dev/null >"$marker"; }
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
    s{https?://[\x21-\x7e]+|www\.[\x21-\x7e]+}{ }g;   # URLs, in place; see lang_share
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
bg_text=$(printf '%s' "$input" | jq -r '
  if (.background_tasks | type) != "array" then empty else
  [ (.background_tasks[] | "\(.status): \(.description // "(no description)")"),
    ((.session_crons // [])[]? | "scheduled: \(.prompt // "(no prompt)")") ]
  | if length == 0 then "nothing running or scheduled" else join(" | ") end end' 2>/dev/null)
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
    if [ "$watch_judge_blocks" = "1" ]; then
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
