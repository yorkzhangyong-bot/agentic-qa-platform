# Backlog

## Platform backlog
- [ ] Verdict job: fail the run on REAL_BUG, ENV, unhealed drift (optional fail_on_flaky)
- [ ] Requirement coverage report: FR/SC ids in test names vs spec
- [ ] Cache installs (node_modules, Playwright browsers) in jobs
- [ ] Shorter PR descriptions from the pr-writer
- [ ] Small prompt rules borrowed from official Playwright agents (regex for dynamic data, no networkidle/waitForLoadState/page.evaluate, comment per plan step, expected result per plan step)
- [ ] Prototype playwright-test MCP test_debug for healer and triage (branch only, merge only if evals improve)
- [ ] Plan-review gate and spec review agent
- [ ] Later: weekly metrics report, flaky quarantine, test data handling, impact analysis, version tags, pytest framework, port bash scripts to Python

## Evaluation of the platform
### Triage eval (in this repo)
- [ ] Labelled failure cases in evals/triage/cases.jsonl (20 seed cases + real failures from consumer runs)
- [ ] Script + manual workflow: accuracy, per-category accuracy, confusion table, critical count REAL_BUG→SELECTOR_DRIFT
- [ ] Record model, engine version, prompt SHA per result

### Benchmark repo (separate consumer repo)
- [ ] Small app + spec with FR/SC ids
- [ ] Answer key of ~20 planted changes: ~10 real bugs, ~6 harmless UI changes (drift), rest env/flaky
- [ ] Generation score: requirements covered, tests pass, human would keep them
- [ ] Per-branch pipeline scores: detection (did a test fail), triage label, issue opened, real bug healed away (must be 0), drift healed honestly, false alarms
- [ ] Headline metric: real bugs reported / real bugs planted
- [ ] Run the full benchmark for all three frameworks (Playwright, Cypress, Selenium) on the same app and answer key, one test folder per framework, and compare detection, healing, false alarms, cost and time per framework

### Cross-cutting evaluation
- [ ] Consistency: repeat each case 3x, measure agreement
- [ ] Cost and time per run and per caught bug
- [ ] Guardrails: planted cheating temptations and prompt injection in page text; anti-cheat must block
- [ ] Output quality of bug reports and PR descriptions (DeepEval / LLM judge)
- [ ] Compare engines (Claude Code vs OpenCode)
- [ ] Real-world tracking on Kestrel: heal PRs merged vs rejected, issues confirmed vs closed as invalid
