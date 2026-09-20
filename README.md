# stingray

A Claude Code `Stop` hook that catches a turn stopping half-done and pushes the
model back to finish it.

Stingrays lie still on the sand and cost you nothing until you step on one.
This does the same: silent on a normal turn, a nudge on a turn that stopped
when it should have kept going.

```
you:     fix the timeout and run the tests
claude:  I'll change the config value now, then run the suite.
         [turn ends. nothing was changed. nothing was run.]

         ── stingray ──────────────────────────────────────────
         this turn looks like it stopped half-done
         (it declared an action that this turn's tool calls do not account for)

claude:  [edits the config, runs the suite]
```

## The three shapes it looks for

| # | Shape | Judged by |
|---|-------|-----------|
| 1 | `no_action` — stopped without doing anything, when it could have acted | [Jev](https://typesafe.ai) |
| 2 | `broken_promise` — declared an action the turn's tool calls don't account for | Jev |
| 3 | `unwatched` — promised to watch CI or a PR review with nothing polling | computed locally |

Shape 3 never goes to a model. Both halves of it are exact values — a
declaration regex, and the `background_tasks` field the hook is handed. Turning
a certainty into a probability is a downgrade, so it stays arithmetic.

## Friction only ever goes up

Every failure path — no key, timeout, HTTP error, malformed response, a score
below threshold, a secret spotted in the outgoing bytes — exits 0 and leaves
behaviour exactly as if the plugin were not installed. stingray can add work.
It can never let the model do less. That rule is what makes the failure modes
boring: there is no configuration in which a broken stingray approves something.

## Install

```bash
git clone https://github.com/Nanako0129/stingray
```

Add the plugin to Claude Code, or point a `Stop` hook straight at the script:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/bin/bash /path/to/stingray/hooks/stingray.sh",
                     "timeout": 10 } ] }
    ]
  }
}
```

Always set `timeout`. Claude Code's default for a hook is **600 seconds**, so an
endpoint that hangs would hold your turn open for ten minutes.

Requires `bash`, `jq`, `curl` and `perl` — all present on macOS and on any
normal Linux.

## API key

Shapes 1 and 2 call TypeSafe's System One (`jev-1.13.0`). Shape 3 needs no key
and no network.

1. Get a key at <https://typesafe.ai>.
2. Put it in `~/.config/typesafe/api_key` (`chmod 600`), or export
   `TYPESAFE_API_KEY`. The file is preferred: an environment variable is visible
   to every process you launch.

**Without a key, stingray behaves exactly as it does when uninstalled**, prints
`(stingray: unavailable — no key; shapes 1/2 skipped)` once per session, and
keeps shape 3 working. It is never silently inert.

## Switches — off by default

| Variable | Effect |
|---|---|
| *(nothing set)* | **Default.** The hook exits immediately. Nothing runs, nothing is sent. |
| `STINGRAY_SHADOW=1` | Calls Jev, writes a decision record, **never blocks**. Start here. |
| `STINGRAY=1` | Blocks on shapes 1 and 2. |
| `STINGRAY_SHAPE3=1` | Also blocks on shape 3. Independent of `STINGRAY` on purpose — see calibration. |

Other knobs: `STINGRAY_TAU` (0.5), `STINGRAY_TIMEOUT` (6s), `STINGRAY_MAX_BLOCKS`
(3 per session), `STINGRAY_STATE_DIR` (`~/.local/state/stingray`),
`STINGRAY_JEV_MODEL` (`jev-1.13.0`, pinned — `jev-latest` would change the
classifier under you).

## What leaves your machine

Only three fields, and only when a key is configured:

| Field | Content |
|---|---|
| `final_text` | the last assistant message, redacted, then truncated to the last 2400 **bytes** — about 800 CJK characters, but roughly 2400 characters of plain ASCII, so an English turn sends about three times the text the accuracy figures below were measured on |
| `tools` | tool **names** and a count for this turn — never arguments |
| `background` | background task **statuses** — never descriptions, never command lines |

Your prompts are never sent. Tool arguments, file contents and diffs are never
sent.

Redaction removes fenced code, block quotes, inline code and URLs, drops any
line carrying an absolute path, a relative path or a filename, and masks commit
SHAs, issue numbers and project names. Project names are *derived*, not
hardcoded: the directory the hook reports and the repository its git remote
points at. Sibling projects you mention by name are not discoverable from
there — list them in `STINGRAY_REDACT_WORDS` if you want them masked too.

Truncation happens *after* redaction. The other order slices a code fence in
half, the pair stops matching, and the whole block leaks.

### See for yourself, then decide

```bash
./tests/show-payload.sh 50
```

That drives the **real hook** against a local recording server and writes the
exact bytes it puts on the wire to `payload-audit.txt`. It reads what is sent,
not what the redactor intends to remove. A separate copy of the redactor drifts
from the shipped one — that drift is how a rule went missing here once while
this README still promised it.

### The redaction ceiling, measured on the bytes actually sent

**Redaction does not reach "no private content", and nothing here should be
read as if it did.**

Across 48 captured payloads from real turns, every leak category the tool counts
came back zero: fenced code, absolute and relative paths, filenames, URLs, commit
SHAs, issue numbers, line ranges. A zero there means "not found", never "clean" —
a scan can only find the categories somebody thought of.

What plainly survives is the **substance of the work**. Reading those payloads
tells you a quota window was read at 80% while 47 samples in the same window
said 77%, that a 60-second blind poll is still running, that six recovery files
sit in a directory dated 2026-08-22. Identifiers are gone; what you are building,
what is broken and how you decided to fix it are not.

TypeSafe processes in the United States, retains without a stated limit, and
caps liability at USD 50. Decide with that in front of you, and with
`payload-audit.txt` open. `STINGRAY_SHADOW=1` still sends. Only the default off
state sends nothing at all.

Before any request leaves, the outgoing bytes are scanned for key material
(`sk-`, `ghp_`, `AKIA`, PEM headers). On a hit the request is dropped and the
turn proceeds untouched.

## Calibration: shadow first, and two separate bars

Accuracy was measured offline against 124 turns from one user's real
transcripts, labelled by whether that user had to type "keep going" (`jev-1.13.0`,
2026-09-21):

| payload | precision | recall | FPR |
|---|---|---|---|
| full (redacted, ~800 chars) | **81.8%** | 14.1% | 3.3% |
| last two sentences only | 61.1% | 17.2% | 11.7% |
| structured flags only | — | — | `no_action` never fires |

Per question, at full payload: `no_action` 85.7% precision / 1.7% FPR;
`broken_promise` 66.7% / 3.3%.

**That experiment cannot settle the question, and it is not presented as if it
did.** The labels systematically undercount: a user only sometimes types "keep
going" — often they just answer, or move on. Of the two false positives at
τ=0.5, manual reading showed one was a labelling error, not a prediction error.
Ten of eleven hits were correct on inspection. Hence: shadow by default, and
real labels come from your own shadow log.

High precision with low recall is the right shape here. A wrong nudge costs a
wasted turn; a missed one costs nothing at all.

One more caveat, stated because this exact divergence has already caused one
defect here: the offline experiment ran through a *copy* of the redactor that
masked a fixed list of project names, while the shipped one derives them from
your directory and git remote. The payloads are close but not byte-identical, so
treat 81.8% as measured on a near neighbour of what ships, not on it.

**Two independent bars before turning blocking on**, because shape 3 must not
ride in on shape 1 and 2's calibration — the Jev question it replaced scored
20.0% precision at 66.7% FPR, and moving it to arithmetic does not by itself
make it good enough:

- Shapes 1 and 2 (`STINGRAY=1`): ≥ 40 shadow records, ≥ 70% precision on your own
  reading, ≤ 3 wrong nudges per 100 stop points, and τ placed in the empty band
  between the score clusters with the derivation written next to it.
- Shape 3 (`STINGRAY_SHAPE3=1`): ≥ 20 shadow records, ≥ 70% precision.

Records land in `$STINGRAY_STATE_DIR/decisions.jsonl`, one line per decision,
each carrying `qset_hash`. Editing one line of criteria moves the whole score
distribution, so a threshold calibrated under the old wording is void — the hash
is how you notice.

## Latency

Measured at the hook position in shadow mode — not with a bare `curl`, because
what matters is what the turn waits for. Taiwan to `api.typesafe.ai`, three
separate runs of 20: **p50 0.742–0.760s, p95 0.818–0.888s**, against a 1.0s
budget. A range rather than one number, because the exact figure is not
reproducible across runs and a single decimal would imply otherwise.

The budget applies to shadow too, because shadow is where you will spend most
of your time and it pays the same round trip. If your p95 exceeds it, turn the
plugin off or lower `STINGRAY_TIMEOUT` — dropping back to shadow does not remove
the latency, so it is not a remedy.

That budget covers the healthy case only. When the endpoint hangs, the turn
waits for `STINGRAY_TIMEOUT` and then proceeds: **measured at 6.11s with the
shipped default**, against a stub that accepts and never answers. Lower the
timeout if that is too long to pay on a bad day.

## Loop protection

Two guards, because one boolean is a single point of failure whose failure
direction is an infinite loop:

1. `stop_hook_active` from the harness — true on re-entry, so a nudge is never
   applied twice to the same stop.
2. A per-session block budget (3 by default) that does not depend on the first.

## Known limits

- The Jev criteria in `questions.json` are written in Traditional Chinese,
  because that is the corpus the 81.8% was measured on. English criteria are
  untested and would void that number. If you work in English, expect to rewrite
  them and recalibrate.
- Shape 3's accuracy cannot be measured offline at all: its evidence,
  `background_tasks`, exists only at the moment the hook runs and cannot be
  reconstructed from a transcript. `tests/acceptance.sh` proves the branch
  behaves correctly on synthetic input; whether it fires on the right turns can
  only come from your shadow log.
- Redaction has a ceiling (above).

## Stop hook facts, measured not read

Claude Code v2.1.278, 2026-09-21. The official docs are wrong on three counts,
so these were established by running it:

| | Docs say | Actually |
|---|---|---|
| Blocking | `exit 2` and print `hookSpecificOutput` JSON on stdout | `exit 2` blocks, but **stdout never reaches the model**. The reason must go to **stderr** |
| `stop_hook_active` | not documented; roll your own counter | **present**, `true` on re-entry |
| `stop_reason`, `scratchpad_dir`, `effort` | provided | **absent** |

Fields actually delivered: `session_id`, `prompt_id`, `transcript_path`, `cwd`,
`permission_mode`, `hook_event_name`, `stop_hook_active`, `last_assistant_message`,
`background_tasks`, `session_crons`.

One more, from the transcript format: every content block of an assistant message
is its own JSONL record, and `promptId` appears only on *user* records. It can
locate where a turn begins; it cannot filter assistant records. Getting that
wrong makes "tools called this turn" read as zero on every turn, which would make
shape 1 fire constantly. See `hooks/turn-tools.jq`.

## Tests

```bash
./tests/acceptance.sh        # 16 cases, no key, no network
./tests/network.sh           # fail-closed paths against a local stub server
./tests/network.sh --live    # also the real endpoint, with synthetic text only
./tests/show-payload.sh 50   # capture what would really be sent, locally
```

Every case drives the real hook with real stdin and asserts on observed exit
codes and stderr. None of them inspect the source. The live cases deliberately
use a synthetic assistant message, so running the suite is not itself a
disclosure.

Two of the cases exist to catch one specific implementation mistake each, and
both were checked against a mutant that makes that mistake:

- **Case 7** — shape 3's regex must run on the raw message. Its declaration
  shares a line with a path, because redaction drops such a line whole. An
  earlier version of this case used a URL and was worthless: URLs are replaced
  in place, the line survives, and a wrong implementation passed it.
- **Case 9** — a missing `background_tasks` key must not read as "nothing is
  running", which would turn shape 3 into "block whenever the regex matches".

## License

MIT
