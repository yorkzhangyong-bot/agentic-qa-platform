#!/usr/bin/env bash
# run-tests.sh — fixture tests for scripts/anti-cheat.sh and scripts/parse-report.sh.
#
#   anti-cheat.sh   Each tests/anti-cheat/*.diff is applied to a fresh git repo built from tests/anti-cheat/base/.
#                   pass-*.diff must exit 0; fail-*.diff must exit 1 and report the rule in its "# rule:" header.
#                   An optional "# forbidden: a,b" header replaces the default framework forbidden paths.
#   parse-report.sh Each tests/parse-report/<name>.xml is parsed in a sample project and compared with
#                   tests/parse-report/<name>.expected.json; with no report files the output must be [].
#
# Usage: bash tests/run-tests.sh          (exit code 0 when every fixture passes)
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
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
