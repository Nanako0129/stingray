# stingray

**English** | [繁體中文](README.zh-TW.md)

[![tests](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml/badge.svg)](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> A Claude Code `Stop` hook for the turn that ends half-done. It catches the three ways a turn quits early — nothing done, an announced action never carried out, a promise to watch CI with nothing polling — and blocks the stop with a nudge instead of letting the turn close on an empty promise.

Stingrays lie still on the sand and cost you nothing until you step on one. This does the same: silent on a normal turn, a nudge only on a turn that stopped when it should have kept going. Two of the three judgements go to [Jev](https://typesafe.ai); the third is arithmetic, because both halves of it are exact values and turning a certainty into a probability is a downgrade.

```
you:     fix the timeout and run the tests
claude:  I'll change the config value now, then run the suite.
         [turn ends. nothing was changed. nothing was run.]

         ── stingray ──────────────────────────────────────────
         this turn looks like it stopped half-done
         (it declared an action that this turn's tool calls do not account for)

claude:  [edits the config, runs the suite]
```

## Table of Contents

- [What it catches](#what-it-catches)
- [Friction only ever goes up](#friction-only-ever-goes-up)
- [Install](#install)
- [API key](#api-key)
- [Switches (off by default)](#switches-off-by-default)
- [What leaves your machine](#what-leaves-your-machine)
- [Calibration](#calibration)
- [Latency](#latency)
- [Loop protection](#loop-protection)
- [Known limits](#known-limits)
- [Stop hook facts, measured not read](#stop-hook-facts-measured-not-read)
- [Layout](#layout)
- [Tests](#tests)
- [Support](#support)
- [License](#license)

---

## What it catches

| # | Shape | Judged by |
|---|-------|-----------|
| 1 | `no_action` — stopped without doing anything, when it could have acted | [Jev](https://typesafe.ai) |
| 2 | `broken_promise` — declared an action the turn's tool calls don't account for | Jev |
| 3 | `unwatched` — promised to watch CI or a PR review with nothing polling | computed locally |

Shape 3 never reaches a model. Its two halves are a declaration regex over the assistant's own words and the `background_tasks` field the hook is already handed — both exact. The Jev question it replaced scored 20.0% precision at 66.7% false-positive rate against the same corpus; moving it to arithmetic was not a cost.

The nudge is one fixed paragraph, not a generated critique. It offers three ways out — finish the work, launch the polling, or name the decision you are blocked on — because a turn stops half-done for all three reasons and only the model knows which.

## Friction only ever goes up

Every failure path — no key, missing `jq`, missing `questions.json`, an endpoint that is neither HTTPS nor loopback, a secret spotted in the outgoing bytes, a timeout, a non-200, a malformed body, a score outside [0,1] or below threshold, an unreadable `background_tasks`, even a block counter that cannot be written — exits 0 and leaves behaviour exactly as if the plugin were not installed.

stingray can add work. It can never let the model do less. Every failure is fail-open in the literal sense — the turn ends exactly as it would have — and that is the safe direction here, because the thing being withheld is a nudge, not a permission. That single rule is what makes the failure modes boring: there is no configuration in which a broken stingray approves something, and no outage that turns into a silent pass.

## Install

> **Notice:** Every command below is written for **user scope** — install once, use it in every project.

### Claude Code plugin

```bash
# install
claude plugin marketplace add Nanako0129/stingray
claude plugin install stingray@stingray --scope user

# update
claude plugin marketplace update stingray
claude plugin update stingray

# uninstall
claude plugin uninstall stingray
```

> **Tip:** The in-session `/plugin install` dialog asks you to pick a scope — choose **User** there.

> **What "verified" means here:** the manifest and both commands were exercised against a local checkout — the marketplace registers, `plugin install` reports success, and `plugin list` shows `stingray@stingray` enabled at user scope. With no switch exported, a payload that would otherwise fire shape 3 exits 0 and creates no state directory, so a fresh install really is inert. The `Nanako0129/stingray` form was exercised the same way after the merge: marketplace added from GitHub, plugin installed at user scope, and a payload that would otherwise fire shape 3 still exits 0 with no state directory.

**Installing it does nothing on its own.** The hook is off until a switch is set, which is deliberate: a plugin that starts interrupting turns the moment it lands is not something you can evaluate. Pick one and put it where your shell exports it:

```bash
# the free local check: no account, no key, no request
export STINGRAY_SHAPE3=1

# or: call Jev, write a decision record, never block. Start here if you have a key.
export STINGRAY_SHADOW=1
```

Verify it is loaded and doing nothing yet:

```bash
claude plugin list | grep stingray
tail -f ~/.local/state/stingray/decisions.jsonl   # nothing until shadow or active
```

### Or wire the hook by hand

No plugin machinery needed — it is one script:

```bash
git clone https://github.com/Nanako0129/stingray ~/stingray
```

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/bin/bash \"$HOME/stingray/hooks/stingray.sh\"",
                     "timeout": 10 } ] }
    ]
  }
}
```

Always set `timeout`. Claude Code's default for a hook is **600 seconds**, so an endpoint that hangs would hold your turn open for ten minutes.

### Requirements

`bash`, `curl` and `perl` ship with macOS and with any normal Linux. **`jq` does not ship with macOS** and the hook exits 0 without it, printing `(stingray: unavailable — jq not found)`:

```bash
command -v jq || brew install jq      # macOS
command -v jq || sudo apt install jq  # Debian/Ubuntu
```

No SDK, and nothing else to install.

`STINGRAY_ENDPOINT` accepts an HTTPS URL, or plain HTTP only to loopback where the test stubs live. The request carries `Authorization: Bearer`, so anything else would put the key on the wire in cleartext and is refused.

## API key

Shapes 1 and 2 call TypeSafe's System One (`jev-1.13.0`). Shape 3 needs no key and no network.

1. Get a key at <https://typesafe.ai>.
2. Put it in `~/.config/typesafe/api_key` (`chmod 600`), or export `TYPESAFE_API_KEY`. The file is preferred: an environment variable is visible to every process you launch.

**Without a key, stingray behaves exactly as it does when uninstalled.** It prints `(stingray: unavailable — no key; shapes 1/2 skipped)` once per session and keeps shape 3 working. It is never silently inert.

## Switches (off by default)

| Variable | Effect |
|---|---|
| *(nothing set)* | **Default.** The hook exits immediately. Nothing runs, nothing is sent. |
| `STINGRAY_SHADOW=1` | Calls Jev, writes a decision record, **never blocks**. Start here. |
| `STINGRAY=1` | Blocks on shapes 1 and 2. |
| `STINGRAY_SHAPE3=1` | Blocks on shape 3. **Usable on its own**: shape 3 needs no key and no network, so this alone enables the hook without switching on the two Jev judgements, which have their own bar to clear — see [Calibration](#calibration). `STINGRAY_SHADOW=1` outranks it. |

The cheapest useful configuration is `STINGRAY_SHAPE3=1` by itself: no account, no key, and no request — just the check that a promise to watch something has something running behind it. It still reads the payload and runs a regex, so it is not free, only free of network and of TypeSafe.

Other knobs: `STINGRAY_TAU` (0.5), `STINGRAY_TIMEOUT` (6s), `STINGRAY_MAX_BLOCKS` (3 per session), `STINGRAY_STATE_DIR` (`~/.local/state/stingray`), `STINGRAY_REDACT_WORDS` (extra names to mask), `STINGRAY_JEV_MODEL` (`jev-1.13.0`, pinned — `jev-latest` would change the classifier under you).

## What leaves your machine

Three fields, and only when a key is configured:

| Field | Content |
|---|---|
| `final_text` | the last assistant message, redacted, then truncated to the last 2400 **bytes** — about 800 CJK characters, but roughly 2400 characters of plain ASCII, so an English turn sends about three times the text the accuracy figures were measured on |
| `tools` | tool **names** and a count for this turn — never arguments |
| `background` | background task **statuses** — never descriptions, never command lines |

Your prompts are never sent. Tool arguments, file contents and diffs are never sent.

Redaction removes fenced code, block quotes, inline code and URLs, drops any line carrying an absolute path, a relative path or a filename, and masks commit SHAs, issue numbers and project names. Project names are *derived*, not hardcoded: the directory the hook reports and the repository its git remote points at. Sibling projects you mention by name are not discoverable from there — list them in `STINGRAY_REDACT_WORDS` if you want them masked too.

Truncation happens **after** redaction. The other order slices a code fence in half, the pair stops matching, and the whole block leaks.

Before any request leaves, the outgoing bytes are scanned for key material (`sk-`, `ghp_`, `AKIA`, PEM headers). On a hit the request is dropped and the turn proceeds untouched.

### See for yourself, then decide

```bash
./tests/show-payload.sh 50
```

That drives the **real hook** against a local recording server and writes the exact bytes it would put on the wire to `payload-audit.txt`. It reports what is sent, not what the redactor intends to remove. A separate copy of a redactor drifts from the shipped one — that drift already happened here once, and this README promised a rule the code did not have.

### The redaction ceiling, measured on the bytes actually sent

**Redaction does not reach "no private content", and nothing here should be read as if it did.**

Across 48 captured payloads from real turns, every leak category the tool counts came back zero: fenced code, absolute and relative paths, filenames, URLs, commit SHAs, issue numbers, line ranges. A zero there means *not found*, never *clean* — a scan can only find the categories somebody thought of.

What plainly survives is the **substance of the work**. Reading those payloads tells you a quota window was read at 80% while 47 samples in the same window said 77%, that a 60-second blind poll is still running, that six recovery files sit in a directory dated 2026-08-22. Identifiers are gone; what you are building, what is broken, and how you decided to fix it are not.

TypeSafe processes in the United States, retains without a stated limit, and caps liability at USD 50. Decide with that in front of you and with `payload-audit.txt` open. `STINGRAY_SHADOW=1` still sends. Only the default off state sends nothing at all.

## Calibration

Measured offline against 124 turns from one maintainer's real transcripts, labelled by whether that person had to type "keep going" (`jev-1.13.0`, 2026-09-21):

| payload | precision | recall | FPR |
|---|---|---|---|
| **full** (redacted, ~800 chars) | **81.8%** | 14.1% | 3.3% |
| last two sentences only | 61.1% | 17.2% | 11.7% |
| structured flags only | — | — | `no_action` never fires |

Per question, at full payload: `no_action` 85.7% precision at 1.7% FPR; `broken_promise` 66.7% at 3.3%. Cutting the payload to the last two sentences costs 20 points of precision and triples the false-positive rate, which is why the whole message is sent.

High precision with low recall is the right shape here. A wrong nudge costs a wasted turn; a missed one costs nothing at all.

**That experiment cannot settle the question, and it is not presented as if it could.** The labels systematically undercount: a person only sometimes types "keep going" — often they just answer, or move on. Of the two false positives at τ=0.5, reading them showed one was a labelling error rather than a prediction error; ten of eleven hits were correct. A second caveat, stated because this exact divergence has already caused one defect here: the offline experiment ran through a *copy* of the redactor that masked a fixed list of project names, while the shipped one derives them. Treat 81.8% as measured on a near neighbour of what ships, not on it.

Hence: off by default, `STINGRAY_SHADOW=1` as the first setting, and **two independent bars** before either judge is allowed to block. Shape 3 must not ride in on shapes 1 and 2's calibration.

| Judge | Bar before it may block |
|---|---|
| Shapes 1 and 2 (`STINGRAY=1`) | ≥ 40 shadow records, ≥ 70% precision on your own reading, ≤ 3 wrong nudges per 100 stop points, τ placed in the empty band between the score clusters with the derivation written beside it |
| Shape 3 (`STINGRAY_SHAPE3=1`) | ≥ 20 shadow records, ≥ 70% precision |

Records land in `$STINGRAY_STATE_DIR/decisions.jsonl`, one line per decision, each carrying `qset_hash` — the hash of `questions.json`, not of the request. Editing one line of criteria moves the whole score distribution, so a threshold calibrated under the old wording is void, and a hash that changed every turn could not show you that. It hashed the request body until CodeRabbit pointed out that this made it useless for the one job it has.

## Latency

Measured at the hook position in shadow mode, not with a bare `curl`, because what matters is what the turn waits for. Taiwan to `api.typesafe.ai`, three separate runs of 20:

| | p50 | p95 | budget |
|---|---|---|---|
| shadow mode | 0.742–0.760s | 0.818–0.888s | 1.0s |

A range rather than one number, because the exact figure is not reproducible across runs and a single decimal would imply otherwise.

The budget applies to shadow too: shadow is where you will spend most of your time and it pays the same round trip. If your p95 exceeds it, turn the plugin off or lower `STINGRAY_TIMEOUT` — dropping back to shadow does not remove the latency, so it is not a remedy.

That budget covers the healthy case only. When the endpoint hangs, the turn waits for `STINGRAY_TIMEOUT` and then proceeds: **measured at 6.15s with the shipped default**, against a stub that accepts and never answers. Lower the timeout if that is too long to pay on a bad day.

## Loop protection

Two guards, because one boolean is a single point of failure whose failure direction is an infinite loop:

1. `stop_hook_active` from the harness — true on re-entry, so a nudge is never applied twice to the same stop.
2. A per-session block budget (3 by default) that does not depend on the first.

## Known limits

- The Jev criteria in `questions.json` are written in Traditional Chinese, because that is the corpus the 81.8% was measured on. English criteria are untested and would void that number. If you work in English, expect to rewrite them and recalibrate.
- Shape 3's accuracy cannot be measured offline at all: its evidence, `background_tasks`, exists only at the moment the hook runs and cannot be reconstructed from a transcript. The test suite proves the branch behaves correctly on synthetic input; whether it fires on the right turns can only come from your shadow log.
- Redaction has a measured ceiling, described above.

## Stop hook facts, measured not read

Claude Code v2.1.278, 2026-09-21. The official documentation is wrong on three counts, so these were established by running it:

| | Docs say | Actually |
|---|---|---|
| Blocking | `exit 2` and print `hookSpecificOutput` JSON on stdout | `exit 2` blocks, but **stdout never reaches the model**. The reason must go to **stderr** |
| `stop_hook_active` | not documented; roll your own counter | **present**, `true` on re-entry |
| `stop_reason`, `scratchpad_dir`, `effort` | provided | **absent** |

Fields actually delivered: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`.

One more, from the transcript format: every content block of an assistant message is its own JSONL record, and `promptId` appears only on *user* records. It can locate where a turn begins; it cannot filter assistant records. Getting that wrong makes "tools called this turn" read as zero on every turn, which would make shape 1 fire constantly. See [`hooks/turn-tools.jq`](hooks/turn-tools.jq).

## Layout

```text
stingray/
├── .claude-plugin/plugin.json   # Claude Code packaging
├── .coderabbit.yaml             # review instructions, and the dated expiry of auto-review at <10 stars
├── .github/workflows/tests.yml  # offline suites + mutation checks, Linux and macOS
├── hooks/
│   ├── hooks.json               # Stop hook registration, explicit timeout
│   ├── stingray.sh              # the whole thing: shapes, redaction, fail-open paths, nudge
│   └── turn-tools.jq            # slice one turn out of the transcript
├── questions.json               # the two Jev criteria — the classifier's contract, pinned to jev-1.13.0
└── tests/
    ├── acceptance.sh            # drives the real hook offline: no key, no network
    ├── network.sh               # fail-open paths; --live also hits the real endpoint
    ├── mutants.sh               # re-derives that each guard still fails when broken
    ├── show-payload.sh          # capture what would really be sent, locally
    ├── stub_server.py           # local stand-in for the endpoint; --list-modes lists its modes
    └── latency.py               # p50/p95 against a budget, exits non-zero over it
```

## Tests

```bash
./tests/acceptance.sh        # drives the real hook offline: no key, no network
./tests/network.sh           # fail-open paths against a local stub server
./tests/network.sh --live    # also the real endpoint, with synthetic text only
./tests/mutants.sh           # do the guards still guard?
./tests/show-payload.sh 50   # capture what would really be sent, locally
```

Every case drives the real hook with real stdin and asserts on observed exit codes and stderr. None of them inspect the source. The live cases deliberately use a synthetic assistant message, so running the suite is not itself a disclosure.

Two cases exist to catch one specific implementation mistake each, and `mutants.sh` re-introduces that mistake and requires the case to fail:

- **Case 7** — shape 3's regex must run on the raw message. Its declaration shares a line with a path, because redaction drops such a line whole. An earlier version used a URL and was worthless: URLs are replaced in place, the line survives, and a wrong implementation passed it. That is why the mutation check exists rather than a note in a comment.
- **Case 9** — a missing `background_tasks` key must not read as "nothing is running", which would turn shape 3 into "block whenever the regex matches".

## Support

stingray is free and needs no account. The one running cost it can incur is yours, not the project's: TypeSafe charges $0.042 per million input tokens, and a turn sends well under a thousand. You can support the maintainer on Patreon.

[![Support on Patreon](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

## License

MIT
