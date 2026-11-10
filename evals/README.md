# Evaluations

## Triage eval (`evals/triage/`)

Measures how well the triage agent (`agents/common/triage.md`) classifies failing tests. It runs offline: no app
and no consumer repository, only labelled failures replayed through the real agent.

| File | What it is |
|---|---|
| `triage/cases.jsonl` | the labelled failures, one JSON object per line |
| `triage/project/` | the sample app's Playwright tests, with a test for every case |
| `triage/run-eval.py` | builds the workspaces, runs the agent, scores the answers |
| `triage/results/` | one result file per eval run, to compare scores over time |
| `../.github/workflows/eval-triage.yml` | the manual workflow that runs it on GitHub |

### What a run does

For every case, and every repeat, `run-eval.py` builds a temporary workspace that matches what the triage job of
`test-and-heal.yml` sees after a failed run with that one failure:

| In the workspace | As in CI |
|---|---|
| a git repository with the tests from `triage/project/` | the checkout of the tested commit |
| `.agentic-qa/`: this platform's agents, `AGENT-RULES.md`, frameworks, scripts and settings | the platform checkout |
| `results/junit.xml`: a Playwright JUnit report holding the case's failure | the `test-results` artifact |
| `results/failures.json`, written from it by `scripts/parse-report.sh` | the "Parse JUnit report" step |
| `test-results/<folder>/error-context.md` for each attempt: what Playwright saved, with the page snapshot where the case has one (not with `--no-snapshots`) | the `test-results` artifact |
| the agent and engine config staged by `scripts/stage-agents.sh` | the "Stage agents" step |

It then runs the agent through `scripts/run-agent.sh`. The triage step's prompt, turn budget (15) and output file are
read from `test-and-heal.yml` itself, so the eval asks exactly what CI asks. If that step changes shape, the eval
fails instead of testing another prompt. The classification in `results/triage.json` is compared with the case's
label. A case's `expected` and `why` never reach the workspace.

What differs from CI, because the eval is offline:

- **No app is running.** The prompt says "App URL: not provided", as in a CI run without `app_url`. The agent judges
  from the error, the page snapshot in `error-context.md`, the test and the git history.
- **Re-runs are replayed.** If the agent re-runs the test, `npx playwright test` prints the recorded failure again
  (`node_modules/.bin/playwright` in the workspace). A case can set `"rerun": "pass"` to make the replay pass.
- **The log is a full transcript.** The engine prints its JSON event stream, with every tool call and its result,
  not only the final answer: Claude Code with `--output-format stream-json --verbose`, OpenCode with
  `--format json`. A wrapper on the agent's `PATH` adds the flags. `run-agent.sh` and what the agent may do are
  unchanged.
- **Runs share one machine.** Up to `--jobs` agents run at once, where CI runs one per job on a fresh runner. So
  each run is kept apart from the others; see [Keeping runs apart](#keeping-runs-apart).

### Keeping the answer key from the agent

The agent is told to stay inside its workspace, but it can still look outside: OpenCode refuses reads there but not
`ls`, and Claude Code's Read, Grep and Glob aren't limited by path. So the eval keeps the answer key out of its
reach:

1. **Nothing in a workspace gives an answer away.** The eval refuses to run if a file from `triage/project/` or
   the platform contains a case's `why`, or a case's test name within 3 lines of a label. It also refuses if such a
   file mentions `cases.jsonl` or `evals/`, because every run that read it would be invalid. `--check` checks this.
2. **In CI, the answer key is deleted before the first agent starts.** This is `--hide-answers`, the default when
   `CI` is set; `eval-triage.yml` passes it explicitly. `run-eval.py` reads the cases and the sample project into
   memory, then deletes from the checkout:
   - all of `evals/`: the cases, the result files (every run in them has its expected label), this README, the
     sample project and `run-eval.py` itself. Any of them leads to the answer key; the workspaces get the project
     from memory;
   - the `--cases` file, if it is outside `evals/`;
   - every other file that contains a case's `why` or its test name near a label. One is `tests/run-tests.sh`,
     whose stub cases reuse real test names;
   - `.git`, whose history holds all of them.

   `--check` lists what would be deleted. The result file is written to `triage/results/` once the last agent has
   finished. Deleting `.git` loses whatever exists only there. So outside the checkout of a GitHub Actions job,
   `--hide-answers` refuses while the repository has uncommitted changes, commits that are on no remote, or
   stashes. If your shell sets `CI`, pass `--no-hide-answers` to run the eval locally.

   While the agents run, the progress lines show only the agents' answers, not the expected labels, because the
   job's log is on the same machine.
3. **Runs that went for the key don't count.** A run is **invalid** if its log mentions `cases.jsonl`, `evals/`
   or the checkout's path, or quotes a case's `why`. The same applies if it mentions the eval's work directory
   outside the run's own folder, since that's where the other runs are. The report lists each invalid run with
   what was found, and it is not scored. Paths inside the run's own folder don't count.

### Keeping runs apart

With `repeats` above 1, no run may see another run's answer; otherwise consistency would measure copying. Each
run of each case gets its own folder, `trials/<id>-r<n>/` in the work directory:

| In the run's folder | What it is |
|---|---|
| `workspace/` | the agent's workspace; removed after the run unless `--keep` |
| `agent.log` | the run's log: building the workspace, then the engine's full transcript |
| `result.json` | the run's record, as in the result file. It holds the expected label, so it is written only after the last agent has finished |
| `tmp/` | the agent's temp directory (`TMPDIR`, `TMP`, `TEMP`) |
| `engine-data/`, `engine-state/` | OpenCode only: its data and state directories, so its sessions, file snapshots, logs and long tool output stay with the run |

- The log and the result are outside the workspace.
- When a run ends, its folder is locked (mode 000) until the eval ends. The agents can't read it and can't run
  `chmod`. On Windows a folder's mode doesn't stop reads, so there only the engines' own rules keep runs apart;
  run the eval on Linux, as CI does.
- A case's runs follow one another and never overlap. Different cases run in parallel.
- Claude Code runs with `--no-session-persistence`, so it saves no transcripts in its config directory.
- With its own data directory per run, OpenCode keeps its sessions there too. That also avoids a race: on one
  shared database, parallel first runs fail at startup with "database is locked" or a failed `CREATE TABLE`.
- If you use `opencode auth login` locally, the eval copies `auth.json` into each run's data directory for the run
  and deletes it right after. In CI the key comes from the environment.

### Cases

`triage/cases.jsonl` holds 31 cases:

- **T01 to T20, the seed cases.** Each has a one-line error that carries its own evidence.
- **T21 to T23, real failures from Kestrel.** They come from Kestrel's `test-and-heal` runs 42612500123 and
  42629695684, which hit the same 14 ENV failures. These three cover the three error shapes among them, in
  Playwright's own report text. Only three things changed: the checkout path is the eval's, Chromium's browser
  logs and the trace attachments are left out, and one call-log line cut off in storage was restored from that
  run's failure summary. Their tests (`tests/e2e-browser/adaptive-attack.spec.ts`, its fixtures and the page object
  `tests/pages/KestrelApp.ts`) are copied unchanged from `yorkzhangyong-bot/kestrel` at `d1797037` (MIT licence).
- **T24 to T31, boundary cases.** Each sits where two labels are easy to confuse under the triage agent's decision
  rules. Their errors use Playwright's report format, with the call log, a code frame generated from the sample
  project, and both CI attempts.

A one-line error is completed the way Playwright prints it: `Error: …` plus the failing line. A multi-line error is
the reporter's whole text.

There is no app to inspect, so every attempt that failed on a loaded page carries its page snapshot. It's a
`# Page snapshot` line, a blank line, then a ```` ```yaml ```` block, placed after the attempt's text (for a
one-line error, after the line). It is what Playwright saves in `error-context.md` when a test fails: the
accessibility tree of the page, from `page.ariaSnapshot()` in its "ai" mode, with refs and `[cursor=pointer]`. It
shows the page the test was on, with what the error and the test describe, and nothing else.

A case whose page never loaded anything has no snapshot, because Playwright writes none for an empty page:
- T17: the navigation was refused;
- T19: there was no browser;
- T21 and T22: the test failed before it opened the app;
- T27: a database helper failed before `page.goto`.

Two things change between the error and the report:

- **The page snapshot leaves the report**, because Playwright doesn't print it there. With `--snapshots`, the
  default, it goes into that attempt's `error-context.md`; with `--no-snapshots` it is gone.
- **Every attempt ends with an `Error Context:` line**, which Playwright 1.65 prints for each failed attempt. An
  attempt without one gets it. Its folder is the first attempt's plus `-retry<n>`, or, if the error names none, the
  one Playwright would use for this test in the sample project (`../test-results/<folder>/error-context.md`,
  relative to its `tests/` test directory).

The report is the same in both modes; only the files differ. Each file is at `test-results/<folder>/` in the
workspace, where the triage job restores it from the `test-results` artifact. It holds what Playwright writes:

- its `# Instructions` for a coding assistant;
- the test's name and location;
- the attempt's errors, without code frames or stack;
- the page snapshot, unless the page never loaded;
- the test source around the failing line, from the sample project.

Nothing else goes in, so no label and no `why`. `--check` also makes sure each case's report and files give no
answer away.

| Field | Meaning |
|---|---|
| `id` | unique id: letters, digits, `.`, `_`, `-` |
| `file` | the test file, under `tests/` |
| `name` | the test's title |
| `error` | the failure as the reporter showed it |
| `expected` | `SELECTOR_DRIFT`, `REAL_BUG`, `FLAKY` or `ENV` |
| `why` | why that label is right, for humans only |
| `rerun` | optional: `fail` (default) or `pass`, what a re-run by the agent shows |

To add a case, add its line and make sure `triage/project/` has the test, so the failing step exists. Without the
test file, the workspace gets a stub test, and `--check` warns. For a real failure from a consumer run, take it from
that run's `results/failures.json`:
- copy `name` and `file`;
- use the `stack` without its first line as `error`, removing secrets and long browser logs;
- label it, and add the test file it ran, with the helpers it imports.

### Run it

**On GitHub:** Actions → **eval-triage** → Run workflow.

| Input | Default | Meaning |
|---|---|---|
| `engine` | `claude` | `claude` or `opencode` |
| `opencode_model` | `deepseek/deepseek-flash` | `provider/model` for OpenCode |
| `claude_model` | empty | model for Claude Code (`ANTHROPIC_MODEL`); empty uses its default |
| `repeats` | `1` | runs per case; `3` measures consistency |
| `snapshots` | on | give each case its `error-context.md` files; off measures triage without page snapshots |

The engine's key must be a secret of this repository: `ANTHROPIC_API_KEY`, or `DEEPSEEK_API_KEY`. For other OpenCode
providers, use `OPENROUTER_API_KEY` or `OPENAI_API_KEY`. Every case is one agent run of up to 15 turns, 4 at a time,
so 31 cases cost 31 triage runs per repeat.

**Locally**, with the engine CLI installed and either logged in or its key set:

```bash
python3 evals/triage/run-eval.py --engine opencode --model deepseek/deepseek-flash
python3 evals/triage/run-eval.py --engine claude --only T01,T06 --keep    # two cases; keep their workspaces
python3 evals/triage/run-eval.py --check      # validate the cases and the CI prompt: no agent, no API calls
python3 evals/triage/run-eval.py --dry-run    # also build every workspace, without the agent
```

Other options:
- `--repeats`;
- `--jobs` (default 4);
- `--max-turns`;
- `--timeout` (seconds per run, default 1200);
- `--cases`, `--only`;
- `--out` (result directory), `--work-dir` (the runs' folders; must be outside the repository, and new or empty);
- `--keep` (keep each run's workspace in its folder);
- `--hide-answers` / `--no-hide-answers` (default: on when `CI` is set);
- `--snapshots` / `--no-snapshots` (default: on): whether each case gets its `error-context.md` files.

### Output

The report is printed and added to the job summary. It shows:
- **Accuracy:** correct runs out of all scored runs.
- **Invalid runs:** how many runs went for the answer key. They are not scored, and the **Invalid runs** table
  lists each one with what its log showed.
- **Per-category accuracy:** the same for each expected label.
- **Confusion table:** expected labels (rows) against the agent's answers (columns). "none" counts runs without a
  valid answer.
- **Critical count:** `REAL_BUG` classified as `SELECTOR_DRIFT`. Each one sends a real bug to the healer, which could
  hide it, so this should be 0.
- **Consistency** (with `repeats` above 1): cases that got the same answer in every run, and the mean agreement.
- **Wrong answers:** every case with its expected label, what the agent said, and the agent's reason. When the
  agent wrote no `results/triage.json`, the reason says why, from the run's log and workspace:
  - the turn limit;
  - the eval's `--timeout`;
  - an engine error, with its message, noting whether it came before the agent's first step;
  - a permission request the engine rejected, after which OpenCode stops;
  - a `triage.json` written, or attempted, somewhere else;
  - otherwise, the agent's last message.

`triage/results/<date>-<engine>-<model>.json` holds the same numbers (`summary.scored` and `summary.invalid` count
the runs) and every run: case, answer, reason, exit code, seconds, and `invalid` with `invalid_context` for an
invalid run. It also records what's needed to compare scores over time:
- `model` and `engine_version`;
- `triage_md.blob`: the git object id of `agents/common/triage.md` as tested. The same text always has the same id.
- `triage_md.commit`, the last commit that changed it, and `triage_md.modified` for local changes;
- `agent_rules_blob`, `platform_commit`, the prompt, the turn budget, and a hash of the cases file;
- `deleted_before_agents`: what `--hide-answers` deleted;
- `snapshots`: whether the cases had their `error-context.md` files. Without them, the file name ends in
  `-no-snapshots`.

The workflow uploads the result file as the artifact `triage-eval-results`, and each run's `agent.log` and
`result.json` as `triage-eval-logs`. To keep the history, commit the result file to `evals/triage/results/`, and
add the run's row to [Results history](#results-history).

### In CI

`ci.yml` only checks the eval: it compiles `run-eval.py` and runs `--check`. `tests/run-tests.sh` also runs it end to
end with a stub engine. That checks the scoring and the invalid-run check. It also checks hide mode on a scratch
clone of the repository, never on the checkout itself. Neither calls a model API.

### Results history

One row per eval run, oldest first. The numbers are the ones described in [Output](#output). Consistency needs more
than one run per case.

| Date | Platform commit | `triage.md` commit | What changed | Engine and model | Cases × repeats | Accuracy | Critical count | Invalid runs | Consistency | Actions run |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-10 | `7733701` | `36a02d1` | first 20-case set after permission and isolation fixes | opencode 1.19.5, `deepseek/deepseek-flash` | 20 × 1 | 20/20 (100%) | 0 | 0 | — | [42804483276](https://github.com/yorkzhangyong-bot/agentic-qa-platform/actions/runs/42804483276) |
| 2026-11-10 | `22990d6` | `36a02d1` | 31 cases: added real Kestrel and tricky cases | opencode 1.19.5, `deepseek/deepseek-flash` | 31 × 3 | 84/90 (93%) | 0 | 3 | 27/31 | [42813980294](https://github.com/yorkzhangyong-bot/agentic-qa-platform/actions/runs/42813980294) |
| 2026-11-10 | `6d66802` | `6d66802` | agents continue after denied paths; FLAKY and ENV triage rules | opencode 1.19.5, `deepseek/deepseek-flash` | 31 × 3 | 90/93 (97%) | 0 | 0 | 31/31 | [42830002351](https://github.com/yorkzhangyong-bot/agentic-qa-platform/actions/runs/42830002351) |
| 2026-11-10 | `743be99` | `743be99` | Playwright's error-context.md for each attempt, a page snapshot in 4 cases; snapshots on | opencode 1.19.5, `deepseek/deepseek-flash` | 31 × 3 | 89/93 (96%) | 0 | 0 | 30/31 | [42851132289](https://github.com/yorkzhangyong-bot/agentic-qa-platform/actions/runs/42851132289) |
| 2026-11-10 | `743be99` | `743be99` | the same, snapshots off | opencode 1.19.5, `deepseek/deepseek-flash` | 31 × 3 | 87/93 (94%) | 0 | 0 | 31/31 | [42854283500](https://github.com/yorkzhangyong-bot/agentic-qa-platform/actions/runs/42854283500) |
| 2026-11-10 | `1d42595` | `1d42595` | a page snapshot for every case whose page had loaded; a missing snapshot is no evidence; snapshots on | opencode 1.19.5, `deepseek/deepseek-flash` | 31 × 3 | 90/93 (97%) | 0 | 0 | 31/31 | [42861690940](https://github.com/yorkzhangyong-bot/agentic-qa-platform/actions/runs/42861690940) |

The first row used a smaller, easier case set, the 20 seed cases, so it isn't directly comparable with the rows
after it.

The first three runs came before `error-context.md`: the cases that have a page snapshot had it inside the error
text, and the others had no `Error Context:` line. From now on, write in "What changed" whether a run had snapshots.

On `743be99` only 4 cases had a page snapshot, the ones that had it in the error text before:
- **T25** was right in all 3 runs with snapshots and wrong in all 3 without.
- **T05** missed once with snapshots: its error-context.md had no page snapshot, and the agent took that as evidence
  against the error message.

After `743be99`, every case whose page had loaded has a snapshot, so later runs aren't directly comparable with
these two.

On `1d42595` the only miss was T23, in all 3 runs, a [known hard case](#known-hard-cases). T05, which missed once
on `743be99`, was right in all 3 runs, and so was T25.

### Known hard cases

- **T23** (a button disabled because the attacker key is missing; expected `ENV`): labelled `REAL_BUG`, because its
  error text alone gives no sign of the missing key. In run 42830002351 it was the only miss, in all 3 repeats. This
  is an expected miss: don't tune the prompt to this one case.
