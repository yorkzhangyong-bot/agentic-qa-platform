#!/usr/bin/env bash
# write-summary.sh — add the test results from JUnit XML (any framework) to the GitHub Actions job summary.
#
# Usage:  write-summary.sh [REPORT_GLOB] [TRIAGE_JSON]
#         REPORT_GLOB defaults to $REPORT_GLOB, then "results/*.xml". Supports ** and {a,b}.
#         TRIAGE_JSON, e.g. results/triage.json: if the file exists, the failed tests get a Triage column with
#         their classification and reason, matched on name + classname like the triage agent writes them.
# Environment:
#   GITHUB_STEP_SUMMARY  file the markdown is appended to (set by GitHub Actions); if unset, it is printed
#   FRAMEWORK            framework name for the header
#   COMMIT_SHA           tested commit for the header (default $GITHUB_SHA); linked when GITHUB_SERVER_URL and
#                        GITHUB_REPOSITORY are set
# Output: a header with the framework and commit, a counts line (total, passed, failed, skipped, duration) and a
#         table of the failed tests (test, file, first line of the error with pipes escaped, cut to 200 characters;
#         at most 100 rows), or "No tests found" when no report matches.
# Always exits 0, so the summary can never fail a job. A report or triage file that can't be parsed is skipped,
# and the summary says so.
set -euo pipefail

glob="${1:-${REPORT_GLOB:-results/*.xml}}"
triage="${2:-}"
out="${GITHUB_STEP_SUMMARY:-}"

note() {  # note <markdown>: last-resort message, used when the Python part could not run; never fails
  printf 'write-summary: %s\n' "$1" >&2
  { if [ -n "$out" ]; then printf '%s\n\n' "$1" >> "$out"; else printf '%s\n\n' "$1"; fi; } 2> /dev/null || true
}

if ! command -v python3 > /dev/null 2>&1; then
  note "> **Warning:** no test summary, because python3 is not installed."
  exit 0
fi

status=0
python3 - "$glob" "$triage" "$out" <<'PY' || status=$?
import glob
import json
import math
import os
import re
import sys
import traceback
import xml.etree.ElementTree as ET

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

pattern, triage_path, out_path = sys.argv[1:4]
MAX_ROWS = 100  # failed tests listed in the table
MAX_TEXT = 200  # characters kept of an error line or a triage reason

# The error-line heuristics and the file resolution are the same as in parse-report.sh, so the table names the same
# files as results/failures.json and results/triage.json.
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
ERROR_LINE = re.compile(r"^[ \t]*(?:(?:[A-Za-z_$][\w$]*\.)*[A-Za-z_$][\w$]*(?:Error|Exception|Failure)|Error)\b.*$", re.M)
TITLE_ONLY = re.compile(r"^\S+:\d+:\d+\s")  # Playwright puts "file:line:col title" in @message
SOURCE_EXT = re.compile(r"\.(?:[cm]?[jt]sx?|java|kt|groovy|py|feature)$")
JAVA_CLASS = re.compile(r"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$")
SKIP_DIRS = {".git", "node_modules", "target", "results", ".agentic-qa", "test-results", "playwright-report"}
# Escaped in table cells: "|" would end the cell, "<" would start an HTML tag ("expected: <true> but was: <false>"),
# the rest would turn into emphasis, code, links, strikethrough, entities or math.
MARKDOWN = re.compile(r"([\\`*_\[\]<>|~&$])")
SEP, ELLIPSIS, NONE = " \u00b7 ", "\u2026", "\u2014"  # middle dot, ellipsis, em dash


def expand_braces(p):
    m = re.search(r"\{([^{}]*)\}", p)
    if not m:
        return [p]
    return [x for alt in m.group(1).split(",") for x in expand_braces(p[:m.start()] + alt + p[m.end():])]


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


_index = None


def find_source(rel):
    """Map 'checkout.spec.ts', '/abs/path/tests/x.cy.ts' or 'com/acme/LoginTest.java' to a repo path."""
    global _index
    rel = rel.replace("\\", "/")
    cwd = os.getcwd().replace("\\", "/").rstrip("/") + "/"
    if rel.startswith(cwd):
        rel = rel[len(cwd):]
    while rel.startswith("./"):
        rel = rel[2:]
    if os.path.isfile(rel):
        return rel
    if _index is None:
        _index = {}
        for root, dirs, files in os.walk("."):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                if SOURCE_EXT.search(name):
                    _index.setdefault(name, []).append(os.path.join(root, name)[2:].replace("\\", "/"))
    hits = [p for p in _index.get(os.path.basename(rel), []) if p == rel or p.endswith("/" + rel)]
    return min(hits, key=len) if hits else rel


def case_file(case, suites, doc_file, classname):
    for el in [case] + suites[::-1]:
        if el.get("file"):
            return find_source(el.get("file"))
    if doc_file:  # Cypress (mocha-junit-reporter) puts the spec path on the "Root Suite"
        return find_source(doc_file)
    if SOURCE_EXT.search(classname) or "/" in classname:  # Playwright: classname is the spec file
        return find_source(classname)
    if JAVA_CLASS.match(classname):  # Surefire: classname is the fully-qualified test class
        return find_source(classname.split("$", 1)[0].replace(".", "/") + ".java")
    return ""


def iter_cases(root):
    state = {"file": ""}

    def walk(el, suites):
        for child in el:
            tag = local(child.tag)
            if tag == "testsuite":
                if child.get("file"):
                    state["file"] = child.get("file")
                yield from walk(child, suites + [child])
            elif tag == "testcase":
                yield child, suites, state["file"]

    tag = local(root.tag)
    if tag == "testsuite":
        if root.get("file"):
            state["file"] = root.get("file")
        yield from walk(root, [root])
    elif tag == "testsuites":
        yield from walk(root, [])


def one_line(text):
    return " ".join(str(text).split())


def clip(text, limit=MAX_TEXT):
    text = one_line(text)
    return text if len(text) <= limit else text[:limit - 1].rstrip() + ELLIPSIS


def md(text):
    """One line of text, safe inside a markdown table cell."""
    return MARKDOWN.sub(r"\\\1", one_line(text))


def code(text):
    return "`" + one_line(text).replace("`", "'") + "`"


def first_error_line(problem):
    """First line of the error message of a <failure> or <error>, skipping Playwright's "file:line:col title"."""
    text = ANSI.sub("", problem.text or "")
    m = ERROR_LINE.search(text)
    if m:
        return m.group(0).strip()
    attr = [line.strip() for line in ANSI.sub("", problem.get("message") or "").splitlines() if line.strip()]
    if attr and not TITLE_ONLY.match(attr[0]):
        return attr[0]
    body = [line.strip() for line in text.splitlines() if line.strip()]
    return (body or attr or [problem.get("type") or ""])[0]


def seconds(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number >= 0 else None


def read_report(path):
    """Counts, failed tests and duration of one JUnit XML file."""
    root = ET.parse(path).getroot()
    cases = list(iter_cases(root))
    result = {"total": len(cases), "passed": 0, "skipped": 0, "rows": []}
    for case, suites, doc_file in cases:
        problem = next((c for c in case if local(c.tag) in ("failure", "error")), None)
        if problem is not None:
            classname = case.get("classname") or ""
            result["rows"].append({
                "name": case.get("name") or "",
                "classname": classname,
                "file": case_file(case, suites, doc_file, classname),
                "error": first_error_line(problem),
            })
        elif any(local(c.tag) == "skipped" for c in case):
            result["skipped"] += 1
        else:
            result["passed"] += 1
    # The report's own total (wall-clock time for parallel Playwright workers) beats the sum of the test times.
    duration = seconds(root.get("time"))
    result["duration"] = duration if duration is not None else sum(seconds(c.get("time")) or 0.0 for c, _, _ in cases)
    return result


def loose(name):
    return re.sub(r"\W+", "", str(name).casefold())


def load_triage(path):
    with open(path, encoding="utf-8-sig") as fh:
        data = json.load(fh)
    items = data.get("items") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise ValueError('expected an object with an "items" array')
    triage = {"exact": {}, "name": {}, "loose": {}}
    for item in items:
        if isinstance(item, dict) and item.get("name"):
            name = str(item["name"])
            triage["exact"].setdefault((name, str(item.get("classname") or "")), item)
            triage["name"].setdefault(name, []).append(item)
            triage["loose"].setdefault(loose(name), []).append(item)
    return triage


def triage_item(triage, row):
    """The triage entry with the test's name + classname; failing that, the only entry with the same name, or the only
    one whose name matches when case and punctuation are ignored (an agent may retype "›" as ">")."""
    item = triage["exact"].get((row["name"], row["classname"]))
    for index, key in (("name", row["name"]), ("loose", loose(row["name"]))):
        if item is None and key and len(triage[index].get(key, [])) == 1:
            item = triage[index][key][0]
    return item


def triage_cell(item):
    if item is None:
        return "_not triaged_"
    label = f"**{md(clip(item.get('classification') or 'unclassified', 40))}**"
    reason = clip(item.get("reason") or "")
    return f"{label}: {md(reason)}" if reason else label


def duration_text(total):
    if round(total, 1) < 60:
        return f"{total:.1f}s"
    minutes, secs = divmod(int(round(total)), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m {secs:02d}s" if hours else f"{minutes}m {secs:02d}s"


def header():
    title = "Test results"
    framework = one_line(os.environ.get("FRAMEWORK", ""))
    if framework:
        title += f": {md(framework)}"
    sha = one_line(os.environ.get("COMMIT_SHA") or os.environ.get("GITHUB_SHA") or "")
    if re.fullmatch(r"[0-9a-fA-F]{7,64}", sha):
        commit = f"`{sha[:7]}`"
        server, repo = os.environ.get("GITHUB_SERVER_URL", ""), os.environ.get("GITHUB_REPOSITORY", "")
        if server and repo:
            commit = f"[{commit}]({server.rstrip('/')}/{repo}/commit/{sha})"
        title += f" @ {commit}"
    elif sha:
        title += f" @ {md(sha)}"
    return f"## {title}"


def summary():
    reports = sorted({f.replace("\\", "/") for p in expand_braces(pattern) for f in glob.glob(p, recursive=True)
                      if os.path.isfile(f)})
    lines = [header(), ""]
    rows = []
    total = passed = skipped = parsed = 0
    duration = 0.0
    for report in reports:
        try:
            result = read_report(report)
        except Exception as exc:  # an unreadable report is named in the summary, never fatal
            lines += [f"> **Warning:** could not parse {code(report)} ({md(clip(exc, 160))}); its tests are missing "
                      "from this summary.", ""]
            continue
        parsed += 1
        total += result["total"]
        passed += result["passed"]
        skipped += result["skipped"]
        duration += result["duration"]
        rows += result["rows"]
    print(f"write-summary: {total} test(s), {len(rows)} failed, from {parsed} of {len(reports)} report(s) "
          f"matching {pattern}", file=sys.stderr)

    if not reports:
        return lines + [f"No tests found: no JUnit reports match {code(pattern)}."]
    if total == 0:
        return lines + [f"No tests found in the JUnit reports matching {code(pattern)}." if parsed else
                        "No tests found: none of the JUnit reports could be parsed."]
    lines.append(SEP.join([f"**Total** {total}", f"**Passed** {passed}", f"**Failed** {len(rows)}",
                           f"**Skipped** {skipped}", f"**Duration** {duration_text(duration)}"]))
    if not rows:
        return lines

    lines += ["", "### Failed tests", ""]
    columns = ["Test", "File", "Error"]
    triage = None
    if triage_path:
        if not os.path.isfile(triage_path):
            lines += [f"No triage results: {code(triage_path)} does not exist.", ""]
        else:
            try:
                triage = load_triage(triage_path)
                columns.append("Triage")
            except Exception as exc:  # an unreadable triage file only costs the Triage column
                lines += [f"> **Warning:** could not read the triage file {code(triage_path)} ({md(clip(exc, 160))}).",
                          ""]
    lines.append("| " + " | ".join(columns) + " |")
    lines.append("| " + " | ".join(["---"] * len(columns)) + " |")
    for row in rows[:MAX_ROWS]:
        cells = [md(row["name"]) or NONE, md(row["file"]) or NONE, md(clip(row["error"])) or NONE]
        if triage is not None:
            cells.append(triage_cell(triage_item(triage, row)))
        lines.append("| " + " | ".join(cells) + " |")
    if len(rows) > MAX_ROWS:
        lines += ["", f"Showing the first {MAX_ROWS} of {len(rows)} failed tests."]
    return lines


try:
    lines = summary()
except Exception as exc:  # never fail the job: say what went wrong in the summary instead
    traceback.print_exc()
    lines = ["## Test results", "",
             f"> **Warning:** the test summary could not be generated ({md(type(exc).__name__)}: {md(clip(exc, 160))})."]
text = "\n".join(lines) + "\n\n"
if out_path:
    with open(out_path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
else:
    sys.stdout.write(text)
PY
if [ "$status" -ne 0 ]; then
  note "> **Warning:** the test summary could not be written (python3 exited with code $status)."
fi
exit 0
