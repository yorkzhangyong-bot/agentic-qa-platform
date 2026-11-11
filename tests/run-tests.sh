#!/usr/bin/env bash
# run-tests.sh — fixture tests for the platform scripts. No network access or API keys needed.
#
#   anti-cheat.sh    Each tests/anti-cheat/*.diff is applied to a fresh git repo built from tests/anti-cheat/base/.
#                    pass-*.diff must exit 0; fail-*.diff must exit 1 and report the rule in its "# rule:" header.
#                    An optional "# forbidden: a,b" header replaces the default framework forbidden paths.
#   parse-report.sh  Each tests/parse-report/<name>.xml is parsed in a sample project and compared with
#                    tests/parse-report/<name>.expected.json; with no report files the output must be [].
#   write-summary.sh The same sample reports, tests/write-summary/edge-cases.xml and, with triage.json, the
#                    Playwright sample must produce tests/write-summary/<name>.expected.md. No reports, broken
#                    reports, a broken or missing triage file, an unwritable summary and a missing python3 are
#                    checked too; every run must exit 0.
#   fetch-spec.sh    The Spec Kit folder tests/fetch-spec/specs/003-feature must produce
#                    tests/fetch-spec/003-feature.expected.md; an empty folder must fail; a file is copied unchanged.
#   stage-agents.sh  Staging for claude and for opencode in a scratch repo must produce the expected files.
#   run-agent.sh     With stub `claude` / `opencode` executables, the expected command lines must be built, and a
#                    missing EXPECTED_OUTPUT must fail the run.
#   check-triage.sh  A triage.json that classifies every failure must pass, and one that classifies some of them
#                    must pass with a warning. Nothing to triage, a missing failures.json, a missing, empty or broken
#                    triage.json, one without an "items" array, and one that classifies none of the failures must
#                    each fail with the "No triage result" error and its reason.
#   locator-check.sh  On git histories of healed tests (tests/locator-check/), with a failing run and recorded
#                    probe output: another button's name and a button turned link must be ❌ and make a draft; a
#                    test ID and a label without a snapshot ❓ without a draft; a strict-mode fix and a page object
#                    locator over several lines ✅; a listed rename passes and is logged; Cypress is skipped; no
#                    changed locator passes. The probe's hook (scripts/locator-probe/playwright.cjs) runs against a
#                    stand-in @playwright/test. The same check with a real browser is tests/locator-probe/run.sh (CI).
#   platform checkout  tests/platform-checkout/check.py reads the workflows a consumer calls and builds each sparse
#                    checkout of the platform with git, as actions/checkout does. None may use cone mode or hold
#                    evals/, tests/, BACKLOG.md, README.md or .github/; every agent job must run
#                    check-platform-checkout.sh before its first agent; every platform path a job's steps, scripts
#                    and agents name must be in that job's checkout; the triage eval's workspace must have the same
#                    parts. From the agent jobs' checkout, stage-agents.sh must stage every framework for both
#                    engines, run-agent.sh must find what it hands Claude Code, and locator-check.sh the probe.
#                    check-platform-checkout.sh must pass that checkout, and fail a full one and one with BACKLOG.md.
#   report-defects.sh  prepare on tests/report-defects/triage.json + failures.json must produce
#                    defect-candidates.expected.json; fingerprints must match their definition, survive other timings,
#                    ids and line numbers, and change with the error. publish runs with a stub `gh`: new issues, a
#                    comment on an open issue, failed gh calls (never a failed run), missing and stray reports.
#   load-app-env.sh  Each tests/load-app-env/<name>.env is passed as APP_ENV: "# expect: ok" fixtures must produce
#                    <name>.expected in $GITHUB_ENV with every value masked; "# expect: error on line N…" fixtures
#                    must fail naming those lines and load nothing. No value may be printed outside ::add-mask::.
#                    Also: CRLF, empty values, % in masks, -- COMMAND, --check, and a guard that no agent step and
#                    no job-wide env in the workflows gets APP_ENV.
#   evals/triage/run-eval.py  --check accepts evals/triage/cases.jsonl and lists what hide mode deletes; it rejects
#                    a bad label and a workspace file that gives an answer away. Runs with a stub engine (every
#                    failure SELECTOR_DRIFT, 3 cases x 2 runs) must report the expected scores, the CI prompt, the
#                    result-file metadata and the engine's full-transcript flags (claude and opencode); a run whose
#                    log quotes the answer key is invalid; opencode's database is created before the parallel runs;
#                    and a missing triage.json is explained (startup error, turn limit, timeout, rejected permission,
#                    wrong place, last message); a multi-line error (a reporter's own text) reaches the JUnit report
#                    unchanged. Each attempt's error-context.md is built as Playwright 1.65 writes it, in the folder
#                    Playwright names (checked against a real Kestrel run): the case's page snapshot leaves the
#                    report for the file (a one-line error with one is still completed), an attempt without an
#                    "Error Context:" line gets one, and a malformed snapshot or path is refused. --no-snapshots
#                    writes no such file, with the same report, and its
#                    result file says so. Hide mode (CI set) runs on a scratch clone: it must delete all of
#                    evals/ and the rest of the answer key, .git included, before the stub agent looks for it, report
#                    that agent's run as invalid and unscored, and refuse to delete a .git with uncommitted work. No
#                    model API is called.
#   agent permissions  tests/engine-permissions/check.py runs the real claude and opencode, as staged for CI, against
#                    a fake model (fake_model.py) that plays a fixed script of tool calls: `ls && env`, `ls; env`,
#                    `ls | env`, `echo $(env)`, `ls\nenv`, backticks, `$VAR`, redirects and a quoted `|` must be
#                    refused without running; `npx playwright test x.spec.ts`, `git status` and writing
#                    results/triage.json must work; OpenCode must refuse writing application source. A file outside
#                    the workspace must be refused (`cat` on both engines; OpenCode's read and grep too, by its
#                    external_directory rule), and the agent must then go on to write results/triage.json. With that
#                    rule back at OpenCode's default "ask", the run must end at the refusal; OpenCode's folder for
#                    truncated output must stay readable. Skipped when an engine isn't installed, unless
#                    REQUIRE_ENGINES=1 (as in CI). The stage-agents.sh checks also cover the permission files: no allow
#                    in an OpenCode agent file, the metacharacter denies after every allow rule, the same denies for
#                    Claude Code, and external_directory denied in OpenCode.
#
# Usage: bash tests/run-tests.sh          (exit code 0 when every check passes)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
ok() { passed=$((passed + 1)); printf '  ok    %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        /'; }

echo "anti-cheat.sh"
repo="$work/repo"
mkdir -p "$repo"
cp -R "$root/tests/anti-cheat/base/." "$repo/"
git -C "$repo" init -q
git -C "$repo" config user.email ci@example.com
git -C "$repo" config user.name ci
git -C "$repo" config core.autocrlf false
git -C "$repo" add -A
git -C "$repo" commit -qm base
default_forbidden="src/main/,cypress/support/commands.*"
for fixture in "$root"/tests/anti-cheat/*.diff; do
  name="$(basename "$fixture" .diff)"
  git -C "$repo" reset -q --hard
  git -C "$repo" clean -qfdx
  if ! git -C "$repo" apply "$fixture"; then
    bad "$name" "the fixture does not apply to tests/anti-cheat/base"
    continue
  fi
  forbidden="$(sed -n 's/^# forbidden: //p' "$fixture")"
  rule="$(sed -n 's/^# rule: //p' "$fixture")"
  set +e
  output="$(cd "$repo" && bash "$root/scripts/anti-cheat.sh" "${forbidden:-$default_forbidden}" HEAD 2>&1)"
  code=$?
  set -e
  case "$name" in
    pass-*)
      if [ "$code" -eq 0 ]; then ok "$name"; else bad "$name" "expected exit 0, got $code"$'\n'"$output"; fi
      ;;
    fail-*)
      if [ "$code" -eq 1 ] && grep -qF "[$rule]" <<< "$output"; then
        ok "$name"
      else
        bad "$name" "expected exit 1 reporting [$rule], got $code"$'\n'"$output"
      fi
      ;;
    *)
      bad "$name" "fixture names must start with pass- or fail-"
      ;;
  esac
done

echo
echo "parse-report.sh"
project="$work/project"
mkdir -p "$project/tests" "$project/cypress/e2e" "$project/src/test/java/com/acme"
touch "$project/tests/checkout.spec.ts" "$project/cypress/e2e/login.cy.ts" "$project/src/test/java/com/acme/LoginTest.java"
for fixture in "$root"/tests/parse-report/*.xml; do
  name="$(basename "$fixture" .xml)"
  rm -rf "$project/results"
  mkdir -p "$project/results"
  cp "$fixture" "$project/results/"
  (cd "$project" && bash "$root/scripts/parse-report.sh" 'results/*.xml' > /dev/null)
  if python3 - "$project/results/failures.json" "${fixture%.xml}.expected.json" <<'PY'
import json
import sys

actual, expected = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3])
sys.exit(0 if actual == expected else 1)
PY
  then
    ok "$name"
  else
    bad "$name" "results/failures.json differs from $(basename "${fixture%.xml}").expected.json:"$'\n'"$(cat "$project/results/failures.json")"
  fi
done
rm -rf "$project/results"
set +e
output="$(cd "$project" && bash "$root/scripts/parse-report.sh" 'results/*.xml' 2>&1)"
code=$?
set -e
if [ "$code" -eq 0 ] && [ "$(cat "$project/results/failures.json")" = "[]" ]; then
  ok "no-report-files"
else
  bad "no-report-files" "expected exit 0 and [], got exit $code"$'\n'"$output"
fi

echo
echo "write-summary.sh"
summary="$work/summary.md"
summary_reports() {  # summary_reports <report>...: make these the only files in the sample project's results/
  rm -rf "$project/results"
  mkdir -p "$project/results"
  if [ "$#" -gt 0 ]; then cp "$@" "$project/results/"; fi
}
summary_run() {  # summary_run <framework> <arg>...: run write-summary.sh in the sample project; sets $code
  rm -f "$summary"
  set +e
  (cd "$project" && env GITHUB_STEP_SUMMARY="$summary" FRAMEWORK="$1" COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/shop SUMMARY_TITLE="${SUMMARY_TITLE:-}" \
    bash "$root/scripts/write-summary.sh" "${@:2}" > "$work/summary.log" 2>&1)
  code=$?
  set -e
}
summary_expect() {  # summary_expect <name>: exit 0 and exactly tests/write-summary/<name>.expected.md
  if [ "$code" -eq 0 ] && diff -u "$root/tests/write-summary/$1.expected.md" "$summary" > "$work/summary.diff" 2>&1; then
    ok "$1"
  else
    bad "$1" "exit $code"$'\n'"$(cat "$work/summary.diff" "$work/summary.log" 2> /dev/null)"
  fi
}
check_texts() {  # check_texts <name> <file> <+present|-absent>...: exit 0, and each text is (+) or isn't (-) in the file
  local name="$1" file="$2" problems="" item
  shift 2
  for item in "$@"; do
    if grep -qF -- "${item:1}" "$file" 2> /dev/null; then
      [ "${item:0:1}" = + ] || problems+="unexpected: ${item:1}"$'\n'
    else
      [ "${item:0:1}" = - ] || problems+="missing: ${item:1}"$'\n'
    fi
  done
  if [ "$code" -eq 0 ] && [ -z "$problems" ]; then
    ok "$name"
  else
    bad "$name" "exit $code"$'\n'"$problems$(cat "$file" 2> /dev/null)"
  fi
}
summary_check() {  # summary_check <name> <+present|-absent>...: check_texts on the write-summary.sh output
  local name="$1"
  shift
  check_texts "$name" "$summary" "$@"
}
for name in playwright cypress surefire passing; do
  case "$name" in surefire) framework=selenium ;; passing) framework=playwright ;; *) framework="$name" ;; esac
  summary_reports "$root/tests/parse-report/$name.xml"
  summary_run "$framework" 'results/*.xml'
  summary_expect "$name"
done
summary_reports "$root/tests/write-summary/edge-cases.xml"
summary_run selenium 'results/*.xml'
summary_expect edge-cases
summary_reports "$root/tests/parse-report/playwright.xml"
summary_run playwright 'results/*.xml' "$root/tests/write-summary/triage.json"
summary_expect with-triage
summary_reports "$root/tests/parse-report/cypress.xml"
summary_run cypress 'results/*.xml' "$root/tests/write-summary/triage.json"
summary_check not-triaged "+| Test | File | Error | Triage |" "+| _not triaged_ |"
summary_reports "$root/tests/parse-report/playwright.xml"
printf '{"items": [{"name": "checkout > applies a coupon", "classname": "other", "classification": "FLAKY", "reason": "Passed on re-run."}]}\n' \
  > "$work/triage-retyped.json"
summary_run playwright 'results/*.xml' "$work/triage-retyped.json"
summary_check retyped-triage-name "+| **FLAKY**: Passed on re-run. |"
summary_reports "$root/tests/parse-report/playwright.xml" "$root/tests/parse-report/passing.xml"
summary_run playwright 'results/*.xml'
summary_check multiple-reports "+**Total** 4 " "+**Passed** 3 " "+**Failed** 1 " "+**Duration** 5.2s"
summary_reports
summary_run playwright 'results/*.xml'
summary_check no-reports "+No tests found" "-**Total**"
summary_reports "$root/tests/parse-report/passing.xml"
head -c 300 "$root/tests/parse-report/playwright.xml" > "$project/results/broken.xml"
summary_run playwright 'results/*.xml'
summary_check unparsable-report "+could not parse" "+results/broken.xml" "+**Total** 2 " "+**Passed** 2 "
summary_reports "$root/tests/parse-report/playwright.xml"
printf 'not json\n' > "$work/triage-broken.json"
summary_run playwright 'results/*.xml' "$work/triage-broken.json"
summary_check unparsable-triage "+could not read the triage file" "+| Checkout " "-| Triage |"
summary_run playwright 'results/*.xml' "$work/no-such-triage.json"
summary_check missing-triage "+No triage results" "-| Triage |"
summary_reports "$root/tests/parse-report/passing.xml"
SUMMARY_TITLE="Test results after healing" summary_run playwright 'results/*.xml'
summary_check custom-title "+## Test results after healing: playwright @"
set +e
(cd "$project" && env GITHUB_STEP_SUMMARY="$work/no-such-dir/summary.md" bash "$root/scripts/write-summary.sh" \
  'results/*.xml' > "$work/summary.log" 2>&1)
code=$?
set -e
if [ "$code" -eq 0 ]; then
  ok "unwritable-summary"
else
  bad "unwritable-summary" "expected exit 0 even when the summary can't be written, got $code"$'\n'"$(cat "$work/summary.log")"
fi
rm -f "$summary"
set +e
(cd "$project" && env PATH=/nonexistent GITHUB_STEP_SUMMARY="$summary" "$BASH" "$root/scripts/write-summary.sh" \
  'results/*.xml' > "$work/summary.log" 2>&1)
code=$?
set -e
summary_check no-python3 "+python3 is not installed"

echo
echo "fetch-spec.sh"
specs="$work/spec-project"
mkdir -p "$specs/specs/empty"
cp -R "$root/tests/fetch-spec/specs/." "$specs/specs/"
if (cd "$specs" && SPEC_PATH=specs/003-feature SPEC_OUT=folder.md bash "$root/scripts/fetch-spec.sh" 2> /dev/null) \
   && diff -u "$root/tests/fetch-spec/003-feature.expected.md" "$specs/folder.md" > "$work/fetch.diff"; then
  ok "spec-kit-folder"
else
  bad "spec-kit-folder" "$(cat "$work/fetch.diff" 2> /dev/null)"
fi
if (cd "$specs" && SPEC_PATH=specs/empty SPEC_OUT=empty.md bash "$root/scripts/fetch-spec.sh" 2> /dev/null); then
  bad "empty-folder-fails" "expected a non-zero exit for a folder without any spec files"
else
  ok "empty-folder-fails"
fi
if (cd "$specs" && SPEC_PATH=specs/003-feature/spec.md SPEC_OUT=file.md bash "$root/scripts/fetch-spec.sh" 2> /dev/null) \
   && cmp -s "$specs/specs/003-feature/spec.md" "$specs/file.md"; then
  ok "single-file-unchanged"
else
  bad "single-file-unchanged" "SPEC_PATH pointing at a file must copy it unchanged"
fi

echo
echo "stage-agents.sh"
scratch="$work/scratch"
mkdir -p "$scratch"
git -C "$scratch" init -q
for engine in claude opencode; do
  if ! (cd "$scratch" && ENGINE="$engine" FRAMEWORK=playwright PLATFORM_DIR="$root" TEST_DIR=e2e \
        PLAYWRIGHT_MCP_VERSION=9.9.9 OPENCODE_MODEL=openrouter/test-model SKIP_MCP_WARMUP=1 \
        bash "$root/scripts/stage-agents.sh" > "$work/stage.log" 2>&1); then
    bad "$engine" "$(cat "$work/stage.log")"
    continue
  fi
  if python3 - "$root" "$scratch" "$engine" > "$work/stage.check" 2>&1 <<'PY'
import json
import pathlib
import re
import sys

root, scratch, engine = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
problems = []
METACHARACTERS = ("&", "|", ";", "`", "$", ">", "<", "\n")  # chaining, substitution, expansion, redirection


def expect(condition, message):
    if not condition:
        problems.append(message)


def read(path):
    return path.read_text(encoding="utf-8")


sources = sorted((root / "agents" / "common").glob("*.md")) + sorted((root / "agents" / "playwright").glob("*.md"))
exclude = read(scratch / ".git" / "info" / "exclude").splitlines()
for entry in ("/.claude/settings.json", "/.mcp.json", "/.opencode/", "/AGENTS.md", "/opencode.json", "/results/", "/PR_BODY.md"):
    expect(entry in exclude, f".git/info/exclude is missing {entry}")
if engine == "claude":
    for src in sources:
        dest = scratch / ".claude" / "agents" / src.name
        expect(dest.exists() and read(dest) == read(src), f"{dest.name} is not a copy of the platform agent")
    expect(read(scratch / ".claude" / "settings.json") == read(root / "settings" / "claude-settings.json"),
           ".claude/settings.json is not a copy of settings/claude-settings.json")
    deny = json.loads(read(root / "settings" / "claude-settings.json"))["permissions"]["deny"]
    for char in METACHARACTERS:  # deny rules win over allow rules in Claude Code, in any order
        expect(f"Bash(*{char}*)" in deny, f"claude-settings.json: no deny rule Bash(*{char!r}*)")
    mcp = json.loads(read(scratch / ".mcp.json"))
    expect(mcp["mcpServers"]["browser"]["args"][0] == "@playwright/mcp@9.9.9", f".mcp.json is not pinned: {mcp}")
else:
    for src in sources:
        staged = read(scratch / ".opencode" / "agents" / src.name)
        head, _, body = staged[4:].partition("\n---\n\n")
        expect(body == read(src).split("\n---\n", 1)[1].lstrip("\n"), f"{src.name}: body differs from the platform agent")
        expect("mode: all" in head and 'model: "openrouter/test-model"' in head, f"{src.name}: mode/model missing")
        listed = {t.strip() for t in re.search(r"^tools:(.*)$", read(src), re.M).group(1).split(",")}
        # OpenCode applies the agent file's rules last, and the last match wins: the file may only switch tools off.
        expect("tools:" not in head and "permission:" in head, f"{src.name}: expected a permission map, no tools map")
        rules = head.split("permission:", 1)[-1]
        expect("allow" not in rules, f"{src.name}: the agent file must not allow anything: {rules.strip()}")
        for permission, tools in {"read": {"Read"}, "edit": {"Write", "Edit"}, "bash": {"Bash"}, "glob": {"Glob"},
                                  "grep": {"Grep"}}.items():
            expect((f'"{permission}": deny' in rules) == (not tools & listed),
                   f"{src.name}: {permission} must be {'left to opencode.json' if tools & listed else 'denied'}")
        expect('"webfetch": deny' in rules, f"{src.name}: webfetch must be denied")
        expect(('"browser_*": deny' in rules) == ("mcp__browser__*" not in listed),
               f"{src.name}: browser_* must be {'left to opencode.json' if 'mcp__browser__*' in listed else 'denied'}")
    expect(not (scratch / ".opencode" / "agent").exists(), "agents must be staged in .opencode/agents/, not .opencode/agent/")
    expect(read(scratch / "AGENTS.md") == read(root / "AGENT-RULES.md"), "AGENTS.md is not a copy of AGENT-RULES.md")
    config = json.loads(read(scratch / "opencode.json"))
    expect(config["mcp"]["browser"] == {"type": "local", "command": ["npx", "@playwright/mcp@9.9.9", "--headless"],
                                        "enabled": True}, f"opencode.json mcp: {config['mcp']}")
    permission = config["permission"]
    expect(permission["edit"].get("*") == "deny" and permission["edit"].get("e2e/**") == "allow",
           f"edit rules: {permission['edit']}")
    bash = permission["bash"]
    expect(list(bash)[0] == "*" and bash["*"] == "deny" and bash.get("npx playwright test *") == "allow"
           and bash.get("git push *") == "deny", f"bash rules: {bash}")
    last_allow = max(n for n, key in enumerate(bash) if bash[key] == "allow")
    for char in METACHARACTERS:  # the last matching rule wins in OpenCode: these must come after every allow rule
        expect(bash.get(f"*{char}*") == "deny" and list(bash).index(f"*{char}*") > last_allow,
               f"bash: *{char!r}* must be denied after every allow rule")
    expect(permission["webfetch"] == "deny", "webfetch must be denied")
    # OpenCode's default for paths outside the workspace is "ask", and `opencode run` rejects every such request,
    # which ends the run. A deny refuses the call and the agent carries on.
    expect(permission.get("external_directory") == "deny", "external_directory must be denied, not asked")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
  then
    ok "$engine"
  else
    bad "$engine" "$(cat "$work/stage.check")"
  fi
done

echo
echo "run-agent.sh"
bin="$work/bin"
mkdir -p "$bin"
for stub in claude opencode; do
  cat > "$bin/$stub" <<'STUB'
#!/usr/bin/env bash
# Test stub: record the arguments, one per line, and optionally write the expected output file.
printf '%s\n' "$@" > "$STUB_ARGS"
if [ "${STUB_WRITE:-1}" = 1 ] && [ -n "${EXPECTED_OUTPUT:-}" ]; then
  mkdir -p "$(dirname "$EXPECTED_OUTPUT")"
  printf '{}\n' > "$EXPECTED_OUTPUT"
fi
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$bin/$stub"
done
run_case() {  # run_case <name> <expected exit> <expected args, joined with spaces, or -> <VAR=value>...
  local name="$1" want_code="$2" want_args="$3" code
  shift 3
  rm -f "$work/args.txt"
  set +e
  (cd "$scratch" && env PATH="$bin:$PATH" STUB_ARGS="$work/args.txt" PLATFORM_DIR="$root" PROMPT="Do the task." "$@" \
    bash "$root/scripts/run-agent.sh" > "$work/run.log" 2>&1)
  code=$?
  set -e
  local got_args=""
  if [ -f "$work/args.txt" ]; then got_args="$(tr '\n' ' ' < "$work/args.txt")"; got_args="${got_args% }"; fi
  if [ "$code" -eq "$want_code" ] && { [ "$want_args" = "-" ] || [ "$got_args" = "$want_args" ]; }; then
    ok "$name"
  else
    bad "$name" "exit $code (want $want_code)"$'\n'"args: $got_args"$'\n'"want: $want_args"$'\n'"$(cat "$work/run.log")"
  fi
}
run_case claude-browser-agent 0 \
  "-p Do the task. --agent triage --append-system-prompt-file $root/AGENT-RULES.md --settings $root/settings/claude-settings.json --allowedTools Read,Edit,Write,Glob,Grep,Agent,Task,mcp__browser__* --mcp-config .mcp.json --strict-mcp-config --permission-mode dontAsk --max-turns 7" \
  ENGINE=claude AGENT=triage MAX_TURNS=7 EXPECTED_OUTPUT=results/triage.json
run_case claude-agent-without-mcp 0 \
  "-p Do the task. --agent pr-writer --append-system-prompt-file $root/AGENT-RULES.md --settings $root/settings/claude-settings.json --allowedTools Read,Edit,Write,Glob,Grep,Agent,Task --strict-mcp-config --permission-mode dontAsk --max-turns 20" \
  ENGINE=claude AGENT=pr-writer MAX_TURNS=20 EXPECTED_OUTPUT=PR_BODY.md
run_case opencode-agent 0 \
  "run --agent triage --model openrouter/test-model Do the task." \
  ENGINE=opencode AGENT=triage MAX_TURNS=7 OPENCODE_MODEL=openrouter/test-model EXPECTED_OUTPUT=results/triage.json
run_case missing-output-fails 1 - ENGINE=claude AGENT=triage MAX_TURNS=7 EXPECTED_OUTPUT=results/triage.json STUB_WRITE=0
run_case early-stop-with-output-passes 0 - ENGINE=opencode AGENT=healer MAX_TURNS=7 EXPECTED_OUTPUT=results/heal-report.json STUB_EXIT=3
run_case unknown-engine-fails 2 - ENGINE=gemini AGENT=triage MAX_TURNS=7

echo
echo "check-triage.sh"
checks="$work/check-triage"
triage_check() {  # triage_check <name> <exit> <text> <failures.json or -> <triage.json or -> [VAR=value...]
  # Exit 1 must come with the "No triage result" error; exit 0 with no error, and no warning unless <text> is one.
  local name="$1" want_code="$2" want_text="$3" failures="$4" triage="$5" code fine=1
  shift 5
  rm -rf "$checks"
  mkdir -p "$checks/results"
  [ "$failures" = - ] || printf '%s' "$failures" > "$checks/results/failures.json"
  [ "$triage" = - ] || printf '%s' "$triage" > "$checks/results/triage.json"
  set +e
  (cd "$checks" && env "$@" bash "$root/scripts/check-triage.sh" > "$work/check-triage.log" 2>&1)
  code=$?
  set -e
  grep -qF -- "$want_text" "$work/check-triage.log" || fine=0
  if [ "$want_code" -eq 1 ]; then
    grep -qF "::error title=No triage result::" "$work/check-triage.log" || fine=0
    grep -qF "heal and report-defects don't run" "$work/check-triage.log" || fine=0
  else
    ! grep -qF "::error" "$work/check-triage.log" || fine=0
    [[ "$want_text" == ::warning* ]] || ! grep -qF "::warning" "$work/check-triage.log" || fine=0
  fi
  if [ "$code" -eq "$want_code" ] && [ "$fine" -eq 1 ]; then
    ok "$name"
  else
    bad "$name" "exit $code (want $want_code), want the text: $want_text"$'\n'"$(cat "$work/check-triage.log")"
  fi
}
two='[{"name":"a","classname":"a.spec.ts"},{"name":"b","classname":"b.spec.ts"}]'
triage_check classifies-every-failure 0 "classifies 2 item(s) for the 2 failing tests" "$two" \
  '{"items":[{"name":"a","classification":"REAL_BUG"},{"name":"b","classification":"FLAKY"}]}'
triage_check classifies-some-failures 0 \
  "::warning title=Some failures not triaged::results/triage.json classifies 1 of the 2 failing tests" \
  "$two" '{"items":[{"name":"a","classification":"ENV"}]}'
triage_check no-triage-file 1 "The triage agent wrote no results/triage.json for the 2 failing tests" "$two" - \
  TRIAGE_OUTCOME=failure
triage_check triage-agent-skipped 1 "The triage agent didn't run, because an earlier step failed" "$two" - \
  TRIAGE_OUTCOME=skipped
triage_check empty-triage-file 1 "The triage agent wrote no results/triage.json" "$two" ''
triage_check triage-not-json 1 "results/triage.json isn't valid JSON" "$two" '{"items": ['
triage_check triage-without-items 1 'isn'"'"'t a JSON object with an "items" array' "$two" '{}'
triage_check triage-bare-list 1 'isn'"'"'t a JSON object with an "items" array' "$two" '[{"classification":"REAL_BUG"}]'
triage_check triage-empty-items 1 "classifies none of the 2 failing tests" "$two" '{"items":[]}'
triage_check triage-unknown-labels 1 "classifies none of the 2 failing tests" "$two" \
  '{"items":[{"name":"a","classification":"selector drift"},{"name":"b"}]}'
triage_check nothing-to-triage 1 "found no failing test case in their JUnit reports" '[]' -
triage_check no-failures-file 1 "results/failures.json doesn't exist" - -

echo
echo "locator-check.sh"
locator_fixtures="$root/tests/locator-check"
locator_case() {  # locator_case <dir> <framework> <healed files, comma-separated> [VAR=value...]: targets, then report
  local dir="$work/locator-$1" framework="$2" files="$3" base file
  local -a healed
  shift 3
  rm -rf "$dir"
  mkdir -p "$dir/repo" "$dir/check"
  cp -R "$locator_fixtures/base/." "$dir/repo/"
  git -C "$dir/repo" init -q
  git -C "$dir/repo" config core.autocrlf false
  git -C "$dir/repo" add -A
  git -C "$dir/repo" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -qm base
  base="$(git -C "$dir/repo" rev-parse HEAD)"
  IFS=, read -r -a healed <<< "$files"
  for file in "${healed[@]}"; do cp "$locator_fixtures/healed/$file" "$dir/repo/$file"; done
  cp -R "$locator_fixtures/failing" "$dir/check/before"
  cp "$locator_fixtures/after.jsonl" "$dir/check/after.jsonl"  # what the probe would record
  printf 'Body written by the pr-writer.\n' > "$dir/repo/PR_BODY.md"
  set +e
  (cd "$dir/repo" && export FRAMEWORK="$framework" TEST_DIR=tests BASE_SHA="$base" PLATFORM_DIR="$root" \
      LOCATOR_CHECK_DIR="$dir/check" GITHUB_OUTPUT="$dir/outputs" GITHUB_STEP_SUMMARY="$dir/summary.md" \
    && for setting in "$@"; do export "${setting?}"; done \
    && bash "$root/scripts/locator-check.sh" targets && bash "$root/scripts/locator-check.sh" report) \
    > "$dir/log" 2>&1
  code=$?
  set -e
  cat "$dir/log" "$dir/repo/PR_BODY.md" "$dir/check/probe-targets.json" "$dir/repo/results/locator-check.json" \
    > "$dir/all" 2> /dev/null || true
}
# A mixed heal: a strict-mode fix to the same link, another button, a test ID, a label without a snapshot, and a
# button that became a link.
locator_case mixed playwright tests/e2e/settings.spec.ts,tests/e2e/delete.spec.ts,tests/e2e/profile.spec.ts,tests/e2e/checkout.spec.ts,tests/e2e/login.spec.ts
check_texts locator-check-flags-a-mismatch "$work/locator-mixed/all" "+status=mismatch" "+draft=true" \
  "+mismatches=2" "+unknown=2" "+Body written by the pr-writer." "+## Locator check" \
  "+❌ 2 of 5 changed locators point to an element with a different role or accessible name" \
  "+- ❌ \`tests/e2e/delete.spec.ts:5\` \`getByRole('button', { name: 'Delete' })\` → \`getByRole('button', { name: 'Cancel' })\`: button \"Delete\" → button \"Cancel\". The accessible name differs." \
  "+button \"Checkout\" → link \"Checkout\". The role differs." \
  "+- ❓ \`tests/e2e/login.spec.ts:5\`" "+unknown → button \"Sign in\". The old locator is a test ID" \
  "+unknown → textbox \"Display name\". There is no page snapshot from the failing run" \
  "+- ✅ \`tests/e2e/settings.spec.ts:5\`" "+link \"Settings\" → link \"Settings\". Same role and accessible name." \
  "+::warning title=Locator check::tests/e2e/delete.spec.ts:5" "+\"draft\": true" \
  "+\"getByRole('banner').getByRole('link', { name: 'Settings' })\"" "+\"getByTestId('sign-in-button')\""
# The same element: on the failing page (also through a page object a failing stack ran through, with a locator over
# several lines).
locator_case match playwright tests/e2e/settings.spec.ts,tests/pages/ProfilePage.ts
check_texts locator-check-passes-the-same-element "$work/locator-match/all" "+status=pass" "+draft=false" \
  "+✅ Every changed locator points to an element with the same role and accessible name as before." \
  "+- ✅ \`tests/pages/ProfilePage.ts:9\`" "+button \"Save changes\" → button \"Save changes\"." "-❌" "-❓"
# Unknown before (a test ID; a label with no snapshot) shows the element after, and doesn't make a draft.
locator_case unknown playwright tests/e2e/profile.spec.ts,tests/e2e/login.spec.ts
check_texts locator-check-unknown-is-no-draft "$work/locator-unknown/all" "+status=unknown" "+draft=false" \
  "+❓ 2 of 2 changed locators couldn't be compared" "+unknown → button \"Sign in\"." "-❌"
locator_case rename playwright tests/e2e/signin.spec.ts "LOCATOR_RENAMES=Dashboard -> Home
\"Sign in\" -> \"Log in\""
check_texts locator-check-accepts-a-listed-rename "$work/locator-rename/all" "+status=pass" "+draft=false" \
  "+::notice title=Locator check::tests/e2e/signin.spec.ts:5: accepted rename \"Sign in\" -> \"Log in\" from locator_renames." \
  "+button \"Sign in\" → button \"Log in\". Accepted rename from locator_renames: \"Sign in\" → \"Log in\"."
locator_case unlisted playwright tests/e2e/signin.spec.ts
check_texts locator-check-flags-an-unlisted-rename "$work/locator-unlisted/all" "+status=mismatch" "+draft=true" \
  "+button \"Sign in\" → button \"Log in\". The accessible name differs."
locator_case cypress cypress tests/e2e/delete.spec.ts
check_texts locator-check-skips-other-frameworks "$work/locator-cypress/all" "+supported=false" \
  "+status=unsupported" "+draft=false" "-## Locator check"
locator_case none playwright tests/e2e/notes.spec.ts
check_texts locator-check-without-changed-locators "$work/locator-none/all" "+status=none" "+draft=false" \
  "+✅ The healer changed no locator."
# The probe's hook, without Playwright: a stand-in @playwright/test shaped like the real one, whose export is the test
# function with every export also a property of it. The test files get a test whose page fixture records the first
# wait-for-element use of a target locator once, and leaves other locators and isVisible() alone.
mkdir -p "$work/probe/node_modules/@playwright/test"
cat > "$work/probe/node_modules/@playwright/test/index.js" <<'JS'
class Locator {
  constructor(selector) { this.selector = selector; }
  toString() { return this.selector; }
  async ariaSnapshot() { return `- button "${this.selector.includes('Cancel') ? 'Cancel' : 'Other'}"`; }
  async click() { return 'clicked'; }
  async isVisible() { return true; }
}
function makeTest(fixtures) {
  const test = () => {};
  test.fixtures = fixtures;
  test.describe = () => {};
  test.extend = more => makeTest({ ...fixtures, ...more });
  return test;
}
const test = makeTest(undefined);
module.exports = Object.assign(test, { test, expect: () => {}, defineConfig: config => config, Locator });
JS
cat > "$work/probe/run.js" <<'JS'
const assert = require('assert');
const fs = require('fs');
const pw = require('@playwright/test');
if (!process.env.LOCATOR_PROBE_TARGETS) {
  assert.strictEqual(pw.test.fixtures, undefined, 'without targets the module must be unchanged');
  process.exit(0);
}
assert.ok(pw.test.fixtures && pw.test.fixtures.page, 'test has no page fixture');
assert.ok(typeof pw === 'function' && pw.test === pw, 'the module must stay the test function');
assert.ok(typeof pw.expect === 'function' && typeof pw.defineConfig === 'function', 'the other exports must stay');
assert.strictEqual(require('@playwright/test'), pw, 'one copy per module');
const page = { locator: selector => new pw.Locator(selector) };
(async () => {
  await pw.test.fixtures.page({ page }, async () => {}, { titlePath: ['x.spec.ts', 'cancels'], file: '/x.spec.ts' });
  const target = new pw.Locator("getByRole('button', { name: 'Cancel' })");
  assert.strictEqual(await target.click(), 'clicked');
  await target.click();
  await new pw.Locator("getByRole('link', { name: 'Home' })").click();
  await new pw.Locator("locator('form').getByRole('button', { name: 'Cancel' })").isVisible();
  const records = fs.readFileSync(process.env.LOCATOR_PROBE_OUT, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.deepStrictEqual(records.map(r => [r.target, r.test, r.snapshot]),
                         [["getByRole('button', { name: 'Cancel' })", 'cancels', '- button "Cancel"']]);
  console.log('probe ok');
})().catch(error => { console.error(error); process.exit(1); });
JS
printf '%s\n' "[\"getByRole('button', { name: 'Cancel' })\"]" > "$work/probe/targets.json"
probe_preload="$root/scripts/locator-probe/playwright.cjs"
if command -v cygpath > /dev/null 2>&1; then  # Git Bash doesn't convert paths inside NODE_OPTIONS for Windows node
  probe_preload="$(cygpath -m "$probe_preload")"
fi
if command -v node > /dev/null 2>&1; then
  set +e
  (cd "$work/probe" && node --check "$probe_preload" && NODE_OPTIONS="--require $probe_preload" node run.js \
    && NODE_OPTIONS="--require $probe_preload" LOCATOR_PROBE_TARGETS=targets.json LOCATOR_PROBE_OUT=out.jsonl \
    node run.js) > "$work/probe.log" 2>&1
  code=$?
  set -e
  if [ "$code" -eq 0 ] && grep -qx "probe ok" "$work/probe.log"; then
    ok "locator-probe-hooks-the-test-fixture"
  else
    bad "locator-probe-hooks-the-test-fixture" "$(cat "$work/probe.log")"
  fi
else
  echo "  skip  locator-probe-hooks-the-test-fixture (node is not installed)"
fi

echo
echo "platform checkout (the workflows' sparse checkout of the platform; tests/platform-checkout/check.py)"
platform_work="$work/platform-checkout"
platform_check() {  # platform_check <check>: ok if tests/platform-checkout/check.py <check> passes
  if python3 "$root/tests/platform-checkout/check.py" "$1" "$root" "$platform_work" > "$work/platform.log" 2>&1; then
    ok "platform-checkout-$1"
  else
    bad "platform-checkout-$1" "$(cat "$work/platform.log")"
  fi
}
platform_check sparse  # a list in every checkout, no cone mode, none of evals/ tests/ BACKLOG.md README.md .github/
platform_check covers  # every platform path a job's steps, scripts and agents read is in that job's checkout
platform_check eval    # the triage eval's workspace has the same platform parts as the agent jobs' checkout
# The scripts, run from the checkout the agent jobs get, as the workflows run them, must find what they read there.
if sparse="$(python3 "$root/tests/platform-checkout/check.py" checkout "$root" "$platform_work" 2> "$work/platform.log")"; then
  failed_stages=""
  for config in "$sparse"/frameworks/*.json; do
    framework="$(basename "$config" .json)"
    for engine in claude opencode; do
      dir="$work/sparse-$framework-$engine"
      mkdir -p "$dir"
      git -C "$dir" init -q
      if ! (cd "$dir" && ENGINE="$engine" FRAMEWORK="$framework" PLATFORM_DIR="$sparse" SKIP_MCP_WARMUP=1 \
            bash "$sparse/scripts/stage-agents.sh") >> "$work/platform-stage.log" 2>&1; then
        failed_stages+=" $framework/$engine"
      fi
    done
  done
  if [ -z "$failed_stages" ]; then
    ok "platform-checkout-stages-every-framework"
  else
    bad "platform-checkout-stages-every-framework" "failed:$failed_stages"$'\n'"$(cat "$work/platform-stage.log")"
  fi
  # run-agent.sh hands Claude Code AGENT-RULES.md and the settings file from the checkout: both must be there.
  rm -f "$work/args.txt"
  set +e
  (cd "$work/sparse-playwright-claude" && env PATH="$bin:$PATH" STUB_ARGS="$work/args.txt" PLATFORM_DIR="$sparse" \
    ENGINE=claude AGENT=triage PROMPT="Do the task." EXPECTED_OUTPUT=results/triage.json \
    bash "$sparse/scripts/run-agent.sh") > "$work/platform-run.log" 2>&1
  code=$?
  set -e
  missing=""
  if [ -f "$work/args.txt" ]; then
    mapfile -t agent_args < "$work/args.txt"
    for i in "${!agent_args[@]}"; do
      case "${agent_args[$i]}" in
        --append-system-prompt-file|--settings)
          [ -f "${agent_args[$((i + 1))]:-}" ] || missing+=" ${agent_args[$((i + 1))]:-}" ;;
      esac
    done
  else
    missing=" (claude never ran)"
  fi
  if [ "$code" -eq 0 ] && [ -z "$missing" ]; then
    ok "platform-checkout-runs-an-agent"
  else
    bad "platform-checkout-runs-an-agent" "exit $code; missing:$missing"$'\n'"$(cat "$work/platform-run.log")"
  fi
  # locator-check.sh hands the verification run the probe from the checkout.
  locator_case sparse playwright tests/e2e/delete.spec.ts PLATFORM_DIR="$sparse"
  if [ "$code" -eq 0 ] && grep -E '^probe=.+playwright\.cjs$' "$work/locator-sparse/outputs" \
      | grep -qF "$(basename "$sparse")"; then
    ok "platform-checkout-has-the-locator-probe"
  else
    bad "platform-checkout-has-the-locator-probe" "exit $code"$'\n'"$(cat "$work/locator-sparse/outputs" "$work/locator-sparse/log" 2> /dev/null)"
  fi
  guard_case() {  # guard_case <name> <exit> <checkout> <+present|-absent>...: check-platform-checkout.sh on it
    local name="$1" want="$2" checkout="$3" problems="" item got
    shift 3
    set +e
    PLATFORM_DIR="$checkout" bash "$sparse/scripts/check-platform-checkout.sh" > "$work/guard.log" 2>&1
    got=$?
    set -e
    for item in "$@"; do
      if grep -qF -- "${item:1}" "$work/guard.log"; then
        [ "${item:0:1}" = + ] || problems+="unexpected: ${item:1}"$'\n'
      else
        [ "${item:0:1}" = - ] || problems+="missing: ${item:1}"$'\n'
      fi
    done
    if [ "$got" -eq "$want" ] && [ -z "$problems" ]; then
      ok "$name"
    else
      bad "$name" "exit $got (want $want)"$'\n'"$problems$(cat "$work/guard.log")"
    fi
  }
  guard_case check-platform-checkout-passes-the-sparse-checkout 0 "$sparse" \
    "+none of evals, tests and BACKLOG.md is in" "-::error::"
  guard_case check-platform-checkout-fails-a-full-checkout 1 "$root" "+/evals is in the platform checkout" \
    "+/tests is in the platform checkout" "+/BACKLOG.md is in the platform checkout"
  mkdir -p "$work/backlog-only"
  printf '# Backlog\n' > "$work/backlog-only/BACKLOG.md"
  guard_case check-platform-checkout-names-what-it-finds 1 "$work/backlog-only" \
    "+/BACKLOG.md is in the platform checkout, where an agent could read it." "-/evals is" "-/tests is"
  guard_case check-platform-checkout-without-a-checkout 2 "$work/no-checkout" "+not found"
else
  bad "platform-checkout-builds" "$(cat "$work/platform.log")"
fi

echo
echo "report-defects.sh"
fixtures="$root/tests/report-defects"
defects="$work/defects"
transcript="$work/gh/transcript"
cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Test stub for gh: log the call, then answer as gh would. GH_* variables choose the scenario.
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list")
    if [[ " $* " == *" --search "* ]]; then
      if [ "${GH_FAIL_SEARCH:-0}" = 1 ]; then echo "HTTP 502: Server Error" >&2; exit 1; fi
      printf '%s' "${GH_SEARCH_HIT:-}"
    else
      printf '%s' "${GH_BODY_HIT:-}"
    fi
    ;;
  "label list") printf '%s\n' "${GH_LABELS:-bug}" ;;
  "label create") ;;
  "issue create")
    prev=""
    for arg in "$@"; do
      if [ "$prev" = --body-file ]; then cat "$arg" >> "$GH_BODIES"; fi
      prev="$arg"
    done
    if [ "${GH_FAIL_CREATE:-0}" = 1 ]; then echo "GraphQL: Resource not accessible by integration (createIssue)" >&2; exit 1; fi
    if [ "${GH_FAIL_ASSIGNEE:-0}" = 1 ] && [[ " $* " == *" --assignee "* ]]; then
      echo "could not assign user: 'qa-lead' not found" >&2
      exit 1
    fi
    issue=$(( $(cat "$GH_COUNTER" 2> /dev/null || echo 100) + 1 ))
    echo "$issue" > "$GH_COUNTER"
    echo "https://github.com/acme/shop/issues/$issue"
    ;;
  "issue comment") echo "https://github.com/acme/shop/issues/$3#issuecomment-1" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/gh"
defects_prepare() {  # defects_prepare <failures.json>: "report-defects.sh prepare" on tests/report-defects/triage.json
  rm -rf "$defects"
  mkdir -p "$defects/results"
  cp "$fixtures/triage.json" "$defects/results/triage.json"
  cp "$1" "$defects/results/failures.json"
  set +e
  (cd "$defects" && env COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 RUN_URL=https://github.com/acme/shop/actions/runs/42 \
    APP_URL=https://staging.example.com FRAMEWORK=playwright ENGINE=opencode OPENCODE_MODEL=deepseek/deepseek-flash \
    bash "$root/scripts/report-defects.sh" prepare > "$work/defects.log" 2>&1)
  code=$?
  set -e
}
fingerprints() {  # fingerprints: the candidates' fingerprints, one per line
  python3 - "$defects/results/defect-candidates.json" <<'PY'
import json
import sys

for candidate in json.load(open(sys.argv[1], encoding="utf-8"))["candidates"]:
    print(candidate["fingerprint"])
PY
}
defects_setup() {  # defects_setup: the expected candidates and the sample reports in a fresh scratch project
  rm -rf "$defects" "$work/gh"
  mkdir -p "$defects/results" "$work/gh"
  cp "$fixtures/defect-candidates.expected.json" "$defects/results/defect-candidates.json"
  cp -R "$fixtures/defects" "$defects/results/defects"
  touch "$work/gh/log" "$work/gh/bodies" "$work/gh/summary.md"
}
defects_publish() {  # defects_publish [VAR=value]...: "report-defects.sh publish" with the stub gh; sets $code, $transcript
  set +e
  (cd "$defects" && env PATH="$bin:$PATH" GH_LOG="$work/gh/log" GH_BODIES="$work/gh/bodies" GH_COUNTER="$work/gh/counter" \
    GITHUB_STEP_SUMMARY="$work/gh/summary.md" COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
    RUN_URL=https://github.com/acme/shop/actions/runs/42 DEFECT_LABELS="bug, agentic-qa" DEFECT_ASSIGNEES=qa-lead "$@" \
    bash "$root/scripts/report-defects.sh" publish > "$work/gh/output" 2>&1)
  code=$?
  set -e
  local part
  for part in "$work/gh/log" "$work/gh/output" "$work/gh/summary.md" "$defects/results/defects-report.json" "$work/gh/bodies"; do
    printf '== %s\n' "${part##*/}"
    cat "$part" 2> /dev/null || true
  done > "$transcript"
}

defects_prepare "$fixtures/failures.json"
if [ "$code" -eq 0 ] && python3 - "$defects/results/defect-candidates.json" "$fixtures/defect-candidates.expected.json" <<'PY'
import json
import sys

actual, expected = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3])
sys.exit(0 if actual == expected else 1)
PY
then
  ok "candidates"
else
  bad "candidates" "exit $code; differs from defect-candidates.expected.json:"$'\n'"$(cat "$work/defects.log" "$defects/results/defect-candidates.json" 2> /dev/null)"
fi
first_run="$(fingerprints)"
fp_checkout="$(sed -n 1p <<< "$first_run")"
fp_login="$(sed -n 2p <<< "$first_run")"
# The documented definition: sha1 of "<test file>\n<test name>\n<first error line>", numbers and hex ids removed.
want="$(printf '%s\n%s\n%s' tests/login.spec.ts 'rejects a wrong password' \
  "Error: expect(locator).toBeVisible() failed for getByRole('alert') after retries (session )" | sha1sum | cut -c1-40)"
if [ "$fp_login" = "$want" ]; then ok "fingerprint-definition"; else bad "fingerprint-definition" "got $fp_login, want $want"; fi
defects_prepare "$fixtures/failures-rerun.json"
if [ "$code" -eq 0 ] && [ "$(fingerprints)" = "$first_run" ]; then
  ok "fingerprint-stable-across-runs"
else
  bad "fingerprint-stable-across-runs" "other timings, ids and line numbers changed the fingerprints:"$'\n'"$first_run"$'\n'"$(fingerprints 2>&1)"
fi
sed 's/toHaveText/toContainText/' "$fixtures/failures.json" > "$work/failures-changed.json"
defects_prepare "$work/failures-changed.json"
changed="$(fingerprints)"
if [ "$code" -eq 0 ] && [ "$(sed -n 1p <<< "$changed")" != "$fp_checkout" ] && [ "$(sed -n 2p <<< "$changed")" = "$fp_login" ]; then
  ok "fingerprint-follows-the-error"
else
  bad "fingerprint-follows-the-error" "a different assertion must change that failure's fingerprint, and only that one:"$'\n'"$changed"
fi

defects_setup
defects_publish
check_texts new-issues "$transcript" \
  "+issue create --title [Agentic QA] Order total ignores the second item (Checkout " \
  "+issue create --title [Agentic QA] Wrong password shows no error (rejects a wrong password)" \
  "+--label bug,agentic-qa --assignee qa-lead" "+label create agentic-qa" "-label create bug" \
  "+| opened | [#101](https://github.com/acme/shop/issues/101) |" "+\"number\": 102" \
  "+<!-- agentic-qa-defect: $fp_checkout -->" "+<!-- agentic-qa-defect: $fp_login -->" \
  "-0000000000000000000000000000000000000000" "+Spotted by @"$'\xe2\x80\x8b'"qa-team" "+\`@smoke\`"
defects_setup
defects_publish GH_SEARCH_HIT="42 https://github.com/acme/shop/issues/42"
check_texts existing-issue-gets-a-comment "$transcript" \
  "+issue comment 42 --body Still failing on 0123456789abcdef0123456789abcdef01234567" \
  "+https://github.com/acme/shop/actions/runs/42" "-issue create" "+| still failing: commented |" "+\"updated\": ["
defects_setup
defects_publish GH_BODY_HIT="43 https://github.com/acme/shop/issues/43"
check_texts found-in-bodies-when-search-lags "$transcript" "+issue comment 43 --body Still failing on" "-issue create"
defects_setup
defects_publish GH_FAIL_CREATE=1
check_texts gh-failure-is-reported "$transcript" \
  "+could not open the issue: GraphQL: Resource not accessible by integration" "+| **failed**: could not open" \
  "+\"failed\": [" "+::warning::report-defects:"
defects_setup
defects_publish GH_FAIL_SEARCH=1
check_texts search-failure-opens-nothing "$transcript" "+could not look for an open issue" "-issue create" "-issue comment"
defects_setup
defects_publish GH_FAIL_ASSIGNEE=1
check_texts rejected-assignee-is-dropped "$transcript" "+opened (not assigned: could not assign user" \
  "+\"note\": \"not assigned:" "+\"number\": 101"
defects_setup
rm "$defects/results/defects/rejects-a-wrong-password-"*.md
printf '# [Agentic QA] Not a candidate\n' > "$defects/results/defects/rogue.md"
defects_publish
check_texts missing-and-stray-reports "$transcript" "+**no report**" "+rogue.md" "-Not a candidate" "+\"missing\": ["

echo
echo "load-app-env.sh"
github_env="$work/github_env"
app_env_out="$work/app-env.out"
load_env() {  # load_env [VAR=value]... -- [ARG]...: run load-app-env.sh ARGs in a clean environment; sets $code
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  rm -f "$github_env"
  set +e
  env -u APP_ENV GITHUB_ACTIONS=true GITHUB_ENV="$github_env" "${vars[@]}" bash "$root/scripts/load-app-env.sh" "$@" \
    > "$app_env_out" 2>&1
  code=$?
  set -e
}
env_check() {  # env_check <name> <exit> <GITHUB_ENV content, or none> <+present|-absent>...: about the last load_env
  local name="$1" want="$2" expected="$3" problems="" item
  shift 3
  [ "$code" -eq "$want" ] || problems+="exit $code, want $want"$'\n'
  if [ "$expected" = none ]; then
    [ ! -e "$github_env" ] || problems+="GITHUB_ENV was written"$'\n'
  elif [ "$(cat "$github_env" 2> /dev/null)" != "$expected" ]; then
    problems+="GITHUB_ENV holds:"$'\n'"$(cat "$github_env" 2> /dev/null)"$'\n'
  fi
  for item in "$@"; do
    if grep -qF -- "${item:1}" "$app_env_out"; then
      [ "${item:0:1}" = + ] || problems+="printed: ${item:1}"$'\n'
    else
      [ "${item:0:1}" = - ] || problems+="missing: ${item:1}"$'\n'
    fi
  done
  if [ -z "$problems" ]; then ok "$name"; else bad "$name" "$problems$(cat "$app_env_out")"; fi
}
for fixture in "$root"/tests/load-app-env/*.env; do
  name="$(basename "$fixture" .env)"
  expect="$(sed -n 's/^# expect: //p' "$fixture")"
  load_env APP_ENV="$(cat "$fixture")" --
  problems=""
  # No value, and no malformed line, may be printed anywhere but in an ::add-mask:: line.
  while IFS= read -r secret; do
    if [ -n "$secret" ] && grep -vF '::add-mask::' "$app_env_out" | grep -qF -- "$secret"; then
      problems+="printed: $secret"$'\n'
    fi
  done < <(grep -v '^[[:space:]]*#' "$fixture" | sed -e 's/^[[:space:]]*//' -e 's/^[^=]*=//')
  if [ "$expect" = ok ]; then
    [ "$code" -eq 0 ] || problems+="exit $code, want 0"$'\n'
    cmp -s "$github_env" "${fixture%.env}.expected" \
      || problems+="GITHUB_ENV differs from $name.expected:"$'\n'"$(cat "$github_env" 2> /dev/null)"$'\n'
    while IFS= read -r value; do
      if [ -n "$value" ] && ! grep -qxF "::add-mask::$value" "$app_env_out"; then problems+="not masked: $value"$'\n'; fi
    done < <(sed 's/^[^=]*=//' "${fixture%.env}.expected")
  else
    [ "$code" -eq 1 ] || problems+="exit $code, want 1"$'\n'
    [ ! -e "$github_env" ] || problems+="GITHUB_ENV was written although the input was rejected"$'\n'
    if grep -q '::add-mask::' "$app_env_out"; then problems+="masked values of a rejected input"$'\n'; fi
    read -r -a line_numbers <<< "${expect#error on line }"
    for line_number in "${line_numbers[@]}"; do
      grep -q "APP_ENV line $line_number " "$app_env_out" || problems+="no error for line $line_number"$'\n'
    done
  fi
  if [ -z "$problems" ]; then ok "$name"; else bad "$name" "$problems$(cat "$app_env_out")"; fi
done
load_env APP_ENV="$(cat "$root/tests/load-app-env/valid.env")" GITHUB_ACTIONS= --
env_check no-masks-outside-github-actions 0 "$(cat "$root/tests/load-app-env/valid.expected")" "-::add-mask::" \
  "-sk-or-v1-fixture-7f3e9a1c4b2d"
load_env APP_ENV=$'CRLF_SECRET=fixture-crlf-value-5e6f7a\r\nEMPTY_ONE=\r\n' --
env_check crlf-and-empty-value 0 $'CRLF_SECRET=fixture-crlf-value-5e6f7a\nEMPTY_ONE=' \
  "+::add-mask::fixture-crlf-value-5e6f7a" "+APP_ENV line 2 sets EMPTY_ONE to an empty value"
load_env APP_ENV='PCT_SECRET=fixture%25pct%0Avalue' --
env_check percent-escaped-in-mask 0 'PCT_SECRET=fixture%25pct%0Avalue' "+::add-mask::fixture%2525pct%250Avalue"
load_env APP_ENV='APP_TOKEN=fixture-exec-token=x' GITHUB_ACTIONS= -- -- printenv APP_TOKEN
env_check command-gets-the-values 0 none "+fixture-exec-token=x"
load_env APP_ENV='APP_TOKEN=fixture-exec-token=x' -- -- printenv APP_ENV
env_check command-does-not-get-app-env 1 none "+::add-mask::fixture-exec-token=x" "-APP_TOKEN"
load_env --
env_check empty-app-env-loads-nothing 0 none "-load-app-env" "-::"
load_env APP_ENV="$(cat "$root/tests/load-app-env/valid.env")" -- --check
env_check check-masks-without-loading 0 none "+::add-mask::sk-or-v1-fixture-7f3e9a1c4b2d" "+APP_ENV is valid"
load_env APP_ENV='not a valid line' -- --check
env_check check-rejects-malformed-input 1 none "+APP_ENV line 1 " "-not a valid line"
load_env -- --bogus
env_check usage-error 2 none "+usage:"
# The workflows themselves: no job-wide APP_ENV, no agent step with it, no $GITHUB_ENV loading in a job with agents.
if python3 - "$root/.github/workflows" > "$work/app-env-guard.log" 2>&1 <<'PY'
import pathlib
import re
import sys

problems = []
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.yml")):
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("#")]
    text = "\n".join(lines) + "\n"
    if "\njobs:\n" not in text:
        continue
    for job in re.split(r"(?m)^  (?=[\w-]+:\s*$)", text.split("\njobs:\n", 1)[1])[1:]:
        name = job.split(":", 1)[0]
        head, _, steps = job.partition("\n    steps:\n")
        if "secrets.APP_ENV" in head:
            problems.append(f"{path.name} {name}: APP_ENV is set for the whole job")
        agents = "run-agent.sh" in steps
        for step in re.split(r"(?m)^      - ", steps)[1:]:
            if "secrets.APP_ENV" not in step:
                continue
            title = step.splitlines()[0]
            if "run-agent.sh" in step:
                problems.append(f"{path.name} {name}: the agent step '{title}' gets APP_ENV")
            elif agents and not re.search(r'load-app-env\.sh"? (--check|--)( |$)', step, re.M):
                problems.append(f"{path.name} {name}: '{title}' loads APP_ENV into GITHUB_ENV in a job with agents")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
then
  ok "agents-never-get-app-env"
else
  bad "agents-never-get-app-env" "$(cat "$work/app-env-guard.log")"
fi

echo
echo "evals/triage/run-eval.py"
set +e
(cd "$root" && python3 evals/triage/run-eval.py --check > "$work/eval-check.log" 2>&1)
code=$?
set -e
# Hide mode deletes all of evals/; and this file too, as the stub cases below reuse three real test names with their
# labels.
check_texts eval-cases-are-valid "$work/eval-check.log" "+cases OK" "-warning" \
  "+no file that goes into a workspace gives an answer away" "+  evals/  (the eval: its cases, result files" \
  "+  tests/run-tests.sh  (T01: its test name near a label" "+  .git/  (" "-  evals/triage/"
printf '%s\n' '{"id": "x", "file": "tests/x.spec.ts", "name": "n", "error": "e", "expected": "BUG", "why": "w"}' \
  > "$work/eval-bad.jsonl"
set +e
(cd "$root" && python3 evals/triage/run-eval.py --check --cases "$work/eval-bad.jsonl" > "$work/eval-bad.log" 2>&1)
code=$?
set -e
if [ "$code" -eq 1 ] && grep -qF "expected must be one of" "$work/eval-bad.log"; then
  ok "eval-rejects-a-bad-label"
else
  bad "eval-rejects-a-bad-label" "exit $code"$'\n'"$(cat "$work/eval-bad.log")"
fi
# No file that goes into every workspace may give an answer away: here a case's "why" is a line of AGENT-RULES.md.
python3 - "$root/AGENT-RULES.md" > "$work/eval-leaky.jsonl" <<'PY'
import json
import sys

why = next(line.strip() for line in open(sys.argv[1], encoding="utf-8")
           if len(line.strip()) > 40 and not line.startswith("#"))
print(json.dumps({"id": "leaky", "file": "tests/e2e-browser/app.spec.ts", "name": "home page loads",
                  "error": "page.goto: net::ERR_CONNECTION_REFUSED", "expected": "ENV", "why": why}))
PY
set +e
(cd "$root" && python3 evals/triage/run-eval.py --check --cases "$work/eval-leaky.jsonl" > "$work/eval-leaky.log" 2>&1)
code=$?
set -e
if [ "$code" -eq 1 ] && grep -qF "AGENT-RULES.md gives away leaky's answer (its why)" "$work/eval-leaky.log"; then
  ok "eval-refuses-a-leaky-workspace"
else
  bad "eval-refuses-a-leaky-workspace" "exit $code"$'\n'"$(cat "$work/eval-leaky.log")"
fi
# End to end with a stub engine that calls every failure SELECTOR_DRIFT: 3 cases x 2 runs. CI is unset, so the answer
# key stays; hide mode, which would delete parts of this checkout, is tested on a scratch clone further down.
eval_bin="$work/eval-bin"
mkdir -p "$eval_bin"
cat > "$eval_bin/claude" <<'STUB'
#!/usr/bin/env bash
# Stub engine for the triage eval, as claude and as opencode: records its arguments and calls every failure
# SELECTOR_DRIFT. In the workspace whose failure is the test $EVAL_STUB_PEEK_ON, it first runs cat $EVAL_STUB_PEEK,
# as an agent hunting for the answer key would. For the test $EVAL_STUB_CRASH_ON it fails at startup instead, as
# opencode did when parallel first runs raced to create its database. It also records when its run (the folder
# trials/<case>-r<n> around the workspace) starts and ends, its data and temp folders, and whether a second run
# could read the first run's log.
if [ "${1:-}" = --version ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
printf '%s\n' "$@" >> "$EVAL_STUB_ARGS"
run="$(basename "$(dirname "$PWD")")"
echo "start $run" >> "$EVAL_STUB_ARGS"
trap 'echo "end $run" >> "$EVAL_STUB_ARGS"' EXIT
echo "folders data=${XDG_DATA_HOME//\\//} tmp=${TMPDIR//\\//}" >> "$EVAL_STUB_ARGS"
case "$run" in
  *-r1) ;;
  *) if cat "../../${run%-r*}-r1/agent.log" > /dev/null 2>&1; then echo "$run read ${run%-r*}-r1" >> "$EVAL_STUB_ARGS"; fi ;;
esac
for result in ../../*/result.json; do  # a run's record holds its expected label: never on disk while agents run
  if [ -e "$result" ]; then echo "$run found a result on disk: $result" >> "$EVAL_STUB_ARGS"; fi
done
if [ -n "${EVAL_STUB_CRASH_ON:-}" ] && grep -qF "$EVAL_STUB_CRASH_ON" results/failures.json; then
  printf '\033[91m\033[1mError: \033[0mUnexpected error\n\ndatabase is locked\n'
  exit 1
fi
if [ -n "${EVAL_STUB_PEEK:-}" ] && grep -qF "$EVAL_STUB_PEEK_ON" results/failures.json; then
  cat "$EVAL_STUB_PEEK"
fi
python3 - "$EXPECTED_OUTPUT" <<'PY'
import json
import sys

failures = json.load(open("results/failures.json", encoding="utf-8"))
items = [{"name": f["name"], "classname": f["classname"], "file": f["file"], "classification": "SELECTOR_DRIFT",
          "reason": "stub verdict"} for f in failures]
json.dump({"framework": "playwright", "items": items}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STUB
chmod +x "$eval_bin/claude"
cp "$eval_bin/claude" "$eval_bin/opencode"
cat > "$work/eval-cases.jsonl" <<'JSONL'
{"id": "drift", "file": "tests/e2e-browser/login.spec.ts", "name": "logs in with valid credentials", "error": "locator.click: Timeout 10000ms exceeded. waiting for getByTestId('login-btn').", "expected": "SELECTOR_DRIFT", "why": "never-shown-to-the-agent"}
{"id": "bug", "file": "tests/e2e-browser/checkout.spec.ts", "name": "shows correct total", "error": "expect(received).toBe(expected) Expected: \"$30.00\" Received: \"$300.00\".", "expected": "REAL_BUG", "why": "never-shown-to-the-agent"}
{"id": "env", "file": "tests/e2e-browser/app.spec.ts", "name": "home page loads", "error": "page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:8501/", "expected": "ENV", "why": "never-shown-to-the-agent"}
JSONL
set +e
(cd "$root" && env -u CI PATH="$eval_bin:$PATH" EVAL_STUB_ARGS="$work/eval-args.txt" SKIP_MCP_WARMUP=1 \
  GITHUB_STEP_SUMMARY="$work/eval-summary.md" python3 evals/triage/run-eval.py --engine claude \
  --cases "$work/eval-cases.jsonl" --repeats 2 --jobs 4 --out "$work/eval-results" --work-dir "$work/eval-run" --keep \
  > "$work/eval.log" 2>&1)
code=$?
set -e
{ cat "$work/eval-summary.md" "$work"/eval-results/*.json "$work/eval-args.txt" "$work/eval.log"; } \
  > "$work/eval-transcript" 2> /dev/null || true
check_texts eval-run-with-stub-engine "$work/eval-transcript" \
  "+**Accuracy** 2/6 (33%)" "+**Critical: REAL_BUG classified as SELECTOR_DRIFT** 2" "+**Invalid runs** 0" \
  "+3/3 cases gave the same answer in all 2 runs" "+| REAL_BUG | 2 | 0 | 0 | 0 | 0 |" \
  "+| SELECTOR_DRIFT | 2/2 (100%) |" "+| bug | shows correct total | REAL_BUG | SELECTOR_DRIFT " "+stub verdict" \
  "-| drift |" "-### Invalid runs" "+\"engine_version\": \"9.9.9 (Claude Code)\"" "+\"model\": \"default\"" \
  "+\"blob\": \"$(git -C "$root" hash-object agents/common/triage.md)\"" "+\"deleted_before_agents\": []" \
  "+Triage every failure in results/failures.json" "+App URL: not provided." "+--max-turns" "+stream-json" \
  "+--no-session-persistence" "+drift run 1: expected SELECTOR_DRIFT, got SELECTOR_DRIFT" "+\"snapshots\": true" \
  "+error-context.md on"
# The answer must never reach the agent: no workspace may contain a case's "why".
kept="$(find "$work/eval-run/trials" -mindepth 2 -maxdepth 2 -type d -name workspace | wc -l)"
if [ "$kept" -eq 6 ] && ! grep -rqF "never-shown-to-the-agent" "$work"/eval-run/trials/*/workspace; then
  ok "eval-workspaces-hide-the-answer"
else
  bad "eval-workspaces-hide-the-answer" "$kept workspaces kept; the why text is in:"$'\n'"$(grep -rlF never-shown-to-the-agent "$work"/eval-run/trials/*/workspace | head -n 3)"
fi
# Each run has its own folder, its log and result outside the workspace. A case's two runs never overlap, though
# --jobs 4 leaves room for them to, and when run 2 starts, run 1's folder is locked (on Windows a folder's mode doesn't
# stop reads, so that part is skipped). After the eval every folder is readable again.
set +e
python3 - "$work/eval-args.txt" "$work/eval-run/trials" > "$work/eval-isolation.log" 2>&1 <<'PY'
import sys
from pathlib import Path

order = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.startswith(("start ", "end "))]
problems = []
for case in ("drift", "bug", "env"):
    try:
        if order.index(f"end {case}-r1") > order.index(f"start {case}-r2"):
            problems.append(f"{case}: run 2 started before run 1 ended")
    except ValueError as exc:
        problems.append(f"{case}: {exc}")
for run in sorted(f"{case}-r{n}" for case in ("drift", "bug", "env") for n in (1, 2)):
    folder = Path(sys.argv[2]) / run
    missing = [name for name in ("agent.log", "result.json", "workspace") if not (folder / name).exists()]
    if missing:
        problems.append(f"{run}: no {', '.join(missing)} in its folder after the eval")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
code=$?
set -e
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ;;
  *) if grep -q -- "-r2 read " "$work/eval-args.txt"; then code=1; grep -- "-r2 read " "$work/eval-args.txt" >> "$work/eval-isolation.log"; fi ;;
esac
if grep -q "found a result on disk" "$work/eval-args.txt"; then
  code=1
  grep "found a result on disk" "$work/eval-args.txt" >> "$work/eval-isolation.log"
fi
if [ "$code" -eq 0 ]; then ok "eval-runs-are-isolated"; else bad "eval-runs-are-isolated" "$(cat "$work/eval-isolation.log")"; fi
# OpenCode's transcript, its JSON event stream, goes to the log too, and each run gets its own data folder (sessions,
# snapshots) and temp folder. In drift the stub agent reads a copy of the answer key under another name: that run is
# invalid because the log quotes a case's "why". In bug the stub fails at startup: the report must say how.
cp "$work/eval-cases.jsonl" "$work/key-copy.txt"
set +e
(cd "$root" && env -u CI PATH="$eval_bin:$PATH" EVAL_STUB_ARGS="$work/eval-oc-args.txt" \
  EVAL_STUB_PEEK="$work/key-copy.txt" EVAL_STUB_PEEK_ON="logs in with valid credentials" \
  EVAL_STUB_CRASH_ON="shows correct total" SKIP_MCP_WARMUP=1 GITHUB_STEP_SUMMARY="$work/eval-oc-summary.md" \
  python3 evals/triage/run-eval.py --engine opencode --cases "$work/eval-cases.jsonl" --only drift,bug --jobs 2 \
  --out "$work/eval-oc-results" --work-dir "$work/eval-oc-run" > "$work/eval-oc.log" 2>&1)
code=$?
set -e
{ cat "$work/eval-oc-summary.md" "$work/eval-oc-args.txt" "$work/eval-oc.log"; } > "$work/eval-oc-transcript" \
  2> /dev/null || true
check_texts eval-opencode-transcript "$work/eval-oc-transcript" "+deepseek/deepseek-flash" "+--format" \
  "-stream-json" "+/trials/drift-r1/engine-data tmp=" "+/trials/bug-r1/engine-data tmp=" "+/trials/drift-r1/tmp" \
  "+**Accuracy** 0/1 (0%)" "+**Invalid runs** 1 (not scored)" \
  "+the log quotes the answer key (the why of drift, bug and env)" \
  "+| bug | shows correct total | REAL_BUG | none | no triage.json: opencode failed before the agent took a step (exit code 1): Unexpected error: database is locked |"
# When the agent writes no triage.json, the report must say why. The texts are from real runs: opencode failing at
# startup as parallel first runs raced to create its database, opencode's turn limit, a rejected permission.
mkdir -p "$work/missing"
set +e
python3 - "$root/evals/triage/run-eval.py" "$work/missing" > "$work/eval-missing.log" 2>&1 <<'PY'
import importlib.util
import json
import sys
import types
from pathlib import Path

spec = importlib.util.spec_from_file_location("run_eval", sys.argv[1])
run_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_eval)
step = {"expected_output": "results/triage.json", "max_turns": 15}
opencode = types.SimpleNamespace(engine="opencode", timeout=1200)
claude = types.SimpleNamespace(engine="claude", timeout=1200)
started = json.dumps({"type": "step_start", "part": {}})


def done(code, engine="opencode"):
    return f"::error::The triage agent did not write results/triage.json ({engine} exit code {code})."


samples = [
    ("locked", opencode, 1, f"\x1b[91m\x1b[1mError: \x1b[0mUnexpected error\n\ndatabase is locked\n{done(1)}"),
    ("migration", opencode, 1, "Error: Unexpected error\n\nFailed query: \n  CREATE TABLE `workspace` (\n"
                               f"    `id` text PRIMARY KEY,\n{done(1)}"),
    ("turns", opencode, 1, f"{started}\n::warning::opencode reached the 450s limit that stands in for MAX_TURNS=15.\n"
                           f"{done(124)}"),
    ("claude-turns", claude, 1, json.dumps({"type": "assistant", "message": {"content": []}}) + "\n"
     + json.dumps({"type": "result", "subtype": "error_max_turns", "is_error": True}) + "\n" + done(1, "claude")),
    ("timeout", opencode, 124, f"{started}\n\n[stopped after 1200s]\n"),
    ("rejected", opencode, 1, f"{started}\n! permission requested: external_directory (/elsewhere/results/*); "
                              f"auto-rejecting\n{done(0)}"),
    ("tried", claude, 1, json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Write", "input": {"file_path": "/tmp/triage.json"}}]}}) + "\n" + done(0, "claude")),
    ("last-words", opencode, 1, started + "\n" + json.dumps({"type": "text", "part": {"text": "No idea."}}) + "\n"
     + done(0)),
]
ws = Path(sys.argv[2])
for name, opts, code, out in samples:
    print(f"{name}: {run_eval.missing_output(out, code, ws, step, opts)}")
(ws / "triage.json").write_text("{}", encoding="utf-8")
print(f"wrong-place: {run_eval.missing_output(started + chr(10) + done(0), 1, ws, step, opencode)}")
PY
code=$?
set -e
check_texts eval-explains-missing-output "$work/eval-missing.log" \
  "+locked: opencode failed before the agent took a step (exit code 1): Unexpected error: database is locked" \
  "+migration: opencode failed before the agent took a step (exit code 1): Unexpected error: Failed query: CREATE TABLE" \
  "+turns: hit the turn limit: opencode reached the 450s limit that stands in for MAX_TURNS=15" \
  "+claude-turns: hit the turn limit (15 turns)" "+timeout: the eval stopped the run after 1200s (--timeout)" \
  "+rejected: opencode stopped when it auto-rejected a permission request: external_directory (/elsewhere/results/*)" \
  "+tried: tried to write /tmp/triage.json instead of results/triage.json" \
  "+last-words: the agent stopped without writing it (opencode exit code 0); its last message: \"No idea.\"" \
  "+wrong-place: wrote triage.json instead of results/triage.json"
# A multi-line error is the reporter's own text (the real Kestrel cases, the boundary cases) and must reach the JUnit
# report unchanged; a one-line error is completed the way Playwright prints it.
set +e
python3 - "$root/evals/triage/run-eval.py" > "$work/eval-junit.log" 2>&1 <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("run_eval", sys.argv[1])
run_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_eval)
case = {"file": "tests/e2e-browser/x.spec.ts", "name": "x"}
at = f"        at {run_eval.CI_CHECKOUT}/tests/e2e-browser/x.spec.ts:7:3"
problems = []


def report(error):
    test = dict(case, error=error)
    return run_eval.junit(test, 3, 1, run_eval.reporter_error(test, 7, 3))[1]


multi = report("Test timeout of 60000ms exceeded.\n\nError: locator.click: Test timeout of 60000ms exceeded.\n"
               "Call log:\n  - waiting for getByRole('button')")
lines = multi.splitlines()
if "    Test timeout of 60000ms exceeded." not in lines or "      - waiting for getByRole('button')" not in lines:
    problems.append("the multi-line error was changed:\n" + multi)
if "Error: Test timeout" in multi or at in lines:
    problems.append("the eval added its own 'Error: ' or 'at' line to the reporter's text:\n" + multi)
one = report("locator.click: Timeout 10000ms exceeded.")
if "    Error: locator.click: Timeout 10000ms exceeded." not in one.splitlines() or at not in one.splitlines():
    problems.append("the one-line error wasn't completed:\n" + one)
print("\n".join(problems) or "the reporter's text is kept")
sys.exit(1 if problems else 0)
PY
code=$?
set -e
if [ "$code" -eq 0 ]; then ok "eval-keeps-the-reporter-text"; else bad "eval-keeps-the-reporter-text" "$(cat "$work/eval-junit.log")"; fi
# Each attempt's error-context.md, as Playwright 1.65 writes it: in the folder Playwright names (checked against a
# real Kestrel run), with the page snapshot that the case's error gives after its "Error Context:" line. The snapshot
# leaves the report, an attempt without the line gets it, and a malformed snapshot or path is refused.
set +e
python3 - "$root/evals/triage/run-eval.py" > "$work/eval-context.log" 2>&1 <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("run_eval", sys.argv[1])
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
problems = []
real = "adaptive-attack-1-offers-a-405a0--caps-FR-001-FR-014-FR-016--chromium"
got = ev.output_folder("tests/e2e-browser/adaptive-attack.spec.ts",
                       "1. offers an Adaptive mode that shows the attacker and caps [FR-001, FR-014, FR-016]",
                       test_dir="tests/e2e-browser")
if got != real:
    problems.append(f"output folder {got!r}; Playwright named it {real!r}")
case = {"id": "x", "file": "tests/e2e-browser/x.spec.ts", "name": "x"}
sources = {case["file"]: "import { test, expect } from '@playwright/test';\n\ntest('x', async ({ page }) => {\n"
                         "  await page.goto('/');\n  // the heading\n"
                         "  await expect(page.getByRole('heading')).toHaveText('Hello');\n});\n"}
attempt = ("Error: expect(locator).toHaveText(expected) failed\n\nExpected: \"Hello\"\nReceived: \"Bye\"\n\n"
           "  5 |   // the heading\n> 6 |   await expect(page.getByRole('heading')).toHaveText('Hello');\n"
           "    |                                           ^\n"
           f"    at {ev.CI_CHECKOUT}/tests/e2e-browser/x.spec.ts:6:43")
error = (attempt + "\n\nError Context: test-results/x-x-chromium/error-context.md\n\n# Page snapshot\n\n```yaml\n"
         "- heading \"Bye\" [level=1]\n```\n\nRetry #1 " + "\N{BOX DRAWINGS LIGHT HORIZONTAL}" * 20 + "\n\n" + attempt)
text, files = ev.error_context(dict(case, error=error), error, sources, 3, 1)
first, retry = "test-results/x-x-chromium/error-context.md", "test-results/x-x-chromium-retry1/error-context.md"
if "# Page snapshot" in text or "- heading" in text:
    problems.append("the page snapshot is still in the report:\n" + text)
if f"Error Context: {first}" not in text.splitlines() or text.splitlines()[-1] != f"Error Context: {retry}":
    problems.append("each attempt must end with its Error Context line:\n" + text)
if sorted(files) != [retry, first]:
    problems.append(f"files {sorted(files)}, want {first} and {retry}")
else:
    for path, wanted, unwanted in (
            (first, ["# Instructions\n\n- Following Playwright test failed.", "- Name: e2e-browser/x.spec.ts >> x",
                     "- Location: tests/e2e-browser/x.spec.ts:3:1",
                     "# Error details\n\n```\nError: expect(locator).toHaveText(expected) failed\n\nExpected: \"Hello\""
                     "\nReceived: \"Bye\"\n```",
                     "# Page snapshot\n\n```yaml\n- heading \"Bye\" [level=1]\n```", "# Test source\n\n```ts\n",
                     "> 6 |   await expect(", "^ Error: expect(locator).toHaveText(expected) failed"],
             ["at /home"]),
            (retry, ["# Error details", "# Test source"], ["# Page snapshot"])):
        problems += [f"{path} lacks {want!r}" for want in wanted if want not in files[path]]
        problems += [f"{path} has {not_wanted!r}" for not_wanted in unwanted if not_wanted in files[path]]
one = dict(case, error="locator.click: Timeout 10000ms exceeded.")
text, files = ev.error_context(one, ev.reporter_error(one, 6, 3), sources, 3, 1)
if (text.splitlines()[-1] != "Error Context: ../test-results/e2e-browser-x-x-chromium/error-context.md"
        or list(files) != ["test-results/e2e-browser-x-x-chromium/error-context.md"]):
    problems.append(f"the one-line error must get its Error Context line and file:\n{text}\n{list(files)}")
snap = dict(case, error="locator.click: Timeout 10000ms exceeded.\n\n# Page snapshot\n\n```yaml\n"
                        "- button \"Go\" [ref=e2] [cursor=pointer]\n```")
text, files = ev.error_context(snap, ev.reporter_error(snap, 6, 3), sources, 3, 1)
if (text.splitlines()[0] != "Error: locator.click: Timeout 10000ms exceeded." or "# Page snapshot" in text
        or "- button \"Go\" [ref=e2] [cursor=pointer]" not in "".join(files.values())):
    problems.append("a one-line error with a page snapshot must be completed, and the snapshot must go to its file:\n"
                    + text)
for bad in (attempt + "\n\n# Page snapshot\n\n- heading", attempt + "\n\nError Context: elsewhere/error-context.md"):
    try:
        ev.error_context(dict(case, error=bad), bad, sources, 3, 1)
        problems.append("accepted a malformed case:\n" + bad)
    except ev.EvalError:
        pass
print("\n".join(problems) or "error-context.md as Playwright writes it")
sys.exit(1 if problems else 0)
PY
code=$?
set -e
if [ "$code" -eq 0 ]; then ok "eval-error-context"; else bad "eval-error-context" "$(cat "$work/eval-context.log")"; fi
# --snapshots (the default) gives each workspace its failure's error-context.md, at the path the report names;
# --no-snapshots gives it none, with the same report. The result file and the report say which.
snap_ok=1
for mode in snapshots no-snapshots; do
  (cd "$root" && env -u CI SKIP_MCP_WARMUP=1 python3 evals/triage/run-eval.py --dry-run --keep "--$mode" \
    --cases "$work/eval-cases.jsonl" --work-dir "$work/eval-dry-$mode" > "$work/eval-dry-$mode.log" 2>&1) || snap_ok=0
done
(cd "$root" && env -u CI PATH="$eval_bin:$PATH" EVAL_STUB_ARGS="$work/eval-off-args.txt" SKIP_MCP_WARMUP=1 \
  GITHUB_STEP_SUMMARY="$work/eval-off-summary.md" python3 evals/triage/run-eval.py --engine claude --no-snapshots \
  --cases "$work/eval-cases.jsonl" --only env --out "$work/eval-off-results" --work-dir "$work/eval-off-run" \
  > "$work/eval-off.log" 2>&1) || snap_ok=0
set +e
python3 - "$work" > "$work/eval-snapshots.log" 2>&1 <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
problems = []
for case in ("drift", "bug", "env"):
    on, off = (work / f"eval-dry-{mode}" / "trials" / f"{case}-r1" / "workspace" for mode in ("snapshots", "no-snapshots"))
    files = sorted(path.relative_to(on).as_posix() for path in on.glob("test-results/*/error-context.md"))
    report = (on / "results" / "junit.xml").read_text(encoding="utf-8")
    if len(files) != 1 or f"Error Context: ../{files[0]}" not in report:
        problems.append(f"{case}: with snapshots its error-context.md files are {files}; the report names "
                        f"{[line.strip() for line in report.splitlines() if 'Error Context' in line]}")
    if (off / "test-results").exists():
        problems.append(f"{case}: --no-snapshots wrote test-results/")
    if (off / "results" / "junit.xml").read_text(encoding="utf-8") != report:
        problems.append(f"{case}: the report differs between the two modes")
results = sorted((work / "eval-off-results").glob("*.json"))
if len(results) != 1 or not results[0].name.endswith("-no-snapshots.json"):
    problems.append(f"--no-snapshots result files: {[path.name for path in results]}")
elif json.loads(results[0].read_text(encoding="utf-8"))["meta"].get("snapshots") is not False:
    problems.append("the result file doesn't record snapshots: false")
if "error-context.md off" not in (work / "eval-off-summary.md").read_text(encoding="utf-8"):
    problems.append("the report doesn't say error-context.md was off")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
code=$?
set -e
if [ "$code" -eq 0 ] && [ "$snap_ok" -eq 1 ]; then
  ok "eval-snapshots-switch"
else
  bad "eval-snapshots-switch" "$(cat "$work/eval-snapshots.log" "$work"/eval-dry-*.log "$work/eval-off.log" 2> /dev/null | tail -n 30)"
fi

# Hide mode, the default when CI is set, on a scratch clone of this repository whose answer key is the stub cases,
# plus an old result file and a note that quotes a case's "why". All of evals/ must be gone before the first agent
# starts; the workspaces get the sample project from memory. In the env case the stub agent tries to read the answer
# key: it must be gone by then, and that run must be reported as invalid and not scored. The result file goes to
# evals/triage/results/ afterwards, where eval-triage.yml uploads it from.
hide_src="$work/hide-src"
mkdir -p "$hide_src"
cp -R "$root/." "$hide_src/"
rm -rf "$hide_src/.git"
cp "$work/eval-cases.jsonl" "$hide_src/evals/triage/cases.jsonl"
mkdir -p "$hide_src/evals/triage/results"
printf '%s\n' '{"trials": [' '  {"case": "bug",' '   "test": "shows correct total",' '   "expected": "REAL_BUG"}]}' \
  > "$hide_src/evals/triage/results/old-run.json"
echo "Remember: never-shown-to-the-agent" > "$hide_src/notes.txt"
git -C "$hide_src" -c init.defaultBranch=main init -q
git -C "$hide_src" -c core.autocrlf=false add -A
git -C "$hide_src" -c core.autocrlf=false -c user.name=ci -c user.email=ci@example.com -c commit.gpgsign=false \
  commit -qm "scratch copy" --no-verify
git -c core.autocrlf=false clone -q "$hide_src" "$work/hide-repo"
git -c core.autocrlf=false clone -q "$hide_src" "$work/guard-repo"
set +e
(cd "$work/hide-repo" && env CI=true PATH="$eval_bin:$PATH" EVAL_STUB_ARGS="$work/hide-args.txt" \
  EVAL_STUB_PEEK="$work/hide-repo/evals/triage/cases.jsonl" EVAL_STUB_PEEK_ON="home page loads" SKIP_MCP_WARMUP=1 \
  GITHUB_STEP_SUMMARY="$work/hide-summary.md" python3 evals/triage/run-eval.py --engine claude --jobs 1 \
  --work-dir "$work/hide-run" > "$work/hide.log" 2>&1)
code=$?
set -e
{ cat "$work/hide-summary.md" "$work"/hide-repo/evals/triage/results/*.json "$work/hide.log" \
    "$work/hide-run/trials/env-r1/agent.log"; } > "$work/hide-transcript" 2> /dev/null || true
check_texts eval-hide-answers-in-ci "$work/hide-transcript" \
  "+  evals/  (the eval: its cases, result files" "-  evals/triage/" \
  "+  notes.txt  (drift: its why" "+  tests/run-tests.sh  (drift: its why" "+  .git/  (" \
  "+Answer key deleted from the checkout before the first agent started" \
  "+drift run 1: got SELECTOR_DRIFT" "-run 1: expected" "+No such file or directory" "-never-shown-to-the-agent" \
  "+**Accuracy** 1/2 (50%)" "+**Critical: REAL_BUG classified as SELECTOR_DRIFT** 1" "+**Invalid runs** 1 (not scored)" \
  "+### Invalid runs (1 of 3)" "+| env | 1 | SELECTOR_DRIFT | the log mentions cases.jsonl" \
  "+\"invalid\": 1," "+\"scored\": 2," "+\"invalid\": \"the log mentions cases.jsonl"
present=""
missing=""
for f in notes.txt tests/run-tests.sh .git; do
  if [ -e "$work/hide-repo/$f" ]; then present+=" $f"; fi
done
# Only the new result file may be in evals/: written after the last agent finished.
left_in_evals="$(cd "$work/hide-repo" && find evals -type f 2> /dev/null || true)"
if [ "$(printf '%s' "$left_in_evals" | grep -c .)" -ne 1 ] \
  || [[ "$left_in_evals" != evals/triage/results/*-claude-default.json ]]; then
  present+=" evals/:[${left_in_evals//$'\n'/,}]"
fi
for f in agents/common/triage.md AGENT-RULES.md README.md scripts/run-agent.sh settings/claude-settings.json; do
  if [ ! -e "$work/hide-repo/$f" ]; then missing+=" $f"; fi
done
if [ "$code" -eq 0 ] && [ -z "$present$missing" ]; then
  ok "eval-hide-answers-deletes-the-key"
else
  bad "eval-hide-answers-deletes-the-key" "exit $code; still there:${present:- none}; deleted by mistake:${missing:- none}"
fi
# Except in a GitHub Actions job's own checkout, hide mode must not delete a .git that holds work on no remote.
echo "work in progress" > "$work/guard-repo/wip.txt"
set +e
(cd "$work/guard-repo" && env CI=true PATH="$eval_bin:$PATH" EVAL_STUB_ARGS="$work/guard-args.txt" SKIP_MCP_WARMUP=1 \
  GITHUB_STEP_SUMMARY="$work/guard-summary.md" python3 evals/triage/run-eval.py --engine claude --jobs 1 \
  --out "$work/guard-results" --work-dir "$work/guard-run" > "$work/guard.log" 2>&1)
code=$?
set -e
if [ "$code" -eq 1 ] && grep -qF "would delete .git, which holds uncommitted changes" "$work/guard.log" \
  && [ -e "$work/guard-repo/.git" ] && [ -e "$work/guard-repo/evals/triage/cases.jsonl" ] \
  && [ -e "$work/guard-repo/tests/run-tests.sh" ] && [ ! -e "$work/guard-args.txt" ]; then
  ok "eval-hide-answers-keeps-local-work"
else
  bad "eval-hide-answers-keeps-local-work" "exit $code"$'\n'"$(cat "$work/guard.log")"
fi

echo
echo "agent permissions on the real engines (tests/engine-permissions/; a fake model, no API key)"
# Chained, substituted, expanded and redirected commands must be refused, and the test command and the triage
# output must still work, on each engine as staged for CI. Files outside the workspace must be refused without
# ending the run. This needs the engine CLIs: ci.yml installs the versions
# the workflows install by default and sets REQUIRE_ENGINES=1, so there a missing engine fails instead of skipping.
if python3 - "$root" > "$work/engine-versions.log" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
problems = []
for name, var in (("claude_code_version", "CLAUDE_CODE_VERSION"), ("opencode_version", "OPENCODE_VERSION")):
    tested = re.search(rf'^\s+{var}: "([^"]+)"', ci, re.M)
    for workflow in ("test-and-heal.yml", "generate-tests.yml", "eval-triage.yml"):
        text = (root / ".github/workflows" / workflow).read_text(encoding="utf-8")
        used = re.search(rf'^\s+{name}:\n(?:\s+\w+:.*\n)*?\s+default: "([^"]+)"', text, re.M) or re.search(
            rf'^\s+{var}: "([^"]+)"', text, re.M)
        if not tested or not used or tested.group(1) != used.group(1):
            problems.append(f"{workflow} installs {var} {used and used.group(1)}, ci.yml tests "
                            f"{tested and tested.group(1)}")
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
then
  ok "engine-versions-match"
else
  bad "engine-versions-match" "$(cat "$work/engine-versions.log")"
fi
engines=(claude opencode)
pids=()
for engine in "${engines[@]}"; do
  python3 "$root/tests/engine-permissions/check.py" "$engine" "$work/permissions-$engine" \
    > "$work/permissions-$engine.log" 2>&1 &
  pids+=("$!")
done
for n in "${!engines[@]}"; do
  engine="${engines[$n]}"
  set +e
  wait "${pids[$n]}"
  code=$?
  set -e
  if [ "$code" -eq 3 ]; then
    if [ "${REQUIRE_ENGINES:-0}" = 1 ]; then
      bad "$engine-permissions" "$engine is not installed, and REQUIRE_ENGINES=1"
    else
      echo "  skip  $engine-permissions ($engine is not installed)"
    fi
    continue
  fi
  while IFS=$'\t' read -r status name detail; do
    case "$status" in
      ok) ok "$name" ;;
      FAIL) bad "$name" "$detail" ;;
    esac
  done < "$work/permissions-$engine.log"
  if [ "$code" -ne 0 ] && ! grep -q '^FAIL' "$work/permissions-$engine.log"; then
    bad "$engine-permissions" "exit $code"$'\n'"$(tail -n 20 "$work/permissions-$engine.log")"
  fi
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
