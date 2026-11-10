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
| the agent and engine config staged by `scripts/stage-agents.sh` | the "Stage agents" step |

It then runs the agent through `scripts/run-agent.sh`. The triage step's prompt, turn budget (15) and output file are
read from `test-and-heal.yml` itself, so the eval asks exactly what CI asks. If that step changes shape, the eval
fails instead of testing another prompt. The classification in `results/triage.json` is compared with the case's
label. A case's `expected` and `why` never reach the workspace.

What differs from CI, because the eval is offline:

- **No app is running.** The prompt says "App URL: not provided", as in a CI run without `app_url`. The agent judges
  from the error, the test and the git history.
- **Re-runs are replayed.** If the agent re-runs the test, `npx playwright test` prints the recorded failure again
  (`node_modules/.bin/playwright` in the workspace). A case can set `"rerun": "pass"` to make the replay pass.

### Cases

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
test file, the workspace gets a stub test, and `--check` warns. For a real failure from a consumer run, copy `name`,
`file` and `message` from that run's `results/failures.json`, label it, and add the test.

### Run it

**On GitHub:** Actions → **eval-triage** → Run workflow.

| Input | Default | Meaning |
|---|---|---|
| `engine` | `claude` | `claude` or `opencode` |
| `opencode_model` | `deepseek/deepseek-flash` | `provider/model` for OpenCode |
| `claude_model` | empty | model for Claude Code (`ANTHROPIC_MODEL`); empty uses its default |
| `repeats` | `1` | runs per case; `3` measures consistency |

The engine's key must be a secret of this repository: `ANTHROPIC_API_KEY`, or `DEEPSEEK_API_KEY`. For other OpenCode
providers, use `OPENROUTER_API_KEY` or `OPENAI_API_KEY`. Every case is one agent run of up to 15 turns, 4 at a time,
so 20 cases cost 20 triage runs per repeat.

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
- `--out` (result directory), `--work-dir` (workspaces and logs);
- `--keep`.

### Output

The report is printed and added to the job summary. It shows:
- **Accuracy:** correct runs out of all runs.
- **Per-category accuracy:** the same for each expected label.
- **Confusion table:** expected labels (rows) against the agent's answers (columns). "none" counts runs without a
  valid answer.
- **Critical count:** `REAL_BUG` classified as `SELECTOR_DRIFT`. Each one sends a real bug to the healer, which could
  hide it, so this should be 0.
- **Consistency** (with `repeats` above 1): cases that got the same answer in every run, and the mean agreement.
- **Wrong answers:** every case with its expected label, what the agent said, and the agent's reason.

`triage/results/<date>-<engine>-<model>.json` holds the same numbers and every run: case, answer, reason, exit code
and seconds. It also records what's needed to compare scores over time:
- `model` and `engine_version`;
- `triage_md.blob`: the git object id of `agents/common/triage.md` as tested. The same text always has the same id.
- `triage_md.commit`, the last commit that changed it, and `triage_md.modified` for local changes;
- `agent_rules_blob`, `platform_commit`, the prompt, the turn budget, and a hash of the cases file.

The workflow uploads the result file as the artifact `triage-eval-results` and the agents' logs as
`triage-eval-logs`. To keep the history, commit the result file to `evals/triage/results/`.

### In CI

`ci.yml` only checks the eval: it compiles `run-eval.py` and runs `--check`. `tests/run-tests.sh` also runs it end to
end with a stub engine, to check the scoring. Neither calls a model API.
