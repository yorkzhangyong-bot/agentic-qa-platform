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
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/shop bash "$root/scripts/write-summary.sh" "${@:2}" \
    > "$work/summary.log" 2>&1)
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
summary_check() {  # summary_check <name> <+present|-absent>...: exit 0, and each text is (+) or isn't (-) in the summary
  local name="$1" problems="" item
  shift
  for item in "$@"; do
    if grep -qF -- "${item:1}" "$summary" 2> /dev/null; then
      [ "${item:0:1}" = + ] || problems+="unexpected: ${item:1}"$'\n'
    else
      [ "${item:0:1}" = - ] || problems+="missing: ${item:1}"$'\n'
    fi
  done
  if [ "$code" -eq 0 ] && [ -z "$problems" ]; then
    ok "$name"
  else
    bad "$name" "exit $code"$'\n'"$problems$(cat "$summary" "$work/summary.log" 2> /dev/null)"
  fi
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
import sys

root, scratch, engine = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
problems = []


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
    mcp = json.loads(read(scratch / ".mcp.json"))
    expect(mcp["mcpServers"]["browser"]["args"][0] == "@playwright/mcp@9.9.9", f".mcp.json is not pinned: {mcp}")
else:
    for src in sources:
        staged = read(scratch / ".opencode" / "agents" / src.name)
        head, _, body = staged[4:].partition("\n---\n\n")
        expect(body == read(src).split("\n---\n", 1)[1].lstrip("\n"), f"{src.name}: body differs from the platform agent")
        expect("mode: all" in head and 'model: "openrouter/test-model"' in head, f"{src.name}: mode/model missing")
        for tool in ('"read": true', '"write": true', '"edit": true', '"bash": true', '"glob": true', '"grep": true',
                     '"webfetch": false'):
            expect(tool in head, f"{src.name}: tools map lacks {tool}")
        browser = '"browser_*": true' if "mcp__browser__*" in read(src) else '"browser_*": false'
        expect(browser in head, f"{src.name}: expected {browser}")
    expect(not (scratch / ".opencode" / "agent").exists(), "agents must be staged in .opencode/agents/, not .opencode/agent/")
    expect(read(scratch / "AGENTS.md") == read(root / "AGENT-RULES.md"), "AGENTS.md is not a copy of AGENT-RULES.md")
    config = json.loads(read(scratch / "opencode.json"))
    expect(config["mcp"]["browser"] == {"type": "local", "command": ["npx", "@playwright/mcp@9.9.9", "--headless"],
                                        "enabled": True}, f"opencode.json mcp: {config['mcp']}")
    permission = config["permission"]
    expect(permission["edit"].get("*") == "deny" and permission["edit"].get("e2e/**") == "allow",
           f"edit rules: {permission['edit']}")
    expect(permission["bash"].get("*") == "deny" and permission["bash"].get("npx playwright test*") == "allow"
           and permission["bash"].get("git push*") == "deny", f"bash rules: {permission['bash']}")
    expect(permission["webfetch"] == "deny", "webfetch must be denied")
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
  "-p Do the task. --agent triage --append-system-prompt-file $root/AGENT-RULES.md --allowedTools Read,Edit,Write,Glob,Grep,Agent,Task,mcp__browser__* --mcp-config .mcp.json --strict-mcp-config --permission-mode dontAsk --max-turns 7" \
  ENGINE=claude AGENT=triage MAX_TURNS=7 EXPECTED_OUTPUT=results/triage.json
run_case claude-agent-without-mcp 0 \
  "-p Do the task. --agent pr-writer --append-system-prompt-file $root/AGENT-RULES.md --allowedTools Read,Edit,Write,Glob,Grep,Agent,Task --strict-mcp-config --permission-mode dontAsk --max-turns 20" \
  ENGINE=claude AGENT=pr-writer MAX_TURNS=20 EXPECTED_OUTPUT=PR_BODY.md
run_case opencode-agent 0 \
  "run --agent triage --model openrouter/test-model Do the task." \
  ENGINE=opencode AGENT=triage MAX_TURNS=7 OPENCODE_MODEL=openrouter/test-model EXPECTED_OUTPUT=results/triage.json
run_case missing-output-fails 1 - ENGINE=claude AGENT=triage MAX_TURNS=7 EXPECTED_OUTPUT=results/triage.json STUB_WRITE=0
run_case early-stop-with-output-passes 0 - ENGINE=opencode AGENT=healer MAX_TURNS=7 EXPECTED_OUTPUT=results/heal-report.json STUB_EXIT=3
run_case unknown-engine-fails 2 - ENGINE=gemini AGENT=triage MAX_TURNS=7

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
