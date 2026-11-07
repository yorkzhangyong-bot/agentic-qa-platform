#!/usr/bin/env bash
# run-tests.sh — fixture tests for the platform scripts. No network access or API keys needed.
#
#   anti-cheat.sh    Each tests/anti-cheat/*.diff is applied to a fresh git repo built from tests/anti-cheat/base/.
#                    pass-*.diff must exit 0; fail-*.diff must exit 1 and report the rule in its "# rule:" header.
#                    An optional "# forbidden: a,b" header replaces the default framework forbidden paths.
#   parse-report.sh  Each tests/parse-report/<name>.xml is parsed in a sample project and compared with
#                    tests/parse-report/<name>.expected.json; with no report files the output must be [].
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
