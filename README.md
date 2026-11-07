# agentic-qa-platform

Reusable GitHub Actions workflows and AI agents for UI testing across **Playwright**, **Cypress** and
**Selenium (Java/Maven)**. The agents run on **Claude Code** (default) or **OpenCode**.

- **Self-healing.** `test-and-heal.yml` runs your suite. When it fails:
  - a *triage* agent classifies every failure (`SELECTOR_DRIFT`, `REAL_BUG`, `FLAKY`, `ENV`);
  - a *healer* agent repairs only the selector-drift failures, changing locators and waits but never assertions;
  - `anti-cheat.sh` checks the diff;
  - a *pr-writer* agent opens an evidence-first pull request.
- **Test generation.** `generate-tests.yml` turns a spec into tests. The spec can be a markdown file, a
  [Spec Kit](#spec-sources) feature folder, a GitHub issue or a Jira ticket.
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
  │          upload "test-results"    stage-agents.sh (engine-specific config)
  │                                   run-agent.sh triage → results/triage.json
  │                                   run-agent.sh healer (only if SELECTOR_DRIFT) → results/heal-report.json
  │                                   anti-cheat.sh → run-agent.sh pr-writer → PR_BODY.md
  │                                   open PR auto-heal/<run_id>, or update + comment on the open auto-heal PR
  └─ _select-framework.yml validates the engine and reads frameworks/<framework>.json

generate-tests.yml
  config ──► generate: fetch-spec.sh → spec.md
                       stage-agents.sh → run-agent.sh planner → results/plan.md
                       run-agent.sh generator → tests + results/generate-report.json
                       run tests → anti-cheat.sh → run-agent.sh pr-writer → PR auto-generate/<run_id>
```

- **`scripts/stage-agents.sh`** writes the agents, the shared rules ([`AGENT-RULES.md`](AGENT-RULES.md)),
  permissions and MCP config in the format of the selected engine.
- **`scripts/run-agent.sh`** runs one agent non-interactively with its own turn budget. It fails if the agent
  didn't write its result file, instead of silently reporting "no changes".

## Agent engines

| Engine | Install | Secret | Model | Known gaps |
|---|---|---|---|---|
| `claude` (default) | `npm i -g @anthropic-ai/claude-code@<claude_code_version>` (default `2.1.283`) | `ANTHROPIC_API_KEY` | Claude Code's default | None known. This is the engine the agents were written and checked against: exact turn limits (`--max-turns`), and Bash limited by `settings/claude-settings.json`. |
| `opencode` | `npm i -g opencode-ai@<opencode_version>` (default `1.0.0`) | At least one of `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`, `OPENAI_API_KEY` (the one matching the model's provider) | `opencode_model`, default `deepseek/deepseek-flash` | See the list below. |

OpenCode's known gaps:
- No turn cap: `MAX_TURNS` is emulated with a time limit of 30 s per turn.
- Agents are staged with `mode: all`, so that `opencode run --agent` can use them as its primary agent.
- MCP tools are named `browser_<tool>`.
- How its permission patterns behave (rule precedence, path patterns for edits) depends on the OpenCode version.
- The `opencode_version` default is unverified.

**What staging writes for each engine:**
- **claude:**
  - `.claude/agents/*.md`;
  - `.claude/settings.json` (Bash allow/deny list);
  - `.mcp.json` (from `settings/claude-mcp.json`, MCP version pinned).
- **opencode:**
  - `.opencode/agents/<name>.md`, with front matter converted to `description`, `mode`, `model` and a `tools` map,
    where `mcp__browser__*` becomes `"browser_*"`;
  - `AGENTS.md`, a copy of `AGENT-RULES.md`;
  - `opencode.json`: the `browser` MCP server (`type: local`) merged with `settings/opencode-permissions.json`.
    Bash uses the same allow/deny list as Claude, edits are limited to the test directory, `results/` and
    `PR_BODY.md`, and `webfetch` is denied.

> **Healing and generation quality depend on the model.** Smaller or cheaper models misclassify failures more often,
> pick weaker locators, and give up sooner. Every engine and model gets the same guardrails, `anti-cheat.sh` and human
> review, but those guardrails can't make a weak model good.
>
> **The `opencode` engine is untested until its first real run.** Its staging and command lines are covered by the
> fixture tests, but no workflow has run OpenCode end to end yet.

## Repository layout

```text
.
├── AGENT-RULES.md               shared rules every agent follows (engine-neutral)
├── LICENSE                      MIT
├── frameworks/                  one config per framework
│   ├── playwright.json
│   ├── cypress.json
│   └── selenium.json
├── agents/                      agent definitions (Claude Code format; converted for OpenCode when staged)
│   ├── common/                  triage.md, pr-writer.md
│   ├── playwright/              planner.md, generator.md, healer.md
│   ├── cypress/                 planner.md, generator.md, healer.md
│   └── selenium/                planner.md, generator.md, healer.md
├── settings/
│   ├── claude-mcp.json          MCP server "browser" (@playwright/mcp, headless, pinned version)
│   ├── claude-settings.json     Claude Code Bash allow/deny list
│   └── opencode-permissions.json  OpenCode bash/edit/webfetch permissions ({TEST_DIR} filled in when staged)
├── scripts/
│   ├── fetch-spec.sh            spec file, Spec Kit folder, GitHub issue or Jira ticket → spec.md
│   ├── parse-report.sh          JUnit XML (any framework) → results/failures.json
│   ├── anti-cheat.sh            fails on forbidden paths, weakened assertions, skips, sleeps, long timeouts
│   ├── stage-agents.sh          stages agents, rules, permissions and MCP config for ENGINE=claude|opencode
│   └── run-agent.sh             runs one agent on the selected engine, checks its expected output
├── tests/                       fixture tests for the scripts (bash tests/run-tests.sh)
│   ├── anti-cheat/              base/ sample project + *.diff fixtures (pass-* and fail-*)
│   ├── parse-report/            Playwright, Cypress, Surefire XML + expected JSON
│   └── fetch-spec/              Spec Kit folder fixture + expected spec.md
├── .github/workflows/
│   ├── _select-framework.yml    validates the engine, reads frameworks/<framework>.json → outputs
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

1. Add a **dedicated, low-quota** model API key as a secret (see [Security](#security)):
   - `ANTHROPIC_API_KEY` for `engine: claude`, the default;
   - for `engine: opencode`, one of `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY` or `OPENAI_API_KEY`.

   Also add `JIRA_TOKEN` if you generate tests from Jira.
2. Add the variable `APP_URL`: a running, **disposable test instance** of the app that CI can reach. Never use
   production.
3. Under **Settings → Actions → General**, enable **Allow GitHub Actions to create and approve pull requests**.
4. Create the labels `auto-heal`, `auto-generate` and `ready-for-tests`. Only maintainers should be able to apply
   `ready-for-tests`.
5. Copy `templates/caller-test-and-heal.yml` and `templates/caller-generate.yml` to `.github/workflows/`.
6. In both files:
   - check that the `uses:` line points at this repository (the templates use
     `yorkzhangyong-bot/agentic-qa-platform`);
   - set `framework` (`playwright`, `cypress` or `selenium`) and, if needed, `engine` and `test_dir`.
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
| `engine` | no | `claude` | Agent engine: `claude` or `opencode`. Anything else fails in the `config` job, before the tests run. |
| `node_version` | no | `"20"` | Node.js version. Always installed, because the engines and the MCP server need it. |
| `java_version` | no | `"17"` | Java version. Installed when the framework runs Maven or Gradle. |
| `triage_max_turns` | no | `15` | Turn budget for the triage agent. Exact on claude; emulated on opencode. |
| `heal_max_turns` | no | `40` | Turn budget for the healer agent. Exact on claude; emulated on opencode. |
| `claude_code_version` | no | `"2.1.283"` | Version of `@anthropic-ai/claude-code` (engine `claude`). |
| `opencode_version` | no | `"1.0.0"` | Version of `opencode-ai` (engine `opencode`). Unverified default; set it to the version you test with. |
| `opencode_model` | no | `deepseek/deepseek-flash` | Model for the OpenCode agents, as `provider/model`. |
| `playwright_mcp_version` | no | `"0.0.84"` | Version of `@playwright/mcp`, written into the staged MCP config. |
| `platform_ref` | no | `""` | Optional branch, tag or SHA of this repository to take scripts, agents and configs from. Empty uses the commit of the called workflow (`job.workflow_sha`). |

| Secret | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | with `engine: claude` | Dedicated, low-quota key used by Claude Code. |
| `DEEPSEEK_API_KEY` | one of these three with `engine: opencode` | Provider key for OpenCode. |
| `OPENROUTER_API_KEY` | one of these three with `engine: opencode` | Provider key for OpenCode. |
| `OPENAI_API_KEY` | one of these three with `engine: opencode` | Provider key for OpenCode. |
| `JIRA_TOKEN` | no | Accepted so both workflows share the same secrets. Healing does not use it. |
| `PLATFORM_TOKEN` | no | Read token for this repository. Only needed if it is private. |

The secrets are optional in the workflow schema because which ones you need depends on `engine`. The first step of
the agent job checks them and fails early, and it warns if `opencode_model`'s provider has no key. Each agent step
only receives the keys of the selected engine.

| Output | Description |
|---|---|
| `failed` | `'true'` if the test run failed. |
| `pr_url` | URL of the auto-heal pull request that was opened or updated. |

How it runs:

- **`config`** validates `engine` and reads the framework config.
- **`test`** checks out the commit under test and outputs its SHA. For pull requests that is the PR head commit,
  not GitHub's merge commit. It runs the suite with `continue-on-error` and always uploads the `test-results`
  artifact.
- **`heal`** checks out exactly the SHA the test job tested.
  - It runs only when the tests failed, gets `contents: write` and `pull-requests: write`, and is skipped for
    pull requests from forks, which don't receive secrets.
  - The healer runs only if triage found `SELECTOR_DRIFT` items.
  - The job fails if triage or the healer doesn't write its report.
  - The pr-writer agent runs with 20 turns.
  - The job's timeout is 90 minutes.
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
| `engine` | no | `claude` | Agent engine: `claude` or `opencode`. |
| `spec_path` | no | `""` | Markdown spec file or Spec Kit feature folder in the repository. Highest priority (see [Spec sources](#spec-sources)). |
| `issue_number` | no | `""` | GitHub issue whose title and body are the spec. |
| `jira_key` | no | `""` | Jira issue key, e.g. `QA-123`. Fetched from REST API v3. |
| `jira_base_url` | no | `""` | Jira site, e.g. `https://your-company.atlassian.net`. Required with `jira_key`. |
| `jira_email` | no | `""` | Jira Cloud account email, for basic auth with `JIRA_TOKEN`. If empty, the token is sent as a Bearer token (Jira Data Center PAT). |
| `node_version` | no | `"20"` | Node.js version. |
| `java_version` | no | `"17"` | Java version (Maven/Gradle frameworks). |
| `plan_max_turns` | no | `20` | Turn budget for the planner agent. |
| `generate_max_turns` | no | `80` | Turn budget for the generator agent. |
| `claude_code_version` | no | `"2.1.283"` | Version of `@anthropic-ai/claude-code` (engine `claude`). |
| `opencode_version` | no | `"1.0.0"` | Version of `opencode-ai` (engine `opencode`). Unverified default. |
| `opencode_model` | no | `deepseek/deepseek-flash` | Model for the OpenCode agents. |
| `playwright_mcp_version` | no | `"0.0.84"` | Version of `@playwright/mcp`. |
| `platform_ref` | no | `""` | Optional ref override, as in `test-and-heal.yml`. Empty uses the commit of the called workflow. |

Secrets: the same model keys as `test-and-heal.yml`, plus `JIRA_TOKEN` (required with `jira_key`) and
`PLATFORM_TOKEN` (optional).

Output: `pr_url`.

Permissions: `contents: write` and `pull-requests: write`, plus `issues: read` so it can read the issue.

How it runs:
- The job fails if the planner doesn't write `results/plan.md`, or if no test files change.
- The PR goes to branch `auto-generate/<run_id>` with the label `auto-generate`. It is opened as a **draft** if
  the tests fail after generation, for example because of a possible app bug the generator refused to hide.
- Timeout (90 minutes) and concurrency work as in `test-and-heal.yml`.

### `_select-framework.yml` (used by both workflows)

Inputs: `framework`, `engine` and `platform_ref`, plus the optional secret `PLATFORM_TOKEN`. It fails at once on an
unknown `engine`. It outputs every key of `frameworks/<framework>.json`: scalars as strings, arrays and objects as
compact JSON. It also outputs these derived values:
- `install_script`: the install commands, one per line.
- `forbidden_paths_csv`: the forbidden paths, comma-separated.
- `runtime`: `java` if the commands use Maven or Gradle, otherwise `node`.
- `engine`: the validated engine.

## Spec sources

`scripts/fetch-spec.sh` writes `spec.md` from the first source that is set: `spec_path`, then `issue_number`, then
`jira_key`. It fails with a clear message if none is set. The first line of `spec.md` is always a `# <title>`
heading, which becomes the PR title.

- **File.** A `spec_path` that points at a file is copied unchanged.
- **Directory (GitHub Spec Kit).** If `spec_path` is a directory, the files that exist are concatenated in this
  order, each under a `## <file>` header:
  `spec.md`, `plan.md`, `data-model.md`, `contracts/*.md`, `contracts/*.yaml` / `*.yml` (sorted), `quickstart.md`,
  `tasks.md`.
  - YAML contracts are wrapped in fenced code blocks.
  - Other files, such as `research.md`, are ignored.
  - The title comes from the first `#` heading of the folder's `spec.md`, or the folder name if there isn't one.
  - A directory that contains none of these files is an error.

Example: a Spec Kit feature folder in the consumer repository,

```text
specs/003-feature/
├── spec.md            # FR-001 … FR-003, SC-001
├── plan.md
├── data-model.md
├── contracts/
│   └── coupons-api.yaml
├── quickstart.md
└── tasks.md
```

generated from a manual run of `caller-generate.yml` with `spec_path: specs/003-feature`, or from a caller that
passes it:

```yaml
    with:
      framework: playwright
      spec_path: specs/003-feature
```

**Traceability.** When the spec uses Spec Kit ids (`FR-###`, `SC-###`):
- The planner puts the ids each scenario covers in its title, e.g.
  `### 3. Rejects an expired coupon — P1 (FR-003, SC-001)`, and suggests a test name that carries them.
- The generator uses that name and adds a doc comment, e.g. `/** Covers FR-003, SC-001 */` above
  `test('3. rejects an expired coupon [FR-003]', …)`.
- Requirements the plan doesn't cover are listed under "Open questions".

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
| `mcp` | MCP server the agents use (`browser`), defined in `settings/claude-mcp.json`. |

## Add a new framework

1. **Config.** Create `frameworks/<name>.json` with every key above.
   - `run` must write JUnit XML matching `report_glob`. Put reporter settings in `env`.
   - If the framework needs Java, call `mvn` or `gradle` in the commands so `runtime` resolves to `java`.
2. **Agents.** Create `agents/<name>/planner.md`, `generator.md` and `healer.md`, starting from the closest
   existing framework.
   - Keep the front-matter names `planner`, `generator` and `healer`; the workflows run those agents by name.
   - Describe the framework's idioms, locator API, test command and single-test re-run command.
3. **Bash permissions.** Allow the framework's test command for both engines. Otherwise the agents can't run tests.
   - In `settings/claude-settings.json`, e.g. `Bash(npx wdio run:*)`.
   - In `settings/opencode-permissions.json`, e.g. `"npx wdio run*": "allow"`.
4. **Guardrails.** If the framework has its own skip/focus syntax, sleep API or assertion keywords:
   - add them to the patterns in `scripts/anti-cheat.sh`;
   - add `pass-*` and `fail-*` fixtures under `tests/anti-cheat/`.
5. **MCP.** If the agents need another MCP server:
   - Add it to `settings/claude-mcp.json` and set `mcp` in the config. Staging converts it for OpenCode, and the
     workflows allow `mcp__<mcp>__*`.
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

Every rule has `pass-*` and `fail-*` fixtures in `tests/anti-cheat/`. The script runs the same way for both engines.

### Workflow protections

- The job fails if an agent modified the platform checkout (`.agentic-qa/`), because anti-cheat would then be
  running modified code.
- The job fails if the pr-writer changed any file after anti-cheat ran.
- The staged files of both engines and the run artefacts are listed in `.git/info/exclude`. Staged files:
  `.claude/agents/*`, `.claude/settings.json`, `.mcp.json`, `.opencode/` (which holds the staged `agents/`),
  `AGENTS.md`, `opencode.json`. Run
  artefacts: `results/`, `spec.md`, `PR_BODY.md`.
- If staging overwrote any of those files that the repository tracks, they are restored before the PR is created.

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
- **Model API keys should be dedicated, low-quota keys** used only by these workflows. Each agent step receives
  only the keys of the selected engine. Within that step the key is in the agent's environment, so treat it as
  exposed to the agent and cap what it can spend.
- **Only maintainers should be able to apply the `ready-for-tests` label.** Issue and ticket text become agent
  input, so don't grant the triage role broadly, and review an issue before labelling it.
- **Bash is restricted on both engines.** Agents can run only:
  - `npx playwright test`, `npx playwright install`, `npx cypress run`, `mvn`, `pytest`;
  - `git status`, `git diff`, `git log`;
  - `ls`, `cat` and `mkdir`.

  `curl`, `wget`, `git push`, `git config`, `env`, `printenv`, `echo $ANTHROPIC*`, `nc` and `ssh` are explicitly
  denied.
  - **Claude Code:** the list is staged as `.claude/settings.json`, and the agents run with
    `--permission-mode dontAsk` and no `Bash` in `--allowedTools`.
  - **OpenCode:** it is merged into `opencode.json` as `permission.bash`, together with edit limits and
    `webfetch: deny`.
- **Checkouts use `persist-credentials: false`**, so agents can't push with the workflow token. Only
  `create-pull-request` pushes, after the guardrails pass.
- **Third-party actions are pinned to a commit SHA.** `peter-evans/create-pull-request` is pinned to `5f6978f…`
  (`# v8.1.1`). GitHub's own `actions/*` use major tags.

## Notes

- `@playwright/mcp` drives the Google Chrome that GitHub-hosted Ubuntu runners include. Self-hosted runners
  need Chrome, `jq`, `python3`, GNU `timeout` (for OpenCode) and Actions Runner v2.327.1 or later (all actions
  used, including `create-pull-request@v8`, run on Node 24).
- Pull requests opened with the default `GITHUB_TOKEN` don't trigger other workflows. Re-run CI on them
  manually, or switch the action to a GitHub App token.
- The artifact name `test-results` is fixed, so call `test-and-heal.yml` once per workflow run.
- To run an agent locally, run these from the repository under test with the platform checked out in
  `.agentic-qa/`:
  1. `ENGINE=claude FRAMEWORK=playwright bash .agentic-qa/scripts/stage-agents.sh` (or `ENGINE=opencode`)
  2. `ENGINE=claude AGENT=triage PROMPT="Triage results/failures.json" MAX_TURNS=15 EXPECTED_OUTPUT=results/triage.json bash .agentic-qa/scripts/run-agent.sh`

## Development

- `bash tests/run-tests.sh` runs the fixture tests offline:
  - `anti-cheat.sh`: every `tests/anti-cheat/*.diff` is applied to `tests/anti-cheat/base/`; `pass-*` must pass and
    `fail-*` must report the rule named in its header;
  - `parse-report.sh`: the sample reports must produce their `*.expected.json`;
  - `fetch-spec.sh`: the Spec Kit folder must produce `003-feature.expected.md`;
  - `stage-agents.sh`: staging is checked for both engines;
  - `run-agent.sh`: the command lines are checked with stub `claude` / `opencode` executables.
- `.github/workflows/ci.yml` runs on every push and pull request:
  - `shellcheck` on the scripts;
  - `actionlint` on the workflows;
  - validation of the framework JSON, `settings/*.json`, `AGENT-RULES.md` and the agents' front matter;
  - the fixture tests.

## License

[MIT](LICENSE)
