# stingray

**English** | [繁體中文](README.zh-TW.md)

[![tests](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml/badge.svg)](https://github.com/Nanako0129/stingray/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> A Claude Code `Stop` hook for turns that stop half-done. It catches three premature exit patterns — stopping without taking action, declaring an action without calling the tools to back it up, and claiming to monitor background work while nothing is running — and intercepts the exit with a nudge so the turn does not close on an empty promise.

Stingrays sit motionless on sand until stepped on. This hook operates the same way: silent during normal operation, intervening only when a turn stops prematurely. Shapes 1 and 2 are language evaluations handled by [Jev](https://typesafe.ai). Shape 3 checks local process counts first; only when background work is active does it consult a model to verify correspondence.

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
| 3 | `unwatched` — promised to monitor external progress (CI, build, PR review) | Computed locally or Jev (see below) |

Shape 3 separates into two distinct layers:

- **Certain layer:** The assistant declared an intent to monitor background work, but running background tasks plus `session_crons` **equals 0**. This condition is settled by local arithmetic without an API key or network access. Setting `STINGRAY_SHAPE3=1` alone runs this check.
- **Judgement layer:** Running background tasks plus `session_crons` **is greater than 0**. Counting processes cannot determine whether running jobs match what was promised. A background build satisfies a non-zero count while leaving a promised PR review unmonitored. Evaluating whether running work corresponds to the promise requires language interpretation, which is sent to Jev under the `watch_mismatch` evaluation. Without an API key, this evaluation is skipped, preserving existing behavior.

Earlier documentation stated both halves of shape 3 were exact values. That claim was incorrect. `background_tasks` is an exact field provided by the harness, but detecting whether an assistant declared an intent to monitor work relies on regular expression approximations.

The nudge delivered on interception is a fixed paragraph written to stderr, not a dynamically generated critique. It offers three ways out: finish the work, launch a background poll, or state what decision is blocking progress.

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

> **Verification details:** The manifest and installation commands were tested against a local checkout: the marketplace registered, `plugin install` reported success, and `plugin list` showed `stingray@stingray` enabled at user scope. With no switches exported, a payload that would otherwise trigger shape 3 exited 0 and created no state directory. The `Nanako0129/stingray` syntax was verified the same way after merging: added from GitHub, installed at user scope, and confirmed to exit 0 without writing state files.

**Installation alone performs no actions.** The hook remains inactive until a switch is exported:

```bash
# free local check: no account, no key, no network requests
export STINGRAY_SHAPE3=1

# or: call Jev, log decision records, never block turn completion. Start here with an API key.
export STINGRAY_SHADOW=1
```

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

Shapes 1 and 2 call TypeSafe System One (`jev-1.13.0`). Shape 3's **certain** case — a promise with no active tasks or scheduled crons — requires neither an API key nor network access. The correspondence judgement requires both, as it asks the model whether running jobs match what was promised.

1. Obtain a key at <https://typesafe.ai>.
2. Place it in `~/.config/typesafe/api_key` (`chmod 600`), or export `TYPESAFE_API_KEY`. The configuration file is preferred because environment variables are exposed to child processes.

**Without an API key, stingray leaves shapes 1 and 2 inactive.** It outputs `(stingray: unavailable — no key; shapes 1/2 skipped)` once per session while keeping shape 3's local check operational. It does not fail silently.

## Switches (off by default)

Each switch controls evaluation and interception behavior. By default, all switches are unset; the hook exits immediately without running evaluations, issuing requests, or creating files.

Precedence and execution rules:

1. **Unset (default):** Exits 0 immediately. Nothing runs, nothing is sent, and no state files are created.
2. **`STINGRAY_SHAPE3=1` (local arithmetic check):** Intercepts turn completion on shape 3's certain case alone (promised to monitor work, but active tasks plus scheduled crons equal 0). Requires no account, no key, and no network requests.
3. **`STINGRAY_SHADOW=1` (shadow mode, highest precedence):** Evaluates shapes 1 and 2 via Jev and writes decision records to disk, but **never blocks turn completion**. Overrides blocking behavior from both `STINGRAY=1` and `STINGRAY_SHAPE3=1`. Start here once you configure an API key.
4. **`STINGRAY=1` (active mode):** Blocks turn completion on shapes 1 and 2 when Jev flags unfulfilled promises or missing actions.
5. **`STINGRAY_SHAPE3_JUDGE=1` (shape 3 correspondence judgement):** Allows the model evaluation for shape 3 to block turn completion when background work is running but does not match the promise. Requires `STINGRAY_SHAPE3=1` and non-shadow mode. Defaults to off even when shape 3 is active, because its threshold is borrowed without dedicated offline measurement.

| Variable | Effect |
|---|---|
| *(nothing set)* | **Default.** Hook exits immediately (code 0). Nothing runs, nothing is sent, no state files created. |
| `STINGRAY_SHADOW=1` | Calls Jev, logs decision records, **never blocks turn completion**. Outranks `STINGRAY=1` and `STINGRAY_SHAPE3=1`. Start here. |
| `STINGRAY=1` | Blocks turn completion on shapes 1 and 2 via Jev. |
| `STINGRAY_SHAPE3=1` | Blocks turn completion on shape 3's **certain** case (promised to watch work, but active background tasks + scheduled crons == 0). Needs no key and no network. Outranked by `STINGRAY_SHADOW=1`. |
| `STINGRAY_SHAPE3_JUDGE=1` | Allows shape 3's **correspondence judgement** to block turn completion (active tasks > 0, but model judges they do not match the promise). Off by default; requires `STINGRAY_SHAPE3=1` and `STINGRAY=1`. In shape-3-only mode the hook exits before the request path, so this judgement never runs there. Logs decisions regardless of switch state. |

The minimal working configuration is `STINGRAY_SHAPE3=1` alone: no external account, no API key, and no outbound requests. It reads the local payload and runs regular expressions against the message, so execution overhead is non-zero, but isolated from network dependencies.

Additional configuration options: `STINGRAY_TAU` (0.5), `STINGRAY_TIMEOUT` (6s), `STINGRAY_MAX_BLOCKS` (3 per session), `STINGRAY_STATE_DIR` (`~/.local/state/stingray`), `STINGRAY_REDACT_WORDS` (extra terms to mask), and `STINGRAY_JEV_MODEL` (`jev-1.13.0`, pinned to prevent unannounced classifier changes).

## What leaves your machine

Only three fields are transmitted, and only when an API key is configured:

| Field | Content |
|---|---|
| `final_text` | The last assistant message, redacted, then truncated to the last 2400 **bytes** — roughly 800 CJK characters, but approximately 2400 ASCII characters. An English turn transmits roughly three times the character volume used in benchmark evaluations. |
| `tools` | Tool **names** and invocation counts for this turn, excluding arguments. |
| `background` | For each background task: status and **description**. For each scheduled cron: the assigned **prompt**. Both undergo message redaction after stripping credential patterns. Command lines are never sent. |

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

TypeSafe processes requests in the United States and does not publish a retention limit. Its Master Customer Agreement caps liability at the **greater of** what you paid it in the previous twelve months and USD 50 — so USD 50 is the floor, and it is the whole cap only while you have paid nothing. Review `payload-audit.txt` before deciding to enable outbound requests. `STINGRAY_SHADOW=1` transmits data over the wire. Two states make no outbound request at all: the default unset state, and `STINGRAY_SHAPE3=1` on its own, which exits before the request path.

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

**Shape 3 correspondence has never been evaluated offline.** Its threshold is borrowed from the other two questions without independent validation.

Two independent bars govern activation before either evaluator may block turn completion:

| Judge | Bar before blocking turn completion |
|---|---|
| Shapes 1 and 2 (`STINGRAY=1`) | ≥ 40 shadow records, ≥ 70% precision on manual inspection, ≤ 3 false nudges per 100 stop points, τ placed in the empty band between score clusters with derivation documented |
| Shape 3, certain case (`STINGRAY_SHAPE3=1`) | None — pure arithmetic, no threshold to calibrate |
| Shape 3, correspondence (`STINGRAY_SHAPE3_JUDGE=1`) | ≥ 20 shadow records, ≥ 70% precision on manual inspection |

Records land in `$STINGRAY_STATE_DIR/decisions.jsonl`, one line per decision, tagged with `qset_hash` — the SHA-256 hash of `questions.json`, **not the hash of the request**. Modifying criteria shifts score distributions, voiding thresholds calibrated under earlier phrasing; a per-request hash would vary on every turn and could not detect criteria drift.

## Latency

Measured at hook position in shadow mode between Taiwan and `api.typesafe.ai`, across three separate runs of 20 requests:

| | p50 | p95 | budget |
|---|---|---|---|
| shadow mode | 0.742–0.760s | 0.818–0.888s | 1.0s |

Results are reported as ranges because network latency cannot be reproduced to a single decimal across runs.

The 1.0-second budget applies to shadow mode as well: shadow mode executes the same network round trip. If your p95 exceeds this budget, disable the hook or lower `STINGRAY_TIMEOUT`. Reverting to shadow mode does not remove latency.

This budget covers healthy endpoints. When an endpoint hangs, execution waits until `STINGRAY_TIMEOUT`: **measured at 6.15s with the default 6-second timeout** against an unresponsive stub server. Lower `STINGRAY_TIMEOUT` if that delay is unacceptable during outages.

## Loop protection

Two distinct guards prevent execution loops, avoiding single points of failure:

1. `stop_hook_active` from the harness evaluates to `true` on re-entry, preventing consecutive interventions on the same stop event.
2. A per-session interception limit (`STINGRAY_MAX_BLOCKS`, default 3) enforced independently of the harness flag.

## Known limits

- Criteria in `questions.json` are written in Traditional Chinese, matching the corpus used for the 81.8% benchmark. English criteria have zero live measurements; replacing them voids that accuracy figure. Working in English requires rewriting criteria and recalibrating thresholds.
- Shape 3 accuracy cannot be measured offline: `background_tasks` exists only at hook execution and cannot be reconstructed from saved transcripts. Test suites verify logic on synthetic inputs, but production precision depends on your shadow logs.
- Redaction leaves the substance of the work visible, as detailed in the privacy section.
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
├── questions.json               # the three Jev criteria — the classifier's contract, pinned to jev-1.13.0
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

Tests drive the actual hook with real stdin and assert on exit codes and stderr. No test inspects source code directly. Live tests send synthetic text to avoid leaking conversation data.

Two test cases guard against specific implementation errors, verified by `mutants.sh`:

- **Case 7:** Shape 3 regex must execute on unredacted text. Its declaration shares a line with a file path; redaction removes lines containing paths entirely. (An earlier test used a URL, which was replaced in-place and failed to detect the bug).
- **Case 9:** A missing `background_tasks` key must not evaluate as "nothing is running", which would cause shape 3 to trigger whenever the regex matches.

## Support

stingray is free and requires no account. The only operating cost is your own TypeSafe API usage ($0.042 per million input tokens; an average turn consumes well under 1,000 tokens). You can support the maintainer on Patreon.

[![Support on Patreon](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

## License

MIT
