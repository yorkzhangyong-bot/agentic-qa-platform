#!/usr/bin/env bash
# check-triage.sh — fail the triage job when it has no usable triage result.
#
# heal and report-defects run only after the triage job succeeded, and only on what results/triage.json classifies.
# Without a triage result they would be skipped, and a failed test run would end without an error. The triage job
# runs this after the triage agent's step, whatever its outcome, from the repository root.
#
# Environment:
#   TRIAGE_JSON     the triage agent's output (default results/triage.json)
#   FAILURES_JSON   the failing tests, from parse-report.sh (default results/failures.json)
#   TRIAGE_OUTCOME  the outcome of the triage agent's step (success, failure or skipped), to say why there's no result
# Exit code: 0 when the triage file is a JSON object whose "items" array classifies at least one failure as
# SELECTOR_DRIFT, REAL_BUG, FLAKY or ENV (with a warning if it classifies fewer items than there are failures);
# otherwise 1, after an ::error:: annotation that says why.
set -euo pipefail

command -v python3 > /dev/null 2>&1 || { echo "::error title=No triage result::check-triage.sh needs python3."; exit 1; }

python3 - "${TRIAGE_JSON:-results/triage.json}" "${FAILURES_JSON:-results/failures.json}" "${TRIAGE_OUTCOME:-}" <<'PY'
import json
import sys

triage_path, failures_path, outcome = sys.argv[1:4]
LABELS = ("SELECTOR_DRIFT", "REAL_BUG", "FLAKY", "ENV")


def fail(reason):
    print(f"::error title=No triage result::{reason} Without a triage result, heal and report-defects don't run.")
    sys.exit(1)


def one_line(text):
    return " ".join(str(text).split())


try:
    with open(failures_path, encoding="utf-8-sig") as fh:
        failures = json.load(fh)
except FileNotFoundError:
    fail(f"{failures_path} doesn't exist: the failing tests were never read from the report (see the step that "
         "failed above).")
except (OSError, ValueError) as exc:
    fail(f"{failures_path} can't be read: {one_line(exc)}.")
if not isinstance(failures, list):
    fail(f"{failures_path} isn't a list of failing tests.")
if not failures:
    fail("The tests failed, but parse-report.sh found no failing test case in their JUnit reports, or no report, so "
         "there was nothing to triage. This usually means an environment or setup problem: see the 'Run tests' step "
         "of the test job.")
count = f"{len(failures)} failing test" + ("s" if len(failures) != 1 else "")

try:
    with open(triage_path, encoding="utf-8-sig") as fh:
        text = fh.read()
except FileNotFoundError:
    text = ""
except OSError as exc:
    fail(f"{triage_path} can't be read: {one_line(exc)}.")
if not text.strip():
    if outcome == "skipped":
        fail(f"The triage agent didn't run, because an earlier step failed (see above), so the {count} weren't "
             "triaged.")
    fail(f"The triage agent wrote no {triage_path} for the {count}; the log of its step shows where it stopped.")
try:
    triage = json.loads(text)
except ValueError as exc:
    fail(f"{triage_path} isn't valid JSON: {one_line(exc)}.")
items = triage.get("items") if isinstance(triage, dict) else None
if not isinstance(items, list):
    fail(f'{triage_path} isn\'t a JSON object with an "items" array, so none of the {count} counts as triaged.')
classified = [item for item in items if isinstance(item, dict) and item.get("classification") in LABELS]
if not classified:
    fail(f"{triage_path} classifies none of the {count}: no item has the classification {', '.join(LABELS[:-1])} "
         f"or {LABELS[-1]}.")
if len(classified) < len(failures):
    print(f"::warning title=Some failures not triaged::{triage_path} classifies {len(classified)} of the {count}. "
          "The others are neither healed nor reported; the job summary marks them as not triaged.")
print(f"check-triage: {triage_path} classifies {len(classified)} item(s) for the {count}.")
PY
