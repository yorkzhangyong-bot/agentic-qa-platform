#!/usr/bin/env python3
"""run-eval.py — offline evaluation of the triage agent (agents/common/triage.md).

Each labelled failure in evals/triage/cases.jsonl is replayed through the real triage agent, in a temporary
workspace built the way the triage job of .github/workflows/test-and-heal.yml sees a failed run:

  <workspace>/                    git repository with the sample app's tests (evals/triage/project/)
    .agentic-qa/                  this platform: AGENT-RULES.md, agents, frameworks, scripts, settings
    results/junit.xml             a Playwright JUnit report holding the case's one failure
    results/failures.json         written from it by scripts/parse-report.sh, as in CI
    node_modules/.bin/playwright  replays the recorded result if the agent re-runs the test (there is no app)
    .claude/, .mcp.json or …      staged by scripts/stage-agents.sh, as in CI

The agent runs through scripts/run-agent.sh with the triage step's prompt, turn budget and output file, all read
from test-and-heal.yml, and its classification in results/triage.json is compared with the case's label. A case's
"expected" and "why" never reach the workspace.

Usage:
  python3 evals/triage/run-eval.py [--engine claude|opencode] [--model M] [--repeats N] [--jobs N] [--only IDS]
  python3 evals/triage/run-eval.py --check      validate the cases and the CI prompt; no agent, no API calls
  python3 evals/triage/run-eval.py --dry-run    also build every workspace, without running the agent

--model is provider/model for opencode (default $OPENCODE_MODEL, then deepseek/deepseek-flash). For claude it sets
ANTHROPIC_MODEL; without it Claude Code uses its default model, recorded as "default".

Writes evals/triage/results/<date>-<engine>-<model>.json and prints a markdown report, which is also appended to
$GITHUB_STEP_SUMMARY. Exit code: 0 once the eval ran, whatever the score; 1 if the cases, the CI prompt or a
workspace are broken; 2 for a usage error.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVAL_DIR = ROOT / "evals" / "triage"
PROJECT = EVAL_DIR / "project"
WORKFLOW = ROOT / ".github" / "workflows" / "test-and-heal.yml"
TRIAGE_AGENT = "agents/common/triage.md"
LABELS = ("SELECTOR_DRIFT", "REAL_BUG", "FLAKY", "ENV")
REQUIRED = ("id", "file", "name", "error", "expected", "why")
FRAMEWORK = "playwright"
TEST_DIR = "tests"
PLATFORM_PARTS = ("AGENT-RULES.md", "agents", "frameworks", "scripts", "settings")
CI_CHECKOUT = "/home/runner/work/sample-app/sample-app"  # where the tests would be checked out on a GitHub runner
GIT_IDENTITY = {"GIT_AUTHOR_NAME": "Sample Dev", "GIT_AUTHOR_EMAIL": "dev@example.com",
                "GIT_COMMITTER_NAME": "Sample Dev", "GIT_COMMITTER_EMAIL": "dev@example.com",
                "GIT_AUTHOR_DATE": "2026-01-15T10:00:00Z", "GIT_COMMITTER_DATE": "2026-01-15T10:00:00Z"}
SEP = "\N{SINGLE RIGHT-POINTING ANGLE QUOTATION MARK}"  # Playwright's title separator
DOT, TIMES, NONE = "\N{MIDDLE DOT}", "\N{MULTIPLICATION SIGN}", "\N{EM DASH}"
MARKDOWN = re.compile(r"([\\`*_\[\]<>|~&$])")
TEST_CALL = re.compile(r"""^(\s*)test(?:\.\w+)?\(\s*(['"`])(.*?)\2""")
LOCATOR = re.compile(r"(?:getBy\w+|locator|frameLocator)\((?:[^()]|\([^()]*\))*\)")
MATCHER = re.compile(r"\.(to\w+)\(")
ACTION = re.compile(r"\b(?:locator|page|frame)\.(\w+)")
BASH = os.environ.get("EVAL_BASH") or shutil.which("bash") or "bash"
print_lock = threading.Lock()


class EvalError(Exception):
    """A broken case, CI prompt or workspace: unlike a wrong answer from the agent, it makes the eval meaningless."""


def say(text="", stream=sys.stdout):
    with print_lock:
        print(text, file=stream, flush=True)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def remove(path):
    def unlock(func, failed, *_):
        os.chmod(failed, 0o700)  # git marks its objects read-only, which stops rmtree on Windows
        func(failed)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=unlock)
    else:
        shutil.rmtree(path, onerror=unlock)


def run(cmd, cwd, env=None, timeout=300, log=None):
    """Run cmd and return (exit code, output). On timeout the whole process group is stopped, agent included."""
    popen = {"start_new_session": True} if os.name == "posix" else {}
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, **popen)
    try:
        out, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        out, _ = proc.communicate()
        code = 124
        out = (out or b"") + f"\n[stopped after {timeout}s]\n".encode()
    text = (out or b"").decode("utf-8", "replace")
    if log is not None:
        log.write(f"$ {' '.join(str(part) for part in cmd)}\n{text}\n")
        log.flush()
    return code, text


def git(cwd, *args, log=None):
    code, out = run(["git", *args], cwd, env={**os.environ, **GIT_IDENTITY}, log=log)
    if code:
        raise EvalError(f"git {' '.join(args)} failed in {cwd}: {out.strip()[:300]}")
    return out.strip()


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def input_default(lines, name):
    for n, line in enumerate(lines):
        if line.strip() == f"{name}:":
            for follow in lines[n + 1:]:
                if follow.strip() and indent_of(follow) <= indent_of(line):
                    break
                key, _, value = follow.strip().partition(":")
                if key == "default":
                    return value.strip().strip('"')
    raise EvalError(f"{WORKFLOW.name}: the input {name} has no default")


def triage_step(workflow=WORKFLOW):
    """The triage step's PROMPT, MAX_TURNS and EXPECTED_OUTPUT from test-and-heal.yml, so the eval asks exactly what
    CI asks. Fails if the step changes shape, rather than silently testing another prompt."""
    lines = workflow.read_text(encoding="utf-8").splitlines()
    agent = next((n for n, line in enumerate(lines) if line.strip() == "AGENT: triage"), None)
    if agent is None:
        raise EvalError(f"{workflow.name}: no step with AGENT: triage")
    level = indent_of(lines[agent])
    start = end = agent
    while start > 0 and (not lines[start - 1].strip() or indent_of(lines[start - 1]) >= level):
        start -= 1
    while end + 1 < len(lines) and (not lines[end + 1].strip() or indent_of(lines[end + 1]) >= level):
        end += 1
    values, n = {}, start
    while n <= end:
        line = lines[n]
        n += 1
        if not line.strip() or indent_of(line) != level or ":" not in line:
            continue
        key, _, value = line.strip().partition(":")
        value = value.strip()
        if value in (">", ">-", "|", "|-"):
            block = []
            while n <= end and (not lines[n].strip() or indent_of(lines[n]) > level):
                block.append(lines[n].strip())
                n += 1
            value = " ".join(part for part in block if part) if value.startswith(">") else "\n".join(block)
        values[key] = value
    prompt = values.get("PROMPT", "")
    for expression, value in (("${{ env.TEST_DIR }}", TEST_DIR), ("${{ inputs.framework }}", FRAMEWORK),
                              ("${{ inputs.app_url || 'not provided' }}", "not provided")):
        prompt = prompt.replace(expression, value)
    if not prompt or "${{" in prompt:
        raise EvalError(f"{workflow.name}: can't fill in the triage prompt: {prompt or 'no PROMPT'}")
    max_turns = values.get("MAX_TURNS", "")
    if max_turns == "${{ inputs.triage_max_turns }}":
        max_turns = input_default(lines, "triage_max_turns")
    if not max_turns.isdigit():
        raise EvalError(f"{workflow.name}: unexpected MAX_TURNS for triage: {max_turns!r}")
    expected_output = values.get("EXPECTED_OUTPUT", "")
    if not expected_output.startswith("results/"):
        raise EvalError(f"{workflow.name}: unexpected EXPECTED_OUTPUT for triage: {expected_output!r}")
    return {"prompt": prompt, "max_turns": int(max_turns), "expected_output": expected_output}


def load_cases(path):
    cases, errors, seen = [], [], set()
    for n, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        try:
            case = json.loads(line)
        except ValueError as exc:
            errors.append(f"line {n}: not valid JSON ({exc})")
            continue
        if not isinstance(case, dict):
            errors.append(f"line {n}: not a JSON object")
            continue
        where = f"line {n} ({case.get('id', '?')})"
        missing = [key for key in REQUIRED if not isinstance(case.get(key), str) or not case[key].strip()]
        if missing:
            errors.append(f"{where}: missing or empty {', '.join(missing)}")
            continue
        if not re.fullmatch(r"[A-Za-z0-9._-]+", case["id"]):
            errors.append(f"{where}: an id may only contain letters, digits, '.', '_' and '-'")
        if case["id"] in seen:
            errors.append(f"{where}: duplicate id")
        seen.add(case["id"])
        if case["expected"] not in LABELS:
            errors.append(f"{where}: expected must be one of {', '.join(LABELS)}, not {case['expected']!r}")
        if not case["file"].startswith(f"{TEST_DIR}/") or ".." in case["file"].split("/"):
            errors.append(f"{where}: file must be a path under {TEST_DIR}/")
        if case.get("rerun", "fail") not in ("fail", "pass"):
            errors.append(f"{where}: rerun must be fail or pass")
        cases.append(case)
    if not cases and not errors:
        errors.append("no cases")
    return cases, errors


def find_test(source, name):
    """1-based line and column of test('<title>', …), where the title is the last part of the case's name."""
    title = name.split(f" {SEP} ")[-1]
    for n, line in enumerate(source.splitlines(), 1):
        m = TEST_CALL.match(line)
        if m and m.group(3) == title:
            return n, len(m.group(1)) + 1
    return None


def fixture_warnings(cases):
    warnings = []
    for case in cases:
        source = PROJECT / case["file"]
        if not source.is_file():
            warnings.append(f"{case['id']}: {case['file']} is not in evals/triage/project/; its workspace gets a stub test")
        elif find_test(source.read_text(encoding="utf-8"), case["name"]) is None:
            warnings.append(f"{case['id']}: {case['file']} has no test titled {case['name']!r}")
    return warnings


def failing_line(lines, decl, error):
    """0-based index of the statement that most likely failed, for the stack trace: the line with the error's locator,
    else the last one with its matcher, else the one with its action, else the test's last await."""
    end = next((n for n in range(decl, len(lines)) if lines[n].startswith("});")), len(lines))
    body = range(decl, end)
    for locator in LOCATOR.findall(error):
        for probe in (locator, locator[:-1]):
            hit = next((n for n in body if probe in lines[n]), None)
            if hit is not None:
                return hit
    for matcher in MATCHER.findall(error):
        hit = next((n for n in reversed(body) if f".{matcher}(" in lines[n]), None)
        if hit is not None:
            return hit
    for action in ACTION.findall(error):
        hit = next((n for n in body if f".{action}(" in lines[n]), None)
        if hit is not None:
            return hit
    return next((n for n in reversed(body) if "await" in lines[n]), max(decl - 1, 0))


def junit(case, decl, decl_col, at_line, at_col):
    """A Playwright JUnit report with the one failure, and the failure text (as the line reporter prints it)."""
    rel = case["file"][len(TEST_DIR) + 1:]
    error = case["error"].strip()
    if not re.match(r"\w*(?:Error|Exception)\b", error):
        error = f"Error: {error}"  # Playwright prints a thrown error as "<ErrorClass>: <message>"
    header = f"[chromium] {SEP} {rel}:{decl}:{decl_col} {SEP} {case['name']}"
    text = "\n".join([f"  {header}", "", *(f"    {line}" for line in error.splitlines()), "",
                      f"        at {CI_CHECKOUT}/{case['file']}:{at_line}:{at_col}"])
    suites = ET.Element("testsuites", {"id": "", "name": "", "tests": "1", "failures": "1", "skipped": "0",
                                       "errors": "0", "time": "14.2"})
    suite = ET.SubElement(suites, "testsuite", {"name": rel, "timestamp": "2026-01-15T10:05:00.000Z",
                                                "hostname": "chromium", "tests": "1", "failures": "1",
                                                "skipped": "0", "time": "12.8", "errors": "0"})
    testcase = ET.SubElement(suite, "testcase", {"name": case["name"], "classname": rel, "time": "12.8"})
    failure = ET.SubElement(testcase, "failure", {"message": f"{rel.split('/')[-1]}:{decl}:{decl_col} {case['name']}",
                                                  "type": "FAILURE"})
    failure.text = text
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(suites, encoding="unicode") + "\n", text


def rerun_shim(case, failure_text):
    """node_modules/.bin/playwright for the workspace: `npx playwright test …` replays the recorded result."""
    lines = failure_text.splitlines()
    if case.get("rerun", "fail") == "pass":
        output, code = "Running 1 test using 1 worker\n\n  1 passed (6.1s)\n", 0
    else:
        header = lines[0].strip()
        output = "\n".join(["Running 1 test using 1 worker", "", f"  1) {header}", *lines[1:], "", "  1 failed",
                            f"    {header}"]) + "\n"
        code = 1
    marker = "PLAYWRIGHT_OUTPUT_" + hashlib.sha1(output.encode("utf-8")).hexdigest()[:12]
    return ("#!/usr/bin/env bash\n"
            "# Replays the recorded result of this test run.\n"
            'if [ "${1:-}" = --version ]; then echo "Version 1.65.0"; exit 0; fi\n'
            'if [ "${1:-}" != test ]; then echo "playwright: unknown command ${1:-}" >&2; exit 1; fi\n'
            f"cat <<'{marker}'\n{output}{marker}\nexit {code}\n")


def build_workspace(case, ws, engine, model, log):
    """The workspace of a failed CI run with this one failure; returns its entry in results/failures.json."""
    shutil.copytree(PROJECT, ws)
    test_file = ws / case["file"]
    if not test_file.is_file():
        title = case["name"].split(f" {SEP} ")[-1].replace("\\", "\\\\").replace("'", "\\'")
        write(test_file, "import { test } from '@playwright/test';\n\n"
                         f"test('{title}', async ({{ page }}) => {{\n  await page.goto('/');\n}});\n")
    git(ws, "init", "-q", log=log)
    git(ws, "config", "core.autocrlf", "false", log=log)
    git(ws, "add", "-A", log=log)
    git(ws, "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "Add end-to-end tests for the web app",
        log=log)
    for part in PLATFORM_PARTS:
        source, target = ROOT / part, ws / ".agentic-qa" / part
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    source_lines = test_file.read_text(encoding="utf-8").splitlines()
    decl, decl_col = find_test("\n".join(source_lines), case["name"]) or (1, 1)
    at = failing_line(source_lines, decl, case["error"])
    at_col = indent_of(source_lines[at]) + 1 if at < len(source_lines) else 1
    report, failure_text = junit(case, decl, decl_col, at + 1, at_col)
    write(ws / "results" / "junit.xml", report)
    shim = ws / "node_modules" / ".bin" / "playwright"
    write(shim, rerun_shim(case, failure_text))
    shim.chmod(0o755)
    write(shim.with_suffix(".cmd"), '@ECHO off\r\nbash "%~dp0playwright" %*\r\n')  # how npx runs it on Windows
    code, out = run([BASH, ".agentic-qa/scripts/parse-report.sh", "results/*.xml"], ws, log=log)
    if code:
        raise EvalError(f"{case['id']}: parse-report.sh failed: {out.strip()[:300]}")
    failures = json.loads((ws / "results" / "failures.json").read_text(encoding="utf-8"))
    if len(failures) != 1 or failures[0].get("name") != case["name"] or failures[0].get("file") != case["file"]:
        raise EvalError(f"{case['id']}: results/failures.json doesn't hold exactly this failure: {failures}")
    env = {**os.environ, "ENGINE": engine, "FRAMEWORK": FRAMEWORK, "PLATFORM_DIR": ".agentic-qa", "TEST_DIR": TEST_DIR,
           "SKIP_MCP_WARMUP": "1"}
    if engine == "opencode":
        env["OPENCODE_MODEL"] = model
    code, out = run([BASH, ".agentic-qa/scripts/stage-agents.sh"], ws, env=env, log=log)
    if code:
        raise EvalError(f"{case['id']}: stage-agents.sh failed: {out.strip()[:300]}")
    return failures[0]


def read_verdict(path, failure):
    """The agent's classification and reason for the failure, or an error saying why there is none."""
    if not path.is_file():
        return {"error": f"the agent wrote no {path.name}"}
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except ValueError as exc:
        return {"error": f"{path.name} is not valid JSON ({exc})"}
    items = data.get("items") if isinstance(data, dict) else data
    items = [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []
    item = next((i for i in items if i.get("name") == failure["name"]
                 and (i.get("classname") or "") == failure["classname"]), None)
    if item is None and len(items) == 1:
        item = items[0]
    if item is None:
        return {"error": f"{path.name} has no item for this failure"}
    verdict = {"reason": str(item.get("reason") or "")}
    got = str(item.get("classification") or "").strip().upper()
    if got in LABELS:
        verdict["got"] = got
    else:
        verdict["error"] = f"invalid classification {item.get('classification')!r}"
    return verdict


def run_trial(case, repeat, opts, step, work_dir):
    ws = work_dir / "workspaces" / f"{case['id']}-r{repeat}"
    trial = {"case": case["id"], "test": case["name"], "repeat": repeat, "expected": case["expected"], "got": "none",
             "reason": "", "exit_code": None, "seconds": 0.0, "error": ""}
    started = time.monotonic()
    with open(work_dir / "logs" / f"{case['id']}-r{repeat}.log", "w", encoding="utf-8", newline="\n") as log:
        failure = build_workspace(case, ws, opts.engine, opts.model, log)
        if opts.dry_run:
            trial["got"] = "dry-run"
        else:
            env = {**os.environ, "ENGINE": opts.engine, "AGENT": "triage", "PROMPT": step["prompt"],
                   "MAX_TURNS": str(step["max_turns"]), "EXPECTED_OUTPUT": step["expected_output"],
                   "PLATFORM_DIR": ".agentic-qa", "MCP_SERVER": "browser", "MCP_TIMEOUT": "60000",
                   "FRAMEWORK": FRAMEWORK, "TEST_DIR": TEST_DIR, "APP_URL": ""}
            if opts.engine == "opencode":
                env["OPENCODE_MODEL"] = opts.model
            elif opts.model:
                env["ANTHROPIC_MODEL"] = opts.model
            code, _ = run([BASH, ".agentic-qa/scripts/run-agent.sh"], ws, env=env, timeout=opts.timeout, log=log)
            trial["exit_code"] = code
            trial.update(read_verdict(ws / step["expected_output"], failure))
    trial["seconds"] = round(time.monotonic() - started, 1)
    if not opts.keep:
        remove(ws)
    return trial


def score(trials, repeats):
    columns = (*LABELS, "none")
    correct = sum(t["got"] == t["expected"] for t in trials)
    per_label = {label: {"correct": sum(t["got"] == label for t in trials if t["expected"] == label),
                         "total": sum(t["expected"] == label for t in trials)} for label in LABELS}
    confusion = {expected: {got: sum(t["expected"] == expected and t["got"] == got for t in trials) for got in columns}
                 for expected in LABELS}
    by_case = {}
    for trial in trials:
        by_case.setdefault(trial["case"], []).append(trial)
    agreement = {case: Counter(t["got"] for t in runs).most_common(1)[0][1] / len(runs) for case, runs in by_case.items()}
    return {
        "trials": len(trials),
        "correct": correct,
        "accuracy": round(correct / len(trials), 4) if trials else 0.0,
        "per_category": per_label,
        "confusion": confusion,
        "critical_real_bug_as_selector_drift": confusion["REAL_BUG"]["SELECTOR_DRIFT"],
        "consistency": {"repeats": repeats, "unanimous_cases": sum(a == 1 for a in agreement.values()),
                        "cases": len(agreement),
                        "mean_agreement": round(sum(agreement.values()) / len(agreement), 4) if agreement else 0.0},
    }


def md(text, limit=200):
    text = " ".join(str(text).split())
    if len(text) > limit:
        text = text[:limit - 1].rstrip() + "\N{HORIZONTAL ELLIPSIS}"
    return MARKDOWN.sub(r"\\\1", text)


def ratio(part, whole):
    return f"{part}/{whole} ({100 * part / whole:.0f}%)" if whole else f"0/0 ({NONE})"


def report(meta, summary, trials):
    s, c = summary, summary["consistency"]
    lines = [f"## Triage eval: {meta['engine']} {DOT} {meta['model']}", "",
             f"{c['cases']} cases {TIMES} {meta['repeats']} run(s) {DOT} engine `{meta['engine_version']}` {DOT} "
             f"triage.md `{meta['triage_md']['blob'][:7]}`{' (modified)' if meta['triage_md']['modified'] else ''} "
             f"{DOT} platform `{meta['platform_commit'][:7]}` {DOT} {meta['date']}", "",
             f"**Accuracy** {ratio(s['correct'], s['trials'])} {DOT} "
             f"**Critical: REAL_BUG classified as SELECTOR_DRIFT** {s['critical_real_bug_as_selector_drift']}"]
    if meta["repeats"] > 1:
        lines.append("")
        lines.append(f"**Consistency** {c['unanimous_cases']}/{c['cases']} cases gave the same answer in all "
                     f"{meta['repeats']} runs {DOT} mean agreement {100 * c['mean_agreement']:.0f}%")
    lines += ["", "| Expected | Correct |", "| --- | --- |"]
    lines += [f"| {label} | {ratio(v['correct'], v['total'])} |" for label, v in s["per_category"].items()]
    columns = (*LABELS, "none")
    lines += ["", "**Confusion** (rows: expected, columns: got)", "",
              "| Expected | " + " | ".join(columns) + " |", "| --- " * (len(columns) + 1) + "|"]
    lines += [f"| {expected} | " + " | ".join(str(row[got]) for got in columns) + " |"
              for expected, row in s["confusion"].items()]
    wrong = {}
    for trial in trials:
        wrong.setdefault(trial["case"], []).append(trial)
    wrong = {case: runs for case, runs in wrong.items() if any(t["got"] != t["expected"] for t in runs)}
    lines += ["", f"### Wrong answers ({len(wrong)} of {c['cases']} cases)", ""]
    if wrong:
        lines += ["| Case | Test | Expected | Got | Agent's reason |", "| --- | --- | --- | --- | --- |"]
        for case, runs in wrong.items():
            got = ", ".join(f"{label} {TIMES}{n}" if len(runs) > 1 else label
                            for label, n in Counter(t["got"] for t in runs).most_common())
            miss = next(t for t in runs if t["got"] != t["expected"])
            lines.append(f"| {md(case)} | {md(miss['test'], 80)} | {miss['expected']} | {got} | "
                         f"{md(miss['reason'] or miss['error'] or NONE)} |")
    else:
        lines.append("None.")
    return "\n".join(lines) + "\n"


def relative(path):
    """path relative to the repository, if it is inside it, for result files that compare across machines."""
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def git_info(*args):
    code, out = run(["git", *args], ROOT)
    return out.strip() if code == 0 else ""


def engine_version(engine):
    code, out = run([BASH, "-c", f"{engine} --version"], ROOT, timeout=120)
    if code:
        raise EvalError(f"`{engine} --version` failed; is the {engine} CLI installed? {out.strip()[:200]}")
    return (out.strip().splitlines() or ["unknown"])[0]


def warm_up_mcp():
    """Download the browser MCP server once, instead of in every workspace."""
    if os.environ.get("SKIP_MCP_WARMUP") == "1":
        return
    version = os.environ.get("PLAYWRIGHT_MCP_VERSION", "")
    if not version:
        servers = json.loads((ROOT / "settings" / "claude-mcp.json").read_text(encoding="utf-8"))["mcpServers"]
        version = next((a.split("@playwright/mcp@", 1)[1] for s in servers.values() for a in s.get("args", [])
                        if a.startswith("@playwright/mcp@")), "latest")
    code, out = run([BASH, "-c", f'npx -y "@playwright/mcp@{version}" --version'], ROOT, timeout=600)
    if code:
        say(f"run-eval: warning: could not pre-download @playwright/mcp@{version}: {out.strip()[:200]}", sys.stderr)


def results_path(out_dir, date, engine, model):
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", model).strip("-") or "default"
    path, n = out_dir / f"{date}-{engine}-{slug}.json", 2
    while path.exists():
        path, n = out_dir / f"{date}-{engine}-{slug}-{n}.json", n + 1
    return path


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="Offline evaluation of the triage agent.")
    parser.add_argument("--engine", choices=("claude", "opencode"), default=os.environ.get("ENGINE") or "claude")
    parser.add_argument("--model", help="opencode: provider/model; claude: sets ANTHROPIC_MODEL")
    parser.add_argument("--repeats", type=int, default=1, help="runs per case (more than 1 measures consistency)")
    parser.add_argument("--jobs", type=int, default=4, help="cases run in parallel")
    parser.add_argument("--max-turns", type=int, help="override the triage turn budget from test-and-heal.yml")
    parser.add_argument("--timeout", type=int, default=1200, help="seconds before one run is stopped")
    parser.add_argument("--cases", type=Path, default=EVAL_DIR / "cases.jsonl")
    parser.add_argument("--only", help="comma-separated case ids to run")
    parser.add_argument("--out", type=Path, default=EVAL_DIR / "results", help="directory for the result file")
    parser.add_argument("--work-dir", type=Path, help="where workspaces and logs go (default: a new temp dir)")
    parser.add_argument("--keep", action="store_true", help="keep the workspaces")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate cases and prompt only; no agent, no API calls")
    mode.add_argument("--dry-run", action="store_true", help="build the workspaces, but don't run the agent")
    opts = parser.parse_args()
    if opts.repeats < 1 or opts.jobs < 1 or opts.timeout < 1:
        parser.error("--repeats, --jobs and --timeout must be positive")
    if opts.engine == "opencode":
        opts.model = opts.model or os.environ.get("OPENCODE_MODEL") or "deepseek/deepseek-flash"
    else:
        opts.model = opts.model or os.environ.get("ANTHROPIC_MODEL") or ""

    try:
        step = triage_step()
        if opts.max_turns:
            step["max_turns"] = opts.max_turns
        cases, errors = load_cases(opts.cases)
        if opts.only:
            wanted = {part.strip() for part in opts.only.split(",") if part.strip()}
            unknown = wanted - {case["id"] for case in cases}
            errors += [f"--only: no case {name!r}" for name in sorted(unknown)]
            cases = [case for case in cases if case["id"] in wanted]
        for error in errors:
            say(f"run-eval: {opts.cases.name}: {error}", sys.stderr)
        if errors:
            return 1
        for warning in fixture_warnings(cases):
            say(f"run-eval: warning: {warning}", sys.stderr)
        labels = Counter(case["expected"] for case in cases)
        if opts.check:
            say(f"run-eval: {len(cases)} cases OK ({', '.join(f'{n} {label}' for label, n in labels.most_common())}); "
                f"prompt and {step['max_turns']}-turn budget read from {WORKFLOW.name}.")
            return 0

        version = "" if opts.dry_run else engine_version(opts.engine)
        work_dir = opts.work_dir or Path(tempfile.mkdtemp(prefix="triage-eval-"))
        (work_dir / "workspaces").mkdir(parents=True, exist_ok=True)
        (work_dir / "logs").mkdir(parents=True, exist_ok=True)
        repeats = 1 if opts.dry_run else opts.repeats
        jobs = [(case, repeat) for repeat in range(1, repeats + 1) for case in cases]
        if not opts.dry_run:
            warm_up_mcp()
        say(f"run-eval: {len(cases)} cases {TIMES} {repeats} run(s), {opts.jobs} at a time, engine {opts.engine} "
            f"{opts.model or 'default'}; logs in {work_dir / 'logs'}")
        trials, done = [], 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=opts.jobs) as pool:
            futures = {pool.submit(run_trial, case, repeat, opts, step, work_dir): (case, repeat) for case, repeat in jobs}
            for future in concurrent.futures.as_completed(futures):
                case, repeat = futures[future]
                try:
                    trial = future.result()
                except EvalError:
                    pool.shutdown(wait=False, cancel_futures=True)
                    raise
                done += 1
                trials.append(trial)
                outcome = "workspace OK" if opts.dry_run else (
                    f"expected {trial['expected']}, got {trial['got']}"
                    + ("" if trial["got"] == trial["expected"] else "  <- wrong")
                    + (f" ({trial['error']})" if trial["error"] else ""))
                say(f"[{done}/{len(jobs)}] {case['id']} run {repeat}: {outcome} ({trial['seconds']}s)")
        if opts.dry_run:
            say(f"run-eval: dry run OK: {len(trials)} workspaces built, each with exactly its failure in "
                "results/failures.json; the agent was not run.")
            return 0
    except EvalError as exc:
        say(f"run-eval: {exc}", sys.stderr)
        return 1

    order = {case["id"]: n for n, case in enumerate(cases)}
    trials.sort(key=lambda t: (order[t["case"]], t["repeat"]))
    today = datetime.datetime.now(datetime.timezone.utc)
    blob = git_info("hash-object", TRIAGE_AGENT)
    meta = {
        "date": today.strftime("%Y-%m-%d"),
        "finished_at": today.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "engine": opts.engine,
        "engine_version": version,
        "model": opts.model or "default",
        "repeats": opts.repeats,
        "max_turns": step["max_turns"],
        "prompt": step["prompt"],
        "platform_commit": git_info("rev-parse", "HEAD"),
        "triage_md": {"path": TRIAGE_AGENT, "blob": blob, "commit": git_info("log", "-1", "--format=%H", "--", TRIAGE_AGENT),
                      "modified": bool(git_info("status", "--porcelain", "--", TRIAGE_AGENT))},
        "agent_rules_blob": git_info("hash-object", "AGENT-RULES.md"),
        "cases": {"file": relative(opts.cases), "count": len(cases),
                  "sha256": hashlib.sha256(opts.cases.read_bytes()).hexdigest()},
    }
    summary = score(trials, opts.repeats)
    out = results_path(opts.out, meta["date"], opts.engine, meta["model"])
    write(out, json.dumps({"meta": meta, "summary": summary, "trials": trials}, indent=2, ensure_ascii=False) + "\n")
    text = report(meta, summary, trials)
    say("")
    say(text)
    say(f"run-eval: results written to {out}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8", newline="\n") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
