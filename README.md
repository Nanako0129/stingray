# stingray

**English** | [繁體中文](README.zh-TW.md)

[![tests](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml/badge.svg)](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> A Claude Code `Stop` hook for turns that stop half-done. It catches three premature exit patterns — stopping without taking action, declaring an action without calling the tools to back it up, and claiming to monitor background work while nothing is running — and intercepts the exit with a nudge so the turn does not close on an empty promise.

Stingrays sit motionless on sand until stepped on. This hook operates the same way: silent during normal operation, intervening only when a turn stops prematurely. Every judgement goes to [Jev](https://typesafe.ai): whether the turn did nothing, broke a promise, promised to watch something, or answered in the wrong language. The one thing counted locally is what is running in the background.

```
you:     fix the timeout and run the suite
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
| 2 | `broken_promise` — declared an action that this turn's tool calls do not account for | Jev |
| 3 | `unwatched` — promised to monitor external progress (CI, build, PR review) | Jev, against a local count (see below) |
| 4 | `wrong_language` — the final message is not in the language your settings ask for | Jev |

Shape 3 asks Jev whether the final message promises to watch an external result, or says a watch it set up is running (`watch_claim`), and acts on the answer against a count it makes locally:

- **Nothing running:** running background tasks plus `session_crons` **equals 0**. A promise with nothing behind it blocks on `STINGRAY_SHAPE3=1`.
- **Something running:** the count **is greater than 0**, which does not say whether the running work is what was promised — a background build satisfies it while a promised PR review goes unwatched. Jev is asked that too (`watch_mismatch`, in the same request), and it blocks only on `STINGRAY_SHAPE3_JUDGE=1`.

The count is exact; the promise is a judgement. It was a set of regular expressions until 0.3.0, and those read topic rather than commitment: a reply that merely quoted the phrase "keep an eye on" blocked itself, while "I'll keep monitoring the build" and any promise in Japanese or Korean passed unseen. On 59 labelled lines — including every sentence that once blocked a real turn by mistake — Jev scored the promises at 0.48 and above and the rest at 0.18 and below.

The nudge delivered on interception is a fixed paragraph written to stderr, not a dynamically generated critique. It offers three ways out: finish the work, launch a background poll, or state what decision is blocking progress.

Shape 4 reads `language` from Claude Code's settings — the project's `.claude/settings.local.json`, then its `.claude/settings.json`, then your user `settings.json` under `CLAUDE_CONFIG_DIR` — and asks Jev whether the prose of the final message is written in it. Any target language works; common codes such as `zh-TW` are sent as a name, `繁體中文（台灣，zh-TW）`, which Jev reads far more reliably than the bare code. Its nudge asks for the same message again in that language, with code and identifiers left as they were.

A message is asked about only when it has prose to judge — at least 12 units once code, inline code, URLs, block quotes and paths are removed, a unit being one Han, kana or Hangul character or one word in any other script. Without that floor, a line of test results was judged "not Chinese", which is true and useless.

It needs an API key, like shapes 1 and 2, and sends the same redacted final message they do. It replaced a local rule that counted Han characters against English words, which could only ever see English: Japanese scored as Chinese, and Korean or Russian as nothing at all.

## Friction only ever goes up

Every failure path exits 0: missing API keys, absent `jq`, missing `questions.json`, endpoints that are neither HTTPS nor loopback, credential patterns spotted in outgoing payloads, timeouts, non-200 responses, malformed bodies, scores outside [0, 1] or below threshold, unreadable `background_tasks`, or failures writing the interception counter.

In every failure mode, stingray leaves session behavior identical to an environment where the plugin was never installed. The hook can prompt additional work; it can never permit less. Every failure fails open by allowing the turn to conclude normally. Because the hook withholds an intervention rather than granting a permission, a defective configuration cannot approve work. An outage does mean the check did not run and the turn ended unexamined — the same position you are in without the plugin, which is why this direction is the safe one, but it is not the same as the turn having been checked.

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

> **Verification details:** The manifest and installation commands were tested against a local checkout: the marketplace registered, `plugin install` reported success, and `plugin list` showed `stingray@stingray` enabled at user scope. With no switches set, a payload that would otherwise trigger shape 3 exited 0 and created no state directory. The `Nanako0129/stingray` syntax was verified the same way after merging: added from GitHub, installed at user scope, and confirmed to exit 0 without writing state files.

**Installation alone performs no actions.** The hook remains inactive until a switch is set. Set switches in the `env` block of `~/.claude/settings.json`:

```json
{
  "env": {
    "STINGRAY_SHAPE3": "1",
    "STINGRAY_LANG": "1"
  }
}
```

`STINGRAY_SHAPE3` is the watch check and `STINGRAY_LANG` the language check. Both are judged by Jev, so both need an API key and send the redacted final message; there is no keyless mode. With an API key, start from `"STINGRAY_SHADOW": "1"` instead, which calls Jev and logs decision records but never blocks turn completion. Restart Claude Code after changing the file.

> **Why not `export` in your shell:** Claude Code reads `settings.json` itself when it starts, so every session gets the switches however it was launched. A shell `export` reaches only sessions started from a shell opened after the line was added. A terminal tab left open from before, the desktop app and IDE extensions all miss it, and the hook then does nothing without saying so. This was hit in practice: a tab open for eight days kept launching sessions with none of the switches set.

Verify that the plugin is loaded:

```bash
claude plugin list | grep stingray
tail -f ~/.local/state/stingray/decisions.jsonl   # written by shape 3 too, before it blocks
```

### Manual hook configuration

The hook can be wired directly as a shell script:

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

Always set `timeout`. Claude Code's default hook timeout is **600 seconds**; an explicit value prevents an unresponsive endpoint from holding a turn open for ten minutes.

### Requirements

`bash`, `curl`, and `perl` ship with macOS and standard Linux distributions. **`jq` is not pre-installed on macOS**. Without `jq`, the hook exits 0 before evaluating any shape, printing `(stingray: unavailable — jq not found)`:

```bash
command -v jq || brew install jq      # macOS
command -v jq || sudo apt install jq  # Debian/Ubuntu
```

No SDK or additional runtime is required.

`STINGRAY_ENDPOINT` accepts HTTPS URLs, or plain HTTP restricted to loopback where local test servers run. Outgoing requests carry `Authorization: Bearer`; unencrypted requests to non-loopback destinations are rejected to avoid transmitting keys over plaintext connections.

## API key

Every check calls TypeSafe System One (`jev-1.13.0`): shapes 1 and 2, shape 3's promise and correspondence judgements, and the language check.

1. Obtain a key at <https://typesafe.ai>.
2. Place it in `~/.config/typesafe/api_key` (`chmod 600`), or export `TYPESAFE_API_KEY`. The configuration file is preferred because environment variables are exposed to child processes.

**Without an API key, stingray does nothing.** It outputs `(stingray: unavailable — no key; Jev checks skipped)` once per session rather than failing silently.

## Switches (off by default)

Each switch controls evaluation and interception behavior. By default, all switches are unset; the hook exits immediately without running evaluations, issuing requests, or creating files.

Precedence and execution rules:

1. **Unset (default):** Exits 0 immediately. Nothing runs, nothing is sent, and no state files are created.
2. **`STINGRAY_SHAPE3=1` (watch check):** Blocks turn completion when Jev judges the final message to promise a watch and nothing is running or scheduled. Needs an API key and sends the redacted final message. Does not ask shapes 1 and 2.
3. **`STINGRAY_SHADOW=1` (shadow mode, highest precedence):** Evaluates shapes 1 and 2 via Jev and writes decision records to disk, but **never blocks turn completion**. Overrides blocking behavior from both `STINGRAY=1` and `STINGRAY_SHAPE3=1`. Start here once you configure an API key.
4. **`STINGRAY=1` (active mode):** Blocks turn completion on shapes 1 and 2 when Jev flags unfulfilled promises or missing actions.
5. **`STINGRAY_LANG=1` (language check):** Blocks turn completion when Jev judges the final message not to be in the configured `language`. Needs an API key and sends the redacted final message with one question; with `STINGRAY=1` on too, it rides in the same request. It does not turn shape 3 on, and does not ask shapes 1 and 2.
6. **`STINGRAY_SHAPE3_JUDGE=1` (shape 3 correspondence judgement):** Allows shape 3 to block turn completion when background work is running but Jev judges it not to be what was promised. Requires `STINGRAY_SHAPE3=1` and non-shadow mode. Defaults to off even when shape 3 is active, because its threshold is borrowed without dedicated offline measurement.

| Variable | Effect |
|---|---|
| *(nothing set)* | **Default.** Hook exits immediately (code 0). Nothing runs, nothing is sent, no state files created. |
| `STINGRAY_SHADOW=1` | Calls Jev, logs decision records, **never blocks turn completion**. Outranks `STINGRAY=1`, `STINGRAY_SHAPE3=1` and `STINGRAY_LANG=1`. Start here. |
| `STINGRAY=1` | Blocks turn completion on shapes 1 and 2 via Jev. |
| `STINGRAY_SHAPE3=1` | Blocks turn completion when Jev judges a promise to watch and nothing is running or scheduled. Needs a key; sends the redacted final message. Outranked by `STINGRAY_SHADOW=1`. |
| `STINGRAY_LANG=1` | Blocks turn completion on shape 4, a final message Jev judges not to be in the configured `language`. Needs a key; sends the redacted final message. Outranked by `STINGRAY_SHADOW=1`, which records it instead. |
| `STINGRAY_SHAPE3_JUDGE=1` | Allows shape 3's **correspondence judgement** to block turn completion (active tasks > 0, but model judges they do not match the promise). Off by default; requires `STINGRAY_SHAPE3=1`. Logs decisions regardless of switch state. |

The smallest configuration is `STINGRAY_SHAPE3=1` alone: one question per turn, about whether the reply promised a watch. When something is running in the background, a second one (`watch_mismatch`) rides in the same request, carrying the tool list and background statuses as well, and is logged even while `STINGRAY_SHAPE3_JUDGE` is off.

Additional configuration options: `STINGRAY_TAU` (0.5), `STINGRAY_TIMEOUT` (6s), `STINGRAY_MAX_BLOCKS` (3 per session), `STINGRAY_STATE_DIR` (`~/.local/state/stingray`), `STINGRAY_REDACT_WORDS` (extra terms to mask), and `STINGRAY_JEV_MODEL` (`jev-1.13.0`, pinned to prevent unannounced classifier changes).

## What leaves your machine

Only these fields are transmitted, and only when an API key is configured:

| Field | Content |
|---|---|
| `final_text` | The last assistant message, redacted, then truncated to the last 2400 **bytes** — roughly 800 CJK characters, but approximately 2400 ASCII characters. An English turn transmits roughly three times the character volume used in benchmark evaluations. |
| `tools` | Tool **names** and invocation counts for this turn, excluding arguments. |
| `background` | For each background task: status and **description**. For each scheduled cron: the assigned **prompt**. Both undergo message redaction after stripping credential patterns. Command lines are never sent. |
| `language` | The configured language, as a name — on the language question only, which carries this and `final_text` and nothing else. |

User prompts sent to Claude are never transmitted. Tool arguments, file contents, diffs, and executed command lines are never transmitted.

**Scheduled cron prompts are transmitted.** Determining whether scheduled work matches what was promised requires reading the instructions assigned to that cron.

Redaction strips fenced code, block quotes, inline code spans, and URLs. It drops any line containing absolute paths, relative paths, or filenames, and masks commit SHAs, issue numbers, and project names. Project names are derived dynamically from the local working directory and git remote URL. Mentioned sibling projects cannot be inferred automatically; list them in `STINGRAY_REDACT_WORDS` if masking is required.

Truncation occurs **after** redaction. Performing truncation first can split code fences, breaking delimiter balance and causing code blocks to leak.

Before transmission, outbound bytes pass through two credential checks:
1. The redaction pipeline strips `Authorization` headers, bare Bearer or Basic tokens, fields named `api_key`, `auth_token`, `secret`, or `password`, and `github_pat_`.
2. A pre-flight scan checks outgoing bytes for `sk-`, `gh[pousr]_`, `github_pat_`, `AKIA`, and PEM headers. Any match cancels the request and lets the turn proceed untouched.

### Inspecting wire payloads

```bash
./tests/show-payload.sh 50
```

This command runs the actual hook against a local recording server, writing the exact wire bytes to `payload-audit.txt`. It inspects actual network payloads rather than expected filter behavior.

### Redaction ceiling

**Redaction does not achieve "zero private content", and no description here implies that standard.**

Across 48 captured payloads from real turns, all eight tracked leak categories returned zero: fenced code, absolute and relative paths, filenames, URLs, commit SHAs, issue numbers, and line ranges. A zero indicates predefined patterns were *not found*, never that the payload is *clean*.

The **substance of the work survives transmission**. Reading those payloads reveals that a quota window was measured at 80% while 47 samples in the same window reported 77%, that a 60-second blind poll was running, and that six recovery files dated 2026-08-22 were present in a directory. Identifiers were masked; the operational task, the error encountered, and the planned resolution remained legible.

TypeSafe processes requests in the United States and does not publish a retention limit. Its Master Customer Agreement caps liability low enough that a leak leaves no practical financial remedy. Read the current terms rather than this summary of them — the terms change and the summary will not. Review `payload-audit.txt` before deciding to enable outbound requests. `STINGRAY_SHADOW=1` transmits data over the wire. No outbound request is made by default. Every switch sends the redacted final message once it has something to ask about it.

## Calibration

Offline measurement against 124 turns from maintainer transcripts, labelled by whether the user typed "keep going" (`jev-1.13.0`, 2026-09-21):

| payload | precision | recall | FPR |
|---|---|---|---|
| **full** (redacted, ~800 chars) | **81.8%** | 14.1% | 3.3% |
| last two sentences only | 61.1% | 17.2% | 11.7% |
| structured flags only | — | — | `no_action` never fires |

Per question, at full payload: `no_action` achieved 85.7% precision at 1.7% FPR; `broken_promise` achieved 66.7% at 3.3%. Restricting the payload to the last two sentences reduced precision by 20 percentage points and tripled false positives, which is why the full redacted message is sent.

High precision paired with low recall fits this design: an erroneous nudge wastes a turn, whereas a missed nudge leaves execution unchanged.

**This experiment does not settle model accuracy.** The measurement carries three specific limitations:
1. Labels systematically undercount positive cases: users only sometimes type "keep going", often answering directly or continuing manually.
2. For the two false positives observed at τ=0.5, manual review showed one was a labeling error rather than an incorrect prediction; 10 of 11 positive flags were accurate under human review.
3. The offline benchmark ran through a *copy* of the redactor that masked a hardcoded project list, whereas the shipped version derives names dynamically. The 81.8% figure was measured on a close neighbor of the shipped code, not on the exact implementation.
4. It was measured on requests that batched several turns, each asked shapes 1 and 2 and an earlier shape 3 question. The shipped request carries one turn and only the questions its switches and background call for. Measured on 6 inputs, twice each, with and without `watch_claim` and `wrong_language` alongside: the mean of either score moved by at most 0.04, the same as the most the identical request moved when sent twice (0.04), and no input moved across τ. Six inputs show no large effect, not no effect.

**Shape 3's promise judgement was measured on 59 labelled lines** — the 44 of `tests/watch-fixture.tsv` and 15 synthetic — by sending the question to Jev directly. `tests/watch-fixture.sh` re-runs the 44 fixture lines, not the 15, live through the shipped hook: at τ = 0.5 it agrees on 42 of the 43 it scores. The 44th names a file, so redaction removes it and it is never asked (see Known limits). **Its correspondence judgement has never been evaluated.** Its threshold is borrowed from the other questions without independent validation.

Two independent bars govern activation before either evaluator may block turn completion:

| Judge | Bar before blocking turn completion |
|---|---|
| Shapes 1 and 2 (`STINGRAY=1`) | ≥ 40 shadow records, ≥ 70% precision on manual inspection, ≤ 3 false nudges per 100 stop points, τ placed in the empty band between score clusters with derivation documented |
| Shape 3, promise (`STINGRAY_SHAPE3=1`) | None set. Measured on 59 labelled lines, and blocks from the first turn — see known limits |
| Shape 3, correspondence (`STINGRAY_SHAPE3_JUDGE=1`) | ≥ 20 shadow records, ≥ 70% precision on manual inspection |
| Shape 4, language (`STINGRAY_LANG=1`) | None set. Measured only on 20 synthetic replies, and blocks from the first turn — see known limits |

Records land in `$STINGRAY_STATE_DIR/decisions.jsonl`, one line per decision, tagged with `qset_hash` — the SHA-256 hash of `questions.json`, **not the hash of the request**. Modifying criteria shifts score distributions, voiding thresholds calibrated under earlier phrasing; a per-request hash would vary on every turn and could not detect criteria drift.

## Latency

Measured at hook position in shadow mode between Taiwan and `api.typesafe.ai`, across three separate runs of 20 requests:

| | p50 | p95 | budget |
|---|---|---|---|
| shadow mode | 0.742–0.760s | 0.818–0.888s | 1.0s |

Results are reported as ranges because network latency cannot be reproduced to a single decimal across runs.

The 1.0-second budget applies to shadow mode as well: shadow mode executes the same network round trip. If your p95 exceeds this budget, disable the hook or lower `STINGRAY_TIMEOUT`. Reverting to shadow mode does not remove latency.

This budget covers healthy endpoints. When an endpoint hangs, execution waits until `STINGRAY_TIMEOUT`: **measured at 6.15s with the default 6-second timeout** against an unresponsive stub server. Lower `STINGRAY_TIMEOUT` if that delay is unacceptable during outages.

With `STINGRAY_SHAPE3=1` or `STINGRAY_LANG=1` alone, every turn with something to ask about makes this round trip too, where until 0.2.0 or 0.3.0 respectively it made none. A request carrying one question took 0.68–1.03s across 12 calls, measured by calling the endpoint directly with the same request shape rather than at hook position; through the shipped hook, 0.70–0.99s. With several switches on, their questions share one request, adding no round trip.

## Loop protection

Two distinct guards prevent execution loops, avoiding single points of failure:

1. `stop_hook_active` from the harness evaluates to `true` on re-entry, preventing consecutive interventions on the same stop event.
2. A per-session interception limit (`STINGRAY_MAX_BLOCKS`, default 3) enforced independently of the harness flag.

## Known limits

- Criteria in `questions.json` are written in Traditional Chinese, matching the corpus used for the 81.8% benchmark. English criteria have zero live measurements; replacing them voids that accuracy figure. Working in English requires rewriting criteria and recalibrating thresholds.
- Shape 3's correspondence cannot be measured offline: `background_tasks` exists only at hook execution and cannot be reconstructed from saved transcripts. Its promise judgement can, and is — see `tests/watch-fixture.sh`.
- Shape 3 cannot see a promise written on the same line as a file path. Redaction drops that line before Jev reads the message, and when nothing else is left the turn is not asked about at all. Measured through the shipped hook: "我會盯著 src/main.rs 的 CI 結果" was not asked about, while the same promise with the path on its own line was blocked at 0.97. The regular expression it replaced read the raw message and did see it; this is the one thing given up.
- "keep an eye on the review" scores 0.48 and passes. Without a subject it reads as well as an instruction to the user.
- Redaction leaves the substance of the work visible, as detailed in the privacy section.
- Shape 4 has been measured on synthetic replies only, 20 of them, and no real transcript was sent to measure it. zh-TW replies scored 0.10–0.23, including one made of identifiers and one quoting English; English, Japanese, Korean and Russian replies 0.97–0.98; English quoting Chinese terms 0.77; the wrong target in either direction 0.95–0.98. τ is the shared 0.5. How it scores on your own writing is what `decisions.jsonl` will show — its records are `wrong_language` and `language_ok`.
- Shape 4 does not reliably tell Simplified from Traditional Chinese: a Simplified reply against a zh-TW setting scored 0.29.
- The harness writes its own English notices into the transcript as assistant text — "You've hit your session limit …", "API Error: Connection lost mid-response …". The hooks reference says a turn ending on an API error fires `StopFailure`, not `Stop`, which would keep them away from this hook. That is documented, not measured. If one does arrive, shape 4 judges it once and the re-entry guard stops a second.
- `network.sh --live` encountered an 8/9 result on a single test run; five subsequent reruns could not reproduce the failure, and the failing check was not identified. This occurrence is documented in test comments.

## Stop hook facts, measured not read

Claude Code v2.1.278, 2026-09-21. Official documentation differs on three counts, established by live execution:

| Item | Docs say | Reality |
|---|---|---|
| Blocking turn completion | `exit 2` and print `hookSpecificOutput` JSON on stdout | `exit 2` blocks the turn, but **stdout never reaches the model**. The reason must go to **stderr** |
| `stop_hook_active` | Undocumented; implement custom tracking | **Present**, evaluates to `true` on re-entry |
| `stop_reason`, `scratchpad_dir`, `effort` | Provided in payload | **Absent** |

Fields delivered to the hook: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `stop_hook_active`, `last_assistant_message`, `background_tasks`, and `session_crons`.

Transcript record handling: each content block of an assistant message is written as an independent JSONL record, and `promptId` appears only on user records. Filtering assistant records by `promptId` causes turn tool counts to evaluate to zero every turn, triggering constant false positives on shape 1. See [`hooks/turn-tools.jq`](hooks/turn-tools.jq).

## Layout

```text
stingray/
├── .claude-plugin/              # plugin.json and marketplace.json
├── .coderabbit.yaml             # review instructions, and the dated expiry of auto-review at <10 stars
├── .github/workflows/tests.yml  # offline suites + mutation checks, Linux and macOS
├── hooks/
│   ├── hooks.json               # Stop hook registration, explicit timeout
│   ├── stingray.sh              # the whole thing: shapes, redaction, fail-open paths, nudge
│   └── turn-tools.jq            # slice one turn out of the transcript
├── questions.json               # the five Jev questions — the classifier's contract, pinned to jev-1.13.0
└── tests/
    ├── acceptance.sh            # drives the real hook against local stubs; no key, no network
    ├── network.sh               # fail-open paths; --live also hits the real endpoint
    ├── watch-fixture.sh         # live calibration of shape 3 on watch-fixture.tsv; needs a key
    ├── hook-shell.sh            # runs the hook on the interpreter hooks.json ships
    ├── mutants.sh               # re-derives that each guard still fails when broken
    ├── show-payload.sh          # capture what would really be sent, locally
    ├── stub_server.py           # local stand-in for the endpoint; --list-modes lists its modes
    └── latency.py               # p50/p95 against a budget, exits non-zero over it
```

## Tests

```bash
./tests/acceptance.sh        # drives the real hook against local stubs: no key, no network
./tests/network.sh           # fail-open paths against a local stub server
./tests/network.sh --live    # also the real endpoint, with synthetic text only
./tests/mutants.sh           # do the guards still guard?
./tests/show-payload.sh 50   # capture what would really be sent, locally
./tests/watch-fixture.sh     # shape 3 against the real endpoint on labelled lines; needs a key
```

Tests drive the actual hook with real stdin and assert on exit codes and stderr. No test inspects source code directly. Live tests send synthetic text to avoid leaking conversation data.

Two test cases guard against specific implementation errors, verified by `mutants.sh`:

- **Case 8:** With a poll running, a promise judged made must not block. Ignoring the count would block every promise as if nothing ran.
- **Case 9:** A missing `background_tasks` key must not evaluate as "nothing is running", which would cause shape 3 to block whenever a promise is judged.

## Support

stingray is free and requires no account. The only operating cost is your own TypeSafe API usage ($0.042 per million input tokens; an average turn consumes well under 1,000 tokens). You can support the maintainer on Patreon.

[![Support on Patreon](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

## License

MIT
