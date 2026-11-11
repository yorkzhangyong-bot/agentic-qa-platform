#!/usr/bin/env bash
# run.sh — the locator check end to end with a real Playwright and Chromium, on a TypeScript project like the
# consumers' (its own test.extend fixtures, a page object, assertions with expect).
#
#   1. A git repository with the tests before healing (base/), committed; then the healed tests (project/).
#   2. scripts/locator-check.sh targets lists the changed locators.
#   3. The healed tests run with the probe preloaded (NODE_OPTIONS=--require), which must record the element of
#      every changed locator.
#   4. scripts/locator-check.sh report compares them with the failing run (failing/): the PR section must show one
#      match, two unknown (a test ID; a label the page no longer has) and two mismatches (another button; a button
#      that became a link), and the pull request must be a draft.
#
# Needs network access: npm installs @playwright/test (package.json) and Playwright downloads Chromium, with its
# system dependencies when CI is set (scripts/install-browsers.sh, which retries apt and can go on without them).
# ci.yml runs it; locally: bash tests/locator-probe/run.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
check="$work/check"
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$repo" "$check"
cp -R "$here/project/." "$repo/"
cp -R "$here/base/." "$repo/"
git -C "$repo" init -q
git -C "$repo" config core.autocrlf false
git -C "$repo" add -A
git -C "$repo" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false commit -qm "tests before healing"
base="$(git -C "$repo" rev-parse HEAD)"
cp -R "$here/project/tests/." "$repo/tests/"
cp -R "$here/failing" "$check/before"

(cd "$repo" && npm install --no-audit --no-fund --loglevel=error)
if [ -n "${CI:-}" ]; then  # with the system packages, retried; Chromium must launch (scripts/install-browsers.sh)
  (cd "$repo" && FRAMEWORK=playwright BROWSERS=chromium PLATFORM_DIR="$root" bash "$root/scripts/install-browsers.sh" install)
else
  (cd "$repo" && npx playwright install chromium)
fi

export FRAMEWORK=playwright TEST_DIR=tests BASE_SHA="$base" PLATFORM_DIR="$root" LOCATOR_CHECK_DIR="$check"
(cd "$repo" && GITHUB_OUTPUT="$work/targets.out" bash "$root/scripts/locator-check.sh" targets)
probe="$(sed -n 's/^probe=//p' "$work/targets.out")"
[ -n "$probe" ] || fail "locator-check.sh targets gave no probe"

echo "Running the healed tests with the probe ($probe)"
(cd "$repo" && NODE_OPTIONS="--require $probe" LOCATOR_PROBE_TARGETS="$check/probe-targets.json" \
  LOCATOR_PROBE_OUT="$check/after.jsonl" npx playwright test)
echo "The probe recorded:"
cat "$check/after.jsonl"
python3 - "$check/probe-targets.json" "$check/after.jsonl" <<'PY' || fail "the probe didn't record every changed locator"
import json
import sys

targets = json.load(open(sys.argv[1], encoding="utf-8"))
records = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
recorded = {r["target"] for r in records if r.get("snapshot")}
missing = [t for t in targets if t not in recorded]
print("\n".join(f"not recorded: {t}" for t in missing) or f"all {len(targets)} changed locators recorded")
sys.exit(1 if missing or len(targets) != 5 else 0)
PY

printf 'Body written by the pr-writer.\n' > "$repo/PR_BODY.md"
(cd "$repo" && GITHUB_OUTPUT="$work/report.out" bash "$root/scripts/locator-check.sh" report)
grep -qx "draft=true" "$work/report.out" || fail "the pull request must be a draft"
grep -qx "mismatches=2" "$work/report.out" || fail "expected 2 mismatches"
grep -qx "unknown=2" "$work/report.out" || fail "expected 2 unknown"
while IFS= read -r line; do
  grep -qF -- "$line" "$repo/PR_BODY.md" || fail "the PR section lacks: $line"
done <<'LINES'
link "Settings" → link "Settings". Same role and accessible name.
unknown → button "Sign in". The old locator is a test ID
unknown → textbox "Display name". The failing page has no element the old locator matches
button "Delete" → button "Cancel". The accessible name differs.
button "Checkout" → link "Checkout". The role differs.
LINES
echo "locator probe: ok"
