#!/usr/bin/env bash
# parse-report.sh — normalise JUnit XML from any framework (Playwright, Cypress, Maven Surefire, …) into
# results/failures.json.
#
# Usage:  parse-report.sh [REPORT_GLOB]
#         REPORT_GLOB defaults to $REPORT_GLOB, then "results/*.xml". Supports ** and {a,b}.
# Output: results/failures.json (override with FAILURES_OUT): a JSON array with one entry per failed or
#         errored test case: { "name", "classname", "file", "message", "stack" }
# Prints the number of failures. Always exits 0; no report files or no failures produce [].
set -euo pipefail

glob="${1:-${REPORT_GLOB:-results/*.xml}}"
out="${FAILURES_OUT:-results/failures.json}"
mkdir -p "$(dirname "$out")"

python3 - "$glob" "$out" <<'PY'
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

pattern, out_path = sys.argv[1], sys.argv[2]

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
# First line that names an error, e.g. "Error: locator.click: …", "AssertionError: Timed out …",
# "org.openqa.selenium.NoSuchElementException: no such element …"
ERROR_LINE = re.compile(r"^[ \t]*(?:(?:[A-Za-z_$][\w$]*\.)*[A-Za-z_$][\w$]*(?:Error|Exception|Failure)|Error)\b.*$", re.M)
TITLE_ONLY = re.compile(r"^\S+:\d+:\d+\s")  # Playwright puts "file:line:col title" in @message
SOURCE_EXT = re.compile(r"\.(?:[cm]?[jt]sx?|java|kt|groovy|py|feature)$")
JAVA_CLASS = re.compile(r"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$")
SKIP_DIRS = {".git", "node_modules", "target", "results", ".agentic-qa", "test-results", "playwright-report"}


def expand_braces(p):
    m = re.search(r"\{([^{}]*)\}", p)
    if not m:
        return [p]
    return [x for alt in m.group(1).split(",") for x in expand_braces(p[:m.start()] + alt + p[m.end():])]


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def clip(text, limit):
    text = ANSI.sub("", text or "").replace("\r\n", "\n").strip()
    return text if len(text) <= limit else text[:limit] + f"\n... [truncated {len(text) - limit} chars]"


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


def best_message(attr, text):
    attr = clip(attr, 1000)
    first_attr = attr.splitlines()[0] if attr else ""
    m = ERROR_LINE.search(text)
    line = m.group(0).strip() if m else ""
    if line:
        waiting = re.search(r"^\s*-\s*waiting for\s+(.+)$", text, re.M)
        if waiting and "waiting for" not in line:
            line += f" (waiting for {waiting.group(1).strip()})"
        if first_attr and not TITLE_ONLY.match(first_attr) and first_attr not in line:
            line = f"{first_attr} | {line}"
        return clip(line, 1000)
    if first_attr and not TITLE_ONLY.match(first_attr):
        return attr
    first_text = next((l.strip() for l in text.splitlines() if l.strip()), "")
    return clip(first_text or attr or "(no message)", 1000)


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


reports = sorted({f for p in expand_braces(pattern) for f in glob.glob(p, recursive=True) if os.path.isfile(f)})
failures = []
for report in reports:
    try:
        root = ET.parse(report).getroot()
    except (ET.ParseError, OSError) as exc:
        print(f"parse-report: skipping {report}: {exc}", file=sys.stderr)
        continue
    for case, suites, doc_file in iter_cases(root):
        problem = next((c for c in case if local(c.tag) in ("failure", "error")), None)
        if problem is None:
            continue
        classname = case.get("classname") or ""
        text = ANSI.sub("", problem.text or "")
        failures.append({
            "name": case.get("name") or "",
            "classname": classname,
            "file": case_file(case, suites, doc_file, classname),
            "message": best_message(problem.get("message"), text),
            "stack": clip(text, 4000),
        })

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(failures, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

if not reports:
    print(f"parse-report: no report files match '{pattern}'")
print(f"parse-report: {len(failures)} failing test(s) in {len(reports)} report file(s) -> {out_path}")
for f in failures[:20]:
    print(f"  - {f['name']} [{f['file'] or f['classname']}]: {f['message'][:160]}")
if len(failures) > 20:
    print(f"  ... and {len(failures) - 20} more")
PY
