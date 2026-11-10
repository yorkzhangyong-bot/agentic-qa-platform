# Backlog

## Platform backlog
- [ ] Verdict job: fail the run on REAL_BUG, ENV, unhealed drift (optional fail_on_flaky)
- [ ] Requirement coverage report: FR/SC ids in test names vs spec
- [ ] Cache installs (node_modules, Playwright browsers) in jobs
- [ ] Shorter PR descriptions from the pr-writer
- [ ] Small prompt rules borrowed from official Playwright agents (regex for dynamic data, no networkidle/waitForLoadState/page.evaluate, comment per plan step, expected result per plan step)
- [ ] Prototype playwright-test MCP test_debug for healer and triage (branch only, merge only if evals improve)
- [ ] Plan-review gate and spec review agent
- [ ] Limit Claude Code's Read, Grep and Glob to the repository: run-agent.sh allows them by name, so only AGENT-RULES.md keeps a Claude agent out of other folders. Without them in --allowedTools, 2.1.283 refuses a read outside and still reads the workspace; check that its own saved large tool outputs stay readable
- [x] Upload Playwright test-results/**/error-context.md with the test artifact and give it to triage (and healer); update the triage eval to include matching snapshots at the same time
- [ ] Tell the healer about error-context.md: the heal job restores it, but its first test run empties test-results/, so the healer must read it first (or run with --output)
- [ ] Semantic locator check after healing: for each locator the healer changes, compare the element's role and accessible name before and after; if they differ, open the heal PR as a draft and list "before -> after" in the PR body; add test fixtures for match and mismatch
- [ ] Later: weekly metrics report, flaky quarantine, test data handling, impact analysis, version tags, pytest framework, port bash scripts to Python

## Evaluation of the platform
### Triage eval (in this repo)
- [x] Labelled failure cases in evals/triage/cases.jsonl (20 seed cases, 8 boundary cases)
- [x] Add real failures from consumer runs to evals/triage/cases.jsonl (3 of Kestrel's 14 ENV failures)
- [ ] Real consumer failures with labels other than ENV
- [x] Script + manual workflow: accuracy, per-category accuracy, confusion table, critical count REAL_BUG→SELECTOR_DRIFT
- [x] Record model, engine version, prompt SHA per result
- [ ] Grouped eval cases: show several failures from the same run together, as triage sees them in CI, so cross-test clues (like "no attacker key") are available.
- [ ] After each eval run, append its row to the Results history table (by hand for now; automate later).

### Benchmark repo (separate consumer repo)
- [ ] Small app + spec with FR/SC ids
- [ ] Answer key of ~20 planted changes: ~10 real bugs, ~6 harmless UI changes (drift), rest env/flaky
- [ ] Generation score: requirements covered, tests pass, human would keep them
- [ ] Per-branch pipeline scores: detection (did a test fail), triage label, issue opened, real bug healed away (must be 0), drift healed honestly, false alarms
- [ ] Plant a look-alike regression in the benchmark (a different element with a similar selector) and require healed-away = 0
- [ ] Headline metric: real bugs reported / real bugs planted
- [ ] Run the full benchmark for all three frameworks (Playwright, Cypress, Selenium) on the same app and answer key, one test folder per framework, and compare detection, healing, false alarms, cost and time per framework

### Cross-cutting evaluation
- [ ] Consistency: repeat each case 3x, measure agreement
- [ ] Cost and time per run and per caught bug
- [ ] Guardrails: planted cheating temptations and prompt injection in page text; anti-cheat must block
- [ ] Output quality of bug reports and PR descriptions (DeepEval / LLM judge)
- [ ] Compare engines (Claude Code vs OpenCode)
- [ ] Real-world tracking on Kestrel: heal PRs merged vs rejected, issues confirmed vs closed as invalid
