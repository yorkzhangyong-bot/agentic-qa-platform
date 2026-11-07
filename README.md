# agentic-qa-platform

Reusable GitHub Actions workflows and Claude Code sub-agents for AI-assisted UI testing across
**Playwright**, **Cypress** and **Selenium (Java/Maven)**:

- **Self-healing.** `test-and-heal.yml` runs your suite. When it fails:
  - a *triage* agent classifies every failure (`SELECTOR_DRIFT`, `REAL_BUG`, `FLAKY`, `ENV`);
  - a *healer* agent repairs only the selector-drift failures, changing locators and waits but never assertions;
  - `anti-cheat.sh` checks the diff;
  - a *pr-writer* agent opens an evidence-first pull request.
- **Test generation.** `generate-tests.yml` turns a markdown spec, GitHub issue or Jira ticket into tests:
  - a *planner* agent writes a numbered test plan;
  - a *generator* agent implements it, with locators confirmed against the live app;
  - the workflow runs the tests, checks the diff with `anti-cheat.sh` and opens a pull request.

Whatever the test framework, the agents inspect the running app through one MCP server, `browser`
(`@playwright/mcp`).

## How it works

```text
test-and-heal.yml
  config ──► test ──(tests failed)──► heal
  │          check out the commit,    check out the same commit
  │          install, run tests,      parse-report.sh → results/failures.json
  │          upload "test-results"    claude --agent triage → results/triage.json
  │                                   claude --agent healer (only if SELECTOR_DRIFT) → results/heal-report.json
  │                                   anti-cheat.sh → claude --agent pr-writer → PR_BODY.md
  │                                   open PR auto-heal/<run_id>, or update + comment on the open auto-heal PR
  └─ _select-framework.yml reads frameworks/<framework>.json

generate-tests.yml
  config ──► generate: fetch-spec.sh → spec.md
                       claude --agent planner → results/plan.md
                       claude --agent generator → tests + results/generate-report.json
                       run tests → anti-cheat.sh → claude --agent pr-writer → PR auto-generate/<run_id>
```

Each agent runs as its own `claude -p --agent <name>` call, with its own turn budget. Every call gets the shared rules
in [`CLAUDE.md`](CLAUDE.md) through `--append-system-prompt-file`; nothing is written to the consumer's own
`CLAUDE.md`. A step fails if its agent doesn't write its result file, instead of silently reporting "no changes".

## Repository layout

```text
.
├── CLAUDE.md                    shared rules every agent follows
├── .mcp.json                    MCP server "browser" (@playwright/mcp, headless, pinned version)
├── LICENSE                      MIT
├── frameworks/                  one config per framework
│   ├── playwright.json
│   ├── cypress.json
│   └── selenium.json
├── agents/                      Claude Code sub-agents
│   ├── common/                  triage.md, pr-writer.md
│   ├── playwright/              planner.md, generator.md, healer.md
│   ├── cypress/                 planner.md, generator.md, healer.md
│   └── selenium/                planner.md, generator.md, healer.md
├── settings/
│   └── claude-settings.json     staged as .claude/settings.json: Bash allow/deny list for the agents
├── scripts/
│   ├── fetch-spec.sh            SPEC_PATH / GitHub issue / Jira ticket → spec.md
│   ├── parse-report.sh          JUnit XML (any framework) → results/failures.json
│   └── anti-cheat.sh            fails on forbidden paths, weakened assertions, skips, sleeps, long timeouts
├── tests/                       fixture tests for the scripts (bash tests/run-tests.sh)
│   ├── anti-cheat/              base/ sample project + *.diff fixtures (pass-* and fail-*)
│   └── parse-report/            Playwright, Cypress, Surefire XML + expected JSON
├── .github/workflows/
│   ├── _select-framework.yml    reads frameworks/<framework>.json → outputs
│   ├── test-and-heal.yml        reusable: test → triage → heal → PR
│   ├── generate-tests.yml       reusable: spec → plan → tests → PR
│   └── ci.yml                   CI for this repository
└── templates/                   caller workflows for consumer repos
    ├── caller-test-and-heal.yml
    └── caller-generate.yml
```

## Set up this repository (once)

1. Push it to GitHub, e.g. as `your-org/agentic-qa-platform`. Nothing in the workflows needs editing: they
   check out scripts, agents and configs from `${{ job.workflow_repository }}` at `${{ job.workflow_sha }}`,
   i.e. the same repository and commit a consumer calls. This requires github.com; GitHub Enterprise Server
   doesn't provide those values.
2. If the repository is private:
   - Under **Settings → Actions → General → Access**, allow repositories in your organization to use its
     workflows.
   - Give each consumer a `PLATFORM_TOKEN` secret: a token with read access to this repository. The
     workflows use it to check out scripts and agents.

## Onboard a consumer repository (~10 lines)

1. Add the secret `ANTHROPIC_API_KEY`: a **dedicated, low-quota key** used only by these workflows (see
   [Security](#security)). Also add `JIRA_TOKEN` if you generate tests from Jira.
2. Add the variable `APP_URL`: a running, **disposable test instance** of the app that CI can reach. Never use
   production.
3. Under **Settings → Actions → General**, enable **Allow GitHub Actions to create and approve pull requests**.
4. Create the labels `auto-heal`, `auto-generate` and `ready-for-tests`. Only maintainers should be able to apply
   `ready-for-tests`.
5. Copy `templates/caller-test-and-heal.yml` and `templates/caller-generate.yml` to `.github/workflows/`.
6. In both files, check that the `uses:` line points at this repository (the templates use
   `yorkzhangyong-bot/agentic-qa-platform`). Then set `framework` (`playwright`, `cypress` or `selenium`) and
   `test_dir`, if your tests are not in the framework's default folder.
7. Make the tests read their base URL from the environment. The workflows export `APP_URL` and `BASE_URL`, and
   for Cypress also `CYPRESS_BASE_URL`.
8. Check that the framework's commands work from the repository root (`npm ci` + `npx playwright test`,
   `npx cypress run`, or `mvn -B test`).
9. Push to `main` or open a pull request. Failures caused by selector drift come back as an `auto-heal` PR. The
   template's comments show how to gate pull-request healing behind a label to save API budget.
10. Label an issue `ready-for-tests`, or run the workflow manually with `spec_path`. Generated tests come back
    as an `auto-generate` PR.

## Workflow reference

### `test-and-heal.yml`

| Input | Required | Default | Description |
|---|---|---|---|
| `framework` | yes | — | Framework config to use: `playwright`, `cypress`, `selenium` (any `frameworks/<name>.json`). |
| `test_dir` | no | framework's `default_test_dir` | Directory containing the tests, relative to the repository root. |
| `app_url` | no | `""` | Base URL of a running, disposable test instance of the app. Exported as `APP_URL`, `BASE_URL` and `CYPRESS_BASE_URL`. The agents browse it through MCP. |
| `node_version` | no | `"20"` | Node.js version. Always installed, because Claude Code and the MCP server need it. |
| `java_version` | no | `"17"` | Java version. Installed when the framework runs Maven or Gradle. |
| `triage_max_turns` | no | `15` | `--max-turns` for the triage agent. |
| `heal_max_turns` | no | `40` | `--max-turns` for the healer agent. |
| `claude_code_version` | no | `"2.1.283"` | Version of `@anthropic-ai/claude-code` to install. |
| `playwright_mcp_version` | no | `"0.0.84"` | Version of `@playwright/mcp`, written into the staged `.mcp.json`. |
| `platform_ref` | no | `""` | Optional branch, tag or SHA of this repository to take scripts, agents and configs from. Empty uses the commit of the called workflow (`job.workflow_sha`). |

| Secret | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes | Dedicated, low-quota key used by Claude Code. Only exposed to the steps that run agents. |
| `JIRA_TOKEN` | no | Accepted so both workflows share the same secrets. Healing does not use it. |
| `PLATFORM_TOKEN` | no | Read token for this repository. Only needed if it is private. |

| Output | Description |
|---|---|
| `failed` | `'true'` if the test run failed. |
| `pr_url` | URL of the auto-heal pull request that was opened or updated. |

How it runs:

- **`config`** reads the framework config.
- **`test`** checks out the commit under test and outputs its SHA. For pull requests that is the PR head commit,
  not GitHub's merge commit. It runs the suite with `continue-on-error` and always uploads the `test-results`
  artifact.
- **`heal`** checks out exactly the SHA the test job tested.
  - It runs only when the tests failed, gets `contents: write` and `pull-requests: write`, and is skipped for
    pull requests from forks, which don't receive secrets.
  - The healer runs only if triage found `SELECTOR_DRIFT` items.
  - The job fails if triage or the healer doesn't write its report.
  - The pr-writer agent runs with 20 turns.
- **Pull request.** If an open `auto-heal` PR already targets the same base branch, the run pushes its result to
  that PR's branch and comments on the PR. Otherwise it opens a new PR on `auto-heal/<run_id>`, titled
  "Auto-heal: repair failing tests", with the label `auto-heal`.
- **Concurrency.** One run per caller workflow and ref at a time. Later runs wait; nothing is cancelled.

### `generate-tests.yml`

| Input | Required | Default | Description |
|---|---|---|---|
| `framework` | yes | — | Framework config to use. |
| `test_dir` | no | framework's `default_test_dir` | Where the generated tests go. |
| `app_url` | no | `""` | Disposable test instance the planner and generator explore through MCP. Exported as in `test-and-heal.yml`. |
| `spec_path` | no | `""` | Markdown spec in the repository. Highest priority. |
| `issue_number` | no | `""` | GitHub issue whose title and body are the spec. |
| `jira_key` | no | `""` | Jira issue key, e.g. `QA-123`. Fetched from REST API v3. |
| `jira_base_url` | no | `""` | Jira site, e.g. `https://your-company.atlassian.net`. Required with `jira_key`. |
| `jira_email` | no | `""` | Jira Cloud account email, for basic auth with `JIRA_TOKEN`. If empty, the token is sent as a Bearer token (Jira Data Center PAT). |
| `node_version` | no | `"20"` | Node.js version. |
| `java_version` | no | `"17"` | Java version (Maven/Gradle frameworks). |
| `plan_max_turns` | no | `20` | `--max-turns` for the planner agent. |
| `generate_max_turns` | no | `80` | `--max-turns` for the generator agent. |
| `claude_code_version` | no | `"2.1.283"` | Version of `@anthropic-ai/claude-code` to install. |
| `playwright_mcp_version` | no | `"0.0.84"` | Version of `@playwright/mcp`, written into the staged `.mcp.json`. |
| `platform_ref` | no | `""` | Optional ref override, as in `test-and-heal.yml`. Empty uses the commit of the called workflow. |

Secrets:
- `ANTHROPIC_API_KEY` (required).
- `JIRA_TOKEN` (required with `jira_key`).
- `PLATFORM_TOKEN` (optional).

Output: `pr_url`.

Permissions: `contents: write` and `pull-requests: write`, plus `issues: read` so it can read the issue.

How it runs:
- The job fails if the planner doesn't write `results/plan.md`, or if no test files change.
- The PR goes to branch `auto-generate/<run_id>` with the label `auto-generate`. It is opened as a **draft** if
  the tests fail after generation, for example because of a possible app bug the generator refused to hide.
- Concurrency works as in `test-and-heal.yml`.

### `_select-framework.yml` (used by both workflows)

Input `framework` (plus `platform_ref` and the optional secret `PLATFORM_TOKEN`). It outputs every key of
`frameworks/<framework>.json`: scalars as strings, arrays and objects as compact JSON. It also outputs three
derived values:
- `install_script`: the install commands, one per line.
- `forbidden_paths_csv`: the forbidden paths, comma-separated.
- `runtime`: `java` if the commands use Maven or Gradle, otherwise `node`.

## Framework configs

| Key | Meaning |
|---|---|
| `name` | Framework id; same as the file name. |
| `install` | Array of commands, run in order from the repository root. |
| `run` | Test command. Must produce JUnit XML that matches `report_glob`. |
| `env` | Optional object of environment variables for `run`. Playwright uses it to set `PLAYWRIGHT_JUNIT_OUTPUT_NAME`. |
| `report_glob` | Location of the JUnit XML; the input to `parse-report.sh`. |
| `test_glob` | Which files are tests. |
| `default_test_dir` | Where tests live when the caller doesn't set `test_dir`. |
| `locator_priority` | Preferred locator strategies, best first. |
| `forbidden_paths` | Paths or globs agents must never change; enforced by `anti-cheat.sh` on top of its built-in list. |
| `agents_dir` | Folder holding this framework's `planner.md`, `generator.md` and `healer.md`. |
| `mcp` | MCP server the agents use (`browser`). |

## Add a new framework

1. **Config.** Create `frameworks/<name>.json` with every key above.
   - `run` must write JUnit XML matching `report_glob`. Put reporter settings in `env`.
   - If the framework needs Java, call `mvn` or `gradle` in the commands so `runtime` resolves to `java`.
2. **Agents.** Create `agents/<name>/planner.md`, `generator.md` and `healer.md`, starting from the closest
   existing framework.
   - Keep the front-matter names `planner`, `generator` and `healer`; the workflows run those agents by name.
   - Describe the framework's idioms, locator API, test command and single-test re-run command.
3. **Bash permissions.** Allow the framework's test command in `settings/claude-settings.json` (e.g.
   `Bash(npx wdio run:*)`). Otherwise the agents can't run tests.
4. **Guardrails.** If the framework has its own skip/focus syntax, sleep API or assertion keywords:
   - add them to the patterns in `scripts/anti-cheat.sh`;
   - add `pass-*` and `fail-*` fixtures under `tests/anti-cheat/`.
5. **MCP.** If the agents need another MCP server:
   - Add it to `.mcp.json` and set `mcp` in the config. The workflows allow `mcp__<mcp>__*`.
   - List those tools in the agents' `tools`.
6. **Try it.** From a sample repository, call the workflows at `@<your-branch>` with `framework: <name>`.
   Scripts, agents and configs come from the same commit automatically.

## Guardrails

### `anti-cheat.sh`

`scripts/anti-cheat.sh "<forbidden,paths>" [base-ref]` compares the working tree, including new untracked files,
with the base ref. It fails when the diff:

- **[forbidden path]** touches the framework's `forbidden_paths` or a built-in forbidden path: `.github/`,
  `*.config.{ts,js,mjs,cjs}`, `playwright.config.*`, `cypress.config.*`, `package.json`, `package-lock.json`,
  `pnpm-lock.yaml`, `yarn.lock`, `pom.xml`, `build.gradle*`, `tsconfig*.json` or `.env*`. Patterns without a `/`
  match the file name at any depth.
- **[removed assertion]** removes or changes an assertion line: `expect(…)`, an `assert(…)` or
  `assertEquals(…)`-style call, `Assert.…(…)`, `Assertions.…(…)`, `assert.…(…)`, an `assert` statement or
  `.should(…)`. A line that comes back with only its locator, `await`, whitespace or `{ timeout }` changed is
  allowed. Identifiers such as `assertion` or `assertive`, and import lines, don't count as assertions.
- **[weakened assertion]** replaces `toBe` / `toEqual` / `toStrictEqual` / `toHaveText` with `toBeTruthy` /
  `toBeDefined`.
- **[try/catch around assertion]** adds `try` or `catch` (including `.catch(`) within 5 lines of an assertion.
- **[disabled test]** adds `.skip`, `.only`, `.fixme`, `xit`, `xdescribe`, `xtest`, `xcontext`, `xspecify`, `fit`,
  `fdescribe`, `@Disabled…`, `@Ignore` or `@Test(enabled = false)`.
- **[test config]** adds `test.describe.configure(…)` or `test.slow()`.
- **[fixed sleep]** adds `waitForTimeout`, `cy.wait(<number>)`, `cy.wait(Cypress.env(…))`, `Thread.sleep`,
  `TimeUnit.*.sleep` or `setTimeout` (e.g. `new Promise(r => setTimeout(r, ms))`).
- **[long timeout]** adds or raises a timeout above 60000 ms. Covered forms: `timeout: N`, `{ timeout: N }`,
  `setDefaultTimeout(N)`, `setDefaultNavigationTimeout(N)`, `test.setTimeout(N)` and
  `Duration.ofMillis/ofSeconds/ofMinutes(N)`.

Every rule has `pass-*` and `fail-*` fixtures in `tests/anti-cheat/`.

### Workflow protections

- The job fails if an agent modified the platform checkout (`.agentic-qa/`), because anti-cheat would then be
  running modified code.
- The job fails if the pr-writer changed any file after anti-cheat ran.
- The staged agents, `.claude/settings.json`, `.mcp.json`, `results/`, `spec.md` and `PR_BODY.md` are listed in
  `.git/info/exclude`.
- Staging can overwrite tracked `.mcp.json`, `.claude/settings.json` or `.claude/agents` files; those are restored
  before the PR is created.

### Residual risks

These are **not** detected by the script and must be checked by the reviewer (the pr-writer adds a
"Residual risks" section to every PR):

- **An assertion re-targeted to a different element.** If only the locator inside an assertion changes, the check
  passes even when the new locator points at another element. `anti-cheat.sh` lists every such line under
  "review needed" (also in `results/anti-cheat.txt`), so each one can be confirmed by a human.
- **Changed test steps.** Removed or reordered actions that aren't assertions, and changed fixtures or test data,
  are allowed by the script.

## Security

- **`app_url` must point at a disposable test environment, never production.** Agents click through the app,
  submit forms, and treat page content as untrusted input.
- **`ANTHROPIC_API_KEY` should be a dedicated, low-quota key** used only by these workflows. It is in the agent
  process's environment, so treat it as exposed to the agents and cap what it can spend.
- **Only maintainers should be able to apply the `ready-for-tests` label.** Issue and ticket text become agent
  input, so don't grant the triage role broadly, and review an issue before labelling it.
- **Bash is restricted.** `settings/claude-settings.json` is staged as `.claude/settings.json`, and the
  `claude -p` calls run with `--permission-mode dontAsk` and no `Bash` in `--allowedTools`. Agents can run only:
  - `npx playwright test`, `npx playwright install`, `npx cypress run`, `mvn`, `pytest`;
  - `git status`, `git diff`, `git log`;
  - `ls`, `cat` and `mkdir`.

  `curl`, `wget`, `git push`, `git config`, `env`, `printenv`, `echo $ANTHROPIC*`, `nc` and `ssh` are explicitly
  denied.
- **Checkouts use `persist-credentials: false`**, so agents can't push with the workflow token. Only
  `create-pull-request` pushes, after the guardrails pass.
- **Third-party actions are pinned to a commit SHA.** `peter-evans/create-pull-request` is pinned to `5f6978f…`
  (`# v8.1.1`). GitHub's own `actions/*` use major tags.

## Notes

- `@playwright/mcp` drives the Google Chrome that GitHub-hosted Ubuntu runners include. Self-hosted runners
  need Chrome, `jq`, `python3` and Actions Runner v2.327.1 or later (all actions used, including
  `create-pull-request@v8`, run on Node 24).
- Pull requests opened with the default `GITHUB_TOKEN` don't trigger other workflows. Re-run CI on them
  manually, or switch the action to a GitHub App token.
- The artifact name `test-results` is fixed, so call `test-and-heal.yml` once per workflow run.
- To run an agent locally:
  1. Copy `agents/common/*` and `agents/<framework>/*` to `.claude/agents/`.
  2. Copy `.mcp.json` to the repository root and `settings/claude-settings.json` to `.claude/settings.json`.
  3. Run, for example,
     `claude -p "Triage results/failures.json" --agent triage --append-system-prompt-file path/to/CLAUDE.md`.

## Development

- `bash tests/run-tests.sh` runs the fixture tests:
  - every `tests/anti-cheat/*.diff` is applied to `tests/anti-cheat/base/`; `pass-*` must pass and `fail-*` must
    report the rule named in its header;
  - the sample reports in `tests/parse-report/` must produce their `*.expected.json`.
- `.github/workflows/ci.yml` runs on every push and pull request:
  - `shellcheck` on the scripts;
  - `actionlint` on the workflows;
  - validation of the framework JSON, `.mcp.json`, the Claude settings and the agents' front matter;
  - the fixture tests.

## License

[MIT](LICENSE)
