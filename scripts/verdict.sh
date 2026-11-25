#!/usr/bin/env bash
# verdict.sh — the final gate of test-and-heal.yml: fail the run on REAL_BUG, ENV, or selector drift that was not
# healed and verified. There is no AI here: it reads the artifacts the earlier jobs wrote and decides.
#
# Usage:  verdict.sh
# Input (environment):
#   TRIAGE_JSON       results/triage.json (default): the triage agent's classification of every failure
#   FAILURES_JSON     results/failures.json (default): the failing tests, for the names and files
#   HEAL_REPORT       results/heal-report.json (default): the healer's status per SELECTOR_DRIFT item
#   VERIFY_FAILURES   results/verify-failures.json (default): the tests still failing in the verification run
#   DEFECTS_REPORT    results/defects-report.json (default): the issues opened or updated per REAL_BUG
#   VERDICT_OUT       results/verdict.json (default): the machine-readable verdict
#   FAIL_ON_FLAKY     "true" to fail the run on FLAKY failures too (default false)
#   PR_URL            the auto-heal pull request URL, linked from unhealed drift rows (may be empty)
#   GITHUB_STEP_SUMMARY  the markdown is appended here; printed if unset
#
# A failure blocks the run when it is REAL_BUG, ENV, or SELECTOR_DRIFT that the healer did not heal and verify
# (healed, and still absent from verify-failures.json after the verification run); FLAKY blocks only with
# FAIL_ON_FLAKY. Every failing test is listed in the summary with its classification and, where there is one, the
# issue or pull request link. The script writes results/verdict.json and exits 1 when anything blocks, so the job,
# and with it the run, fails; the summary is always written first.
set -euo pipefail

out="${GITHUB_STEP_SUMMARY:-}"
fail_on_flaky="${FAIL_ON_FLAKY:-false}"
pr_url="${PR_URL:-}"

python3 - "$fail_on_flaky" "$pr_url" "$out" <<'PY'
import json
import os
import re
import sys

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

fail_on_flaky, pr_url, out_path = sys.argv[1:4]
fail_on_flaky = fail_on_flaky == "true"

MARKDOWN = re.compile(r"([\\`*_\[\]<>|~&$])")  # escaped in table cells, as in write-summary.sh
NONE = "\N{EM DASH}"


def one_line(text):
    return " ".join(str(text).split())


def md(text):
    return MARKDOWN.sub(r"\\\1", one_line(text))


def code(text):
    return "`" + one_line(text).replace("`", "'") + "`"


def loose(name):
    return re.sub(r"\W+", "", str(name).casefold())


def load(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def items_of(data):
    if isinstance(data, dict):
        return data.get("items")
    return data


triage_path = os.environ.get("TRIAGE_JSON", "results/triage.json")
triage_data = load(triage_path)
if triage_data is None:
    print(f"::error title=Verdict::{triage_path} does not exist or is not valid JSON; nothing to decide on", file=sys.stderr)
    sys.exit(1)
triage = items_of(triage_data)
if not isinstance(triage, list):
    print(f"::error title=Verdict::{triage_path} has no items array", file=sys.stderr)
    sys.exit(1)
failures = load(os.environ.get("FAILURES_JSON", "results/failures.json")) or []
heal = load(os.environ.get("HEAL_REPORT", "results/heal-report.json"))
verify = load(os.environ.get("VERIFY_FAILURES", "results/verify-failures.json"))
defects = load(os.environ.get("DEFECTS_REPORT", "results/defects-report.json"))

# The triage lookup, matched the way write-summary.sh matches failures: name + classname, else the only entry with
# the same name, else the only one whose name matches when case and punctuation are ignored.
exact, name_only, loose_map = {}, {}, {}
for item in triage:
    if isinstance(item, dict) and item.get("name"):
        name = item["name"]
        exact[(name, str(item.get("classname") or ""))] = item
        name_only.setdefault(name, []).append(item)
        loose_map.setdefault(loose(name), []).append(item)


def triage_for(failure):
    name = failure.get("name") or ""
    item = exact.get((name, str(failure.get("classname") or "")))
    if item is None:
        cands = name_only.get(name, [])
        item = cands[0] if len(cands) == 1 else None
    if item is None:
        cands = loose_map.get(loose(name), [])
        item = cands[0] if len(cands) == 1 else None
    return item


# The issue opened or updated for a REAL_BUG test, and the healer's status and the verification run's failures.
issue_links = {}
if isinstance(defects, dict):
    for kind in ("created", "updated"):
        for entry in defects.get(kind) or []:
            if isinstance(entry, dict) and entry.get("test") and entry.get("url"):
                issue_links.setdefault(loose(entry["test"]), entry["url"])
heal_status = {}
if isinstance(heal, dict):
    for item in heal.get("items") or []:
        if isinstance(item, dict) and item.get("name"):
            heal_status.setdefault(loose(item["name"]), item.get("status"))
verify_present = isinstance(verify, list)
verify_names = {loose(f["name"]) for f in verify if isinstance(f, dict) and f.get("name")} if verify_present else set()

failures_list = [f for f in failures if isinstance(f, dict)] if isinstance(failures, list) else []
if not failures_list:
    # A missing or empty failures.json: fall back to the triage items, so the verdict still names each classified test.
    failures_list = [{"name": i.get("name"), "classname": i.get("classname"), "file": i.get("file")}
                     for i in triage if isinstance(i, dict) and i.get("name")]

rows = []
blocking = 0
for failure in failures_list:
    item = triage_for(failure)
    cls = (item or {}).get("classification") if item else None
    name = str(failure.get("name") or "")
    file = str(failure.get("file") or (item or {}).get("file") or failure.get("classname") or "")
    key = loose(name)
    link = ""
    verdict = "pass"
    reason = ""
    if cls == "REAL_BUG":
        verdict, link = "fail", issue_links.get(key, "")
        reason = "a real bug: the run fails"
    elif cls == "ENV":
        verdict = "fail"
        reason = "an environment failure: the run fails"
    elif cls == "SELECTOR_DRIFT":
        status = heal_status.get(key)
        healed = status == "healed"
        verified = verify_present and key not in verify_names
        if healed and verified:
            verdict, reason = "healed and verified", "the healer fixed it and the verification run passed it"
        else:
            verdict, link = "fail", pr_url
            if status is None:
                reason = "selector drift the healer never reported healing"
            elif status == "healed":
                reason = "healed, but the verification run still fails it"
            else:
                reason = f"selector drift left {status}"
    elif cls == "FLAKY":
        if fail_on_flaky:
            verdict, reason = "fail", "flaky, and fail_on_flaky is set"
        else:
            verdict, reason = "allowed", "flaky (fail_on_flaky is off)"
    elif cls is None:
        verdict, reason = "not triaged", "no triage entry matches this failure"
    else:
        verdict = "allowed"

    if verdict == "fail":
        blocking += 1
    rows.append({"name": name, "file": file, "classification": cls or "not triaged",
                 "verdict": verdict, "link": link, "reason": reason})

result = {"failed": blocking > 0, "fail_on_flaky": fail_on_flaky, "items": rows}
verdict_out = os.environ.get("VERDICT_OUT", "results/verdict.json")
os.makedirs(os.path.dirname(verdict_out) or ".", exist_ok=True)
with open(verdict_out, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(result, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

lines = ["## Verdict", ""]
if blocking:
    lines.append(f"The run **fails**: {blocking} failing test(s) are REAL_BUG, ENV, or selector drift that was not "
                 f"healed and verified{fail_on_flaky and ' (or flaky, with fail_on_flaky)' or ''}.")
else:
    lines.append("The verdict passes: no REAL_BUG, ENV or unhealed selector drift failure blocks the run.")
lines += ["", "| Test | File | Classification | Verdict | Link |", "| --- | --- | --- | --- | --- |"]
for row in rows:
    link = NONE
    if row["link"]:
        if "/issues/" in row["link"]:
            number = row["link"].rstrip("/").split("/")[-1]
            link = f"[#{number}]({row['link']})" if number.isdigit() else f"[issue]({row['link']})"
        else:
            link = f"[heal PR]({row['link']})"
    lines.append(f"| {md(row['name']) or NONE} | {md(row['file']) or NONE} | {code(row['classification'])} | "
                 f"{md(row['verdict'])} | {link} |")

text = "\n".join(lines) + "\n\n"
if out_path:
    with open(out_path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
else:
    sys.stdout.write(text)

print(f"verdict: {blocking} blocking failure(s) of {len(rows)}; run {'fails' if blocking else 'passes'}", file=sys.stderr)
if blocking:
    print(f"::error title=Verdict::{blocking} failure(s) are REAL_BUG, ENV or unhealed selector drift: "
          f"see the job summary.", file=sys.stderr)
    sys.exit(1)
PY
