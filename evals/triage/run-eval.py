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
from test-and-heal.yml, and its classification in results/triage.json is compared with the case's label.

The answer key is kept away from the agent:
- No file that goes into a workspace may give an answer away (a case's "why", or its test name near a label) or
  mention cases.jsonl or evals/; otherwise the eval doesn't run. --check checks this too.
- With --hide-answers, the default when CI is set, the cases and the sample project are read into memory; then all
  of evals/ (the cases, the result files, the docs, the project and this script), the cases file if it is
  elsewhere, every other file in this checkout that gives an answer away, and .git (its history holds them all) are
  deleted before the first agent starts. This is meant for throwaway CI checkouts: except in the checkout of a
  GitHub Actions job, it refuses while .git holds work that is on no remote.
- When the agent writes no results/triage.json, the report says why, from the run's log and workspace: the turn
  limit, the eval's --timeout, an engine error, a rejected permission, a file in the wrong place, or else the
  agent's last message. opencode's database is created once before the parallel runs, which would otherwise race
  to create it and fail at startup.
- The engine writes a full transcript to the run's log: its JSON event stream, with every tool call and result. A
  run whose transcript mentions cases.jsonl, evals/ or this checkout's path, or quotes a case's "why", is INVALID:
  reported, but not scored.

Usage:
  python3 evals/triage/run-eval.py [--engine claude|opencode] [--model M] [--repeats N] [--jobs N] [--only IDS]
  python3 evals/triage/run-eval.py --check      validate the cases and the CI prompt; no agent, no API calls
  python3 evals/triage/run-eval.py --dry-run    also build every workspace, without running the agent

--model is provider/model for opencode (default $OPENCODE_MODEL, then deepseek/deepseek-flash). For claude it sets
ANTHROPIC_MODEL; without it Claude Code uses its default model, recorded as "default".

Writes evals/triage/results/<date>-<engine>-<model>.json and prints a markdown report, which is also appended to
$GITHUB_STEP_SUMMARY. Exit code: 0 once the eval ran, whatever the score; 1 if the cases, the CI prompt or a
workspace are broken, or the answer key can't be hidden; 2 for a usage error.
"""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import shlex
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
EVALS = ROOT / "evals"
EVAL_DIR = EVALS / "triage"
PROJECT = EVAL_DIR / "project"
CASES = EVAL_DIR / "cases.jsonl"
RESULTS = EVAL_DIR / "results"
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
DOT, TIMES, NONE, ELLIPSIS = "\N{MIDDLE DOT}", "\N{MULTIPLICATION SIGN}", "\N{EM DASH}", "\N{HORIZONTAL ELLIPSIS}"
MARKDOWN = re.compile(r"([\\`*_\[\]<>|~&$])")
TEST_CALL = re.compile(r"""^(\s*)test(?:\.\w+)?\(\s*(['"`])(.*?)\2""")
LOCATOR = re.compile(r"(?:getBy\w+|locator|frameLocator)\((?:[^()]|\([^()]*\))*\)")
MATCHER = re.compile(r"\.(to\w+)\(")
ACTION = re.compile(r"\b(?:locator|page|frame)\.(\w+)")
LABEL = re.compile(r"\b(?:" + "|".join(LABELS) + r")\b")
NEAR = 3       # a test name this many lines from a label gives its answer away (a result file's records span lines)
MIN_WHY = 20   # a shorter "why" can't give an answer away by itself, and would match by chance
POINTERS = (("cases.jsonl", r"cases\.jsonl"), ("evals/", r"evals[/\\]"))  # where the answer key lives
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
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


def load_cases(text):
    cases, errors, seen = [], [], set()
    for n, line in enumerate(text.splitlines(), 1):
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


def read_cases(path):
    """The cases file's bytes, its cases and its errors, read once: --hide-answers deletes the file afterwards."""
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8-sig")
    except OSError as exc:
        return b"", [], [f"can't read it: {exc.strerror or exc}"]
    except UnicodeDecodeError:
        return b"", [], ["not UTF-8"]
    return (raw, *load_cases(text))


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


def inside(path, folder):
    try:
        Path(path).resolve().relative_to(Path(folder).resolve())
        return True
    except ValueError:
        return False


def read_any(path):
    return path.read_bytes().decode("utf-8", "replace")


def workspace_inputs():
    """This repository's files that go into every workspace: the sample project and the platform parts."""
    files = []
    for source in (PROJECT, *(ROOT / part for part in PLATFORM_PARTS)):
        files += sorted(p for p in source.rglob("*") if p.is_file()) if source.is_dir() else [source]
    return files


def giveaways(text, cases):
    """The cases whose answer text gives away, with how: their "why", or their test name near a label."""
    flat = " ".join(text.split())
    lines = text.splitlines()
    labelled = [n for n, line in enumerate(lines) if LABEL.search(line)]
    found = []
    for case in cases:
        why = " ".join(case["why"].split())
        title = case["name"].split(f" {SEP} ")[-1].strip()
        if len(why) >= MIN_WHY and why in flat:
            found.append((case["id"], "its why"))
        elif labelled and title:
            near = next((n for n, line in enumerate(lines)
                         if title in line and any(abs(n - m) <= NEAR for m in labelled)), None)
            if near is not None:
                found.append((case["id"], f"its test name near a label, line {near + 1}"))
    return found


def workspace_leaks(cases):
    """Errors for the files that go into every workspace and give an answer away, which no deletion can hide, or
    mention where the answer key lives, which would make every run that reads them invalid."""
    errors = []
    for path in workspace_inputs():
        text = read_any(path)
        errors += [f"{relative(path)} gives away {case_id}'s answer ({how}), and it goes into every workspace"
                   for case_id, how in giveaways(text, cases)]
        errors += [f"{relative(path)} mentions {name}, so every run that reads it would be invalid"
                   for name, pattern in POINTERS if re.search(pattern, text)]
    return errors


def load_project():
    """The sample project's files and modes, read once: --hide-answers deletes evals/, the project included, before
    the workspaces are built from it."""
    return {path.relative_to(PROJECT).as_posix(): (path.read_bytes(), path.stat().st_mode & 0o777)
            for path in sorted(PROJECT.rglob("*")) if path.is_file()}


def answer_files(cases, cases_file):
    """What --hide-answers deletes, and why: all of evals/ (the cases, the result files, the docs, the sample project
    and this script), the cases file if it is elsewhere, every other file in this checkout that gives an answer
    away, and .git, whose history holds them all."""
    found = {}
    if EVALS.is_dir():
        found[EVALS] = ("the eval: its cases, result files, docs, sample project and this script; the workspaces get "
                        "the project from memory")
    if cases_file.is_file() and not inside(cases_file, EVALS):
        found[cases_file.resolve()] = "the cases"
    keep = {path.resolve() for path in workspace_inputs()}
    for folder, dirs, names in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d != ".git" and Path(folder, d) != EVALS)
        for name in sorted(names):
            path = Path(folder, name)
            resolved = path.resolve()
            if resolved in found or resolved in keep or path.is_symlink() or not path.is_file():
                continue
            hits = giveaways(read_any(path), cases)
            if hits:
                found[resolved] = "; ".join(f"{case_id}: {how}" for case_id, how in hits[:3]) + (
                    f"; {ELLIPSIS}" if len(hits) > 3 else "")
    git_dir = ROOT / ".git"
    if git_dir.exists() or git_dir.is_symlink():
        found[git_dir] = "its history holds every version of these files"
    return found


def display(path):
    return relative(path) + ("/" if path.is_dir() and not path.is_symlink() else "")


def listing(files):
    return "\n".join(f"  {display(path)}  ({why})" for path, why in files.items())


def ci_is_set():
    return os.environ.get("CI", "").strip().lower() not in ("", "0", "false", "no")


def throwaway_checkout():
    """True for the checkout of a GitHub Actions job, which the runner throws away when the job ends."""
    workspace = os.environ.get("GITHUB_WORKSPACE")
    return os.environ.get("GITHUB_ACTIONS") == "true" and bool(workspace) and Path(workspace).resolve() == ROOT


def unsaved_work():
    """What deleting .git would lose: uncommitted changes, commits that are on no remote, stashed changes."""
    if not (ROOT / ".git").exists():
        return []
    lost = []
    for what, args in (("uncommitted changes", ("status", "--porcelain")),
                       ("commits that are on no remote", ("rev-list", "-n", "1", "HEAD", "--branches", "--not",
                                                          "--remotes")),
                       ("stashed changes", ("stash", "list"))):
        code, out = run(["git", *args], ROOT)
        if code:
            lost.append(f"work git can't check (git {args[0]} failed)")
        elif out.strip():
            lost.append(what)
    return lost


def hide_answers(cases, cases_file):
    """Delete the answer key (see answer_files) before the first agent starts; the cases and the sample project are
    in memory by now. Returns the deleted paths as shown, and their listing."""
    lost = [] if throwaway_checkout() else unsaved_work()
    if lost:
        raise EvalError(f"--hide-answers would delete .git, which holds {' and '.join(lost)}. It is meant for "
                        "throwaway CI checkouts: run with CI unset or with --no-hide-answers, or commit and push first.")
    files = answer_files(cases, cases_file)
    names, text = [display(path) for path in files], listing(files)
    for path in files:
        if path.is_dir() and not path.is_symlink():
            remove(path)
        else:
            path.unlink()
    return names, text


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


def build_workspace(case, ws, project, engine, model, log):
    """The workspace of a failed CI run with this one failure; returns its entry in results/failures.json."""
    ws.mkdir(parents=True)
    for name, (data, mode) in project.items():
        target = ws / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(mode)
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


def transcript_wrapper(work_dir, engine):
    """A bin directory whose <engine> runs the real one with its full transcript on stdout: the engine's JSON event
    stream, with every tool call and result, so the leak check sees what the agent did and not only its answer.
    Claude Code also stops saving the session to its config directory, where a later run could read it (OpenCode
    gets a data directory of its own per run instead). run-agent.sh and what the agent can do stay the same."""
    code, out = run([BASH, "-c", f"command -v {engine}"], ROOT)
    real = out.strip().splitlines()[-1] if code == 0 and out.strip() else ""
    if not real:
        raise EvalError(f"can't find the {engine} CLI on PATH")
    real = shlex.quote(real)
    if engine == "claude":
        body = f'exec {real} "$@" --output-format stream-json --verbose --no-session-persistence\n'
    else:
        body = f'if [ "${{1:-}}" = run ]; then exec {real} "$@" --format json; fi\nexec {real} "$@"\n'
    wrapper = work_dir / "bin" / engine
    write(wrapper, "#!/usr/bin/env bash\n# Written by run-eval.py: the real engine, with its full transcript in the "
                   "run's log.\n" + body)
    wrapper.chmod(0o755)
    return wrapper.parent


def path_pattern(path):
    """A regex for path as a log can show it: / or \\ (also JSON-escaped) between its parts, and on Windows also
    bash's /c/… form."""
    posix = Path(path).as_posix()
    forms = [posix]
    if re.match(r"[A-Za-z]:/", posix):
        forms.append(f"/{posix[0]}{posix[2:]}")
    return "|".join(r"[/\\]+".join(re.escape(part) for part in form.split("/")) for form in forms)


def and_list(items):
    return ", ".join(items[:-1]) + " and " + items[-1] if len(items) > 1 else "".join(items)


def log_leak(output, run_dir, work_dir, cases):
    """Why an agent's log shows it went for the answer key, with where: (reason, context), or ("", "") if it didn't.
    It did if the log mentions where the key lives, or quotes a case's "why" (in a JSON event stream, escaped), or
    mentions the eval's work folder, which holds the other runs. The run's own folder (run_dir: its workspace, log
    and engine data) is cut first."""
    flags = re.I if os.name == "nt" else 0
    text = re.sub(path_pattern(run_dir), "<this run>", output, flags=flags)
    places = (*POINTERS, ("the checkout's path", path_pattern(ROOT)),
              ("the eval's work folder (other runs)", path_pattern(work_dir)))
    found = [(name, text, m) for name, pattern in places if (m := re.search(pattern, text, flags))]
    plain = " ".join(re.sub(r"\\[nrt]", " ", text).replace('\\"', '"').replace("\\\\", "\\").split())
    quoted = [(case["id"], m) for case in cases if len(why := " ".join(case["why"].split())) >= MIN_WHY
              and (m := re.search(re.escape(why), plain))]
    if not found and not quoted:
        return "", ""
    reasons = [f"mentions {and_list([name for name, *_ in found])}"] if found else []
    if quoted:
        reasons.append(f"quotes the answer key (the why of {and_list([case_id for case_id, _ in quoted])})")
    source, m = (found[0][1], found[0][2]) if found else (plain, quoted[0][1])
    context = " ".join(source[max(0, m.start() - 80):m.end() + 80].split())
    return f"the log {' and '.join(reasons)}", f"{ELLIPSIS}{context}{ELLIPSIS}"


def dig(value, *keys):
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def transcript(out):
    """The engine's JSON events and its other output lines, without ANSI colours."""
    events, lines = [], []
    for line in ANSI.sub("", out).splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                event = json.loads(line)
            except ValueError:
                event = None
            if isinstance(event, dict):
                events.append(event)
                continue
        if line:
            lines.append(line)
    return events, lines


def write_attempts(events):
    """(path, error) for each file the agent tried to write or edit: opencode's and Claude Code's tool calls."""
    attempts = []
    for event in events:
        if dig(event, "part", "tool") in ("write", "edit"):
            failed = dig(event, "part", "state", "status") == "error"
            attempts.append((str(dig(event, "part", "state", "input", "filePath") or ""),
                             str(dig(event, "part", "state", "error") or "") if failed else ""))
        content = dig(event, "message", "content")
        for item in content if event.get("type") == "assistant" and isinstance(content, list) else []:
            if dig(item, "type") == "tool_use" and dig(item, "name") in ("Write", "Edit"):
                attempts.append((str(dig(item, "input", "file_path") or ""), ""))
    return attempts


def last_message(events, lines):
    """The agent's last text: from the JSON events, or the engine's plain output if there are none."""
    texts = [str(dig(event, "part", "text")) for event in events if event.get("type") == "text"
             and dig(event, "part", "text")]
    for event in events:
        content = dig(event, "message", "content")
        if event.get("type") == "assistant" and isinstance(content, list):
            texts += [str(item["text"]) for item in content if dig(item, "type") == "text" and dig(item, "text")]
    if not events:
        texts = [line for line in lines if not line.startswith("::")]
    return " ".join(texts[-1].split()) if texts else ""


def missing_output(out, code, ws, step, opts):
    """Why the agent wrote no output file, from run-agent.sh's output, the engine's transcript and the workspace:
    the eval's --timeout, the turn limit, an engine error, a rejected permission, a file in the wrong place, or
    else the agent's last message."""
    expected = step["expected_output"]
    name = expected.rsplit("/", 1)[-1]
    events, lines = transcript(out)
    exit_code = next((m.group(1) for line in lines if (m := re.search(r"\(\w+ exit code (\d+)\)", line))), "?")
    if code == 124 and f"[stopped after {opts.timeout}s]" in out:
        return f"the eval stopped the run after {opts.timeout}s (--timeout)"
    limit = re.search(r"opencode reached the \d+s limit that stands in for MAX_TURNS=\d+", out)
    if limit:
        return f"hit the turn limit: {limit.group(0)}"
    if any(event.get("subtype") == "error_max_turns" for event in events) or any(
            "Reached max turns" in line for line in lines):
        return f"hit the turn limit ({step['max_turns']} turns)"
    errors = [str(dig(event, "error", "data", "message") or dig(event, "error", "message") or event.get("error")
                  or "") for event in events if event.get("type") == "error"]
    errors += [str(event.get("result") or event.get("subtype") or "") for event in events
               if event.get("type") == "result" and event.get("is_error")]
    at = next((n for n, line in enumerate(lines) if line.startswith("Error:")), None)
    if at is not None:  # the engine's own error message, e.g. opencode's "Error: Unexpected error" and its cause
        cause = " ".join(line for line in lines[at + 1:at + 4] if not line.startswith("::"))
        errors.append(": ".join(part for part in (lines[at][len("Error:"):].strip(), cause) if part))
    errors = [" ".join(error.split()) for error in errors if error.strip()]
    if errors:
        started = any(event.get("type") in ("step_start", "assistant") for event in events)
        return (f"{opts.engine} failed{'' if started else ' before the agent took a step'} (exit code {exit_code}): "
                f"{errors[0][:160]}")
    rejected = next((m.group(1) for line in lines
                     if (m := re.match(r"! permission requested: (.+?);? auto-rejecting", line))), None)
    if rejected:
        return f"{opts.engine} stopped when it auto-rejected a permission request: {rejected}"
    elsewhere = sorted(path.relative_to(ws).as_posix() for path in ws.rglob(name)
                       if path.is_file() and "node_modules" not in path.parts)
    if elsewhere:
        return f"wrote {elsewhere[0]} instead of {expected}"
    for path, error in write_attempts(events):
        if path.replace("\\", "/").rsplit("/", 1)[-1] == name:
            if not path.replace("\\", "/").endswith(expected):
                return f"tried to write {path} instead of {expected}"
            if error:
                return f"writing {expected} failed: {' '.join(error.split())[:160]}"
    last = last_message(events, lines)
    return (f"the agent stopped without writing it ({opts.engine} exit code {exit_code})"
            + (f'; its last message: "{last[:160]}"' if last else ""))


def read_verdict(path, failure):
    """The agent's classification and reason for the failure, or an error saying why there is none."""
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


def opencode_auth():
    """OpenCode's stored login (`opencode auth login`), which a run's own data directory needs a copy of."""
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return data / "opencode" / "auth.json"


def run_trial(case, repeat, opts, step, work_dir, bin_dir, project, answer_key):
    """One run of one case, in its own folder trials/<id>-r<n>/: the agent's workspace, and outside it the run's log
    (agent.log), its temp directory and, for OpenCode, its data directory (sessions, snapshots, logs, long tool
    output). Its result.json, which holds the expected label, is written there only after every agent is done (see
    main). When the run is over its folder is locked (see lock), so no later run can read it; repeats of one case
    never run at the same time."""
    run_dir = work_dir / "trials" / f"{case['id']}-r{repeat}"
    ws = run_dir / "workspace"
    if run_dir.exists():
        raise EvalError(f"{run_dir} already exists: give --work-dir an empty or new directory")
    run_dir.mkdir(parents=True)
    os.chmod(run_dir, 0o700)
    trial = {"case": case["id"], "test": case["name"], "repeat": repeat, "expected": case["expected"], "got": "none",
             "reason": "", "exit_code": None, "seconds": 0.0, "error": "", "invalid": "", "invalid_context": ""}
    started = time.monotonic()
    login = None
    try:
        with open(run_dir / "agent.log", "w", encoding="utf-8", newline="\n") as log:
            failure = build_workspace(case, ws, project, opts.engine, opts.model, log)
            if opts.dry_run:
                trial["got"] = "dry-run"
            else:
                tmp = run_dir / "tmp"
                tmp.mkdir()
                env = {**os.environ, "ENGINE": opts.engine, "AGENT": "triage", "PROMPT": step["prompt"],
                       "MAX_TURNS": str(step["max_turns"]), "EXPECTED_OUTPUT": step["expected_output"],
                       "PLATFORM_DIR": ".agentic-qa", "MCP_SERVER": "browser", "MCP_TIMEOUT": "60000",
                       "FRAMEWORK": FRAMEWORK, "TEST_DIR": TEST_DIR, "APP_URL": "",
                       "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",  # the engine with a full transcript
                       "TMPDIR": str(tmp), "TMP": str(tmp), "TEMP": str(tmp)}
                for name in ("PWD", "OLDPWD"):  # they name this checkout; bash sets PWD to the workspace
                    env.pop(name, None)
                if "GITHUB_WORKSPACE" in env:
                    env["GITHUB_WORKSPACE"] = str(ws)  # in CI it is the agent's own repository, not the platform's
                if opts.engine == "opencode":
                    env.update(OPENCODE_MODEL=opts.model, XDG_DATA_HOME=str(run_dir / "engine-data"),
                               XDG_STATE_HOME=str(run_dir / "engine-state"))
                    if opencode_auth().is_file():
                        login = run_dir / "engine-data" / "opencode" / "auth.json"
                        login.parent.mkdir(parents=True)
                        shutil.copy2(opencode_auth(), login)
                elif opts.model:
                    env["ANTHROPIC_MODEL"] = opts.model
                code, out = run([BASH, ".agentic-qa/scripts/run-agent.sh"], ws, env=env, timeout=opts.timeout,
                                log=log)
                trial["exit_code"] = code
                output = ws / step["expected_output"]
                if output.is_file():
                    trial.update(read_verdict(output, failure))
                else:
                    trial["error"] = f"no {output.name}: {missing_output(out, code, ws, step, opts)}"
                trial["invalid"], trial["invalid_context"] = log_leak(out, run_dir, work_dir, answer_key)
        trial["seconds"] = round(time.monotonic() - started, 1)
        if not opts.keep:
            remove(ws)
    finally:
        if login is not None:
            login.unlink(missing_ok=True)  # the copied login doesn't stay in the run's folder
        lock(run_dir)
    return trial


def lock(run_dir):
    """Lock a finished run's folder (mode 000) until the eval ends: the agents can't read it, and they can't run
    chmod. On Windows a folder's mode doesn't stop reads; there the engines' own rules are the only barrier."""
    os.chmod(run_dir, 0)


def unlock(work_dir):
    for run_dir in sorted((work_dir / "trials").glob("*")):
        os.chmod(run_dir, 0o700)


def score(trials, repeats):
    """The scores over the valid runs: an invalid run, whose log points at the answer key, isn't scored."""
    valid = [t for t in trials if not t["invalid"]]
    columns = (*LABELS, "none")
    correct = sum(t["got"] == t["expected"] for t in valid)
    per_label = {label: {"correct": sum(t["got"] == label for t in valid if t["expected"] == label),
                         "total": sum(t["expected"] == label for t in valid)} for label in LABELS}
    confusion = {expected: {got: sum(t["expected"] == expected and t["got"] == got for t in valid) for got in columns}
                 for expected in LABELS}
    by_case = {}
    for trial in valid:
        by_case.setdefault(trial["case"], []).append(trial)
    agreement = {case: Counter(t["got"] for t in runs).most_common(1)[0][1] / len(runs) for case, runs in by_case.items()}
    return {
        "trials": len(trials),
        "invalid": len(trials) - len(valid),
        "scored": len(valid),
        "correct": correct,
        "accuracy": round(correct / len(valid), 4) if valid else 0.0,
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
        text = text[:limit - 1].rstrip() + ELLIPSIS
    return MARKDOWN.sub(r"\\\1", text)


def ratio(part, whole):
    return f"{part}/{whole} ({100 * part / whole:.0f}%)" if whole else f"0/0 ({NONE})"


def report(meta, summary, trials):
    s, c = summary, summary["consistency"]
    lines = [f"## Triage eval: {meta['engine']} {DOT} {meta['model']}", "",
             f"{meta['cases']['count']} cases {TIMES} {meta['repeats']} run(s) {DOT} engine `{meta['engine_version']}` "
             f"{DOT} triage.md `{meta['triage_md']['blob'][:7]}`{' (modified)' if meta['triage_md']['modified'] else ''} "
             f"{DOT} platform `{meta['platform_commit'][:7]}` {DOT} {meta['date']}", ""]
    if meta["deleted_before_agents"]:
        lines += ["Answer key deleted from the checkout before the first agent started: "
                  + ", ".join(f"`{path}`" for path in meta["deleted_before_agents"]) + ".", ""]
    lines.append(f"**Accuracy** {ratio(s['correct'], s['scored'])} {DOT} "
                 f"**Critical: REAL_BUG classified as SELECTOR_DRIFT** {s['critical_real_bug_as_selector_drift']} "
                 f"{DOT} **Invalid runs** {s['invalid']}" + (" (not scored)" if s["invalid"] else ""))
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
    invalid = [t for t in trials if t["invalid"]]
    if invalid:
        lines += ["", f"### Invalid runs ({len(invalid)} of {s['trials']})", "",
                  "Not scored: the agent's log mentions where the answer key lives (cases.jsonl, evals/ or the "
                  "checkout's path).", "",
                  "| Case | Run | Got | Why invalid |", "| --- | --- | --- | --- |"]
        lines += [f"| {md(t['case'])} | {t['repeat']} | {t['got']} | {md(t['invalid'] + ': ' + t['invalid_context'])} |"
                  for t in invalid]
    by_case = {}
    for trial in trials:
        if not trial["invalid"]:
            by_case.setdefault(trial["case"], []).append(trial)
    wrong = {case: runs for case, runs in by_case.items() if any(t["got"] != t["expected"] for t in runs)}
    lines += ["", f"### Wrong answers ({len(wrong)} of {len(by_case)} cases)", ""]
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
    parser.add_argument("--cases", type=Path, default=CASES)
    parser.add_argument("--only", help="comma-separated case ids to run")
    parser.add_argument("--out", type=Path, default=RESULTS, help="directory for the result file")
    parser.add_argument("--work-dir", type=Path, help="where workspaces and logs go (default: a new temp dir)")
    parser.add_argument("--keep", action="store_true", help="keep the workspaces")
    parser.add_argument("--hide-answers", action=argparse.BooleanOptionalAction, default=None,
                        help="delete the answer key from this checkout, .git included, before the first agent "
                             "starts (default: on when CI is set)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate cases and prompt only; no agent, no API calls")
    mode.add_argument("--dry-run", action="store_true", help="build the workspaces, but don't run the agent")
    opts = parser.parse_args()
    if opts.repeats < 1 or opts.jobs < 1 or opts.timeout < 1:
        parser.error("--repeats, --jobs and --timeout must be positive")
    if opts.work_dir and (inside(opts.work_dir, ROOT) or inside(ROOT, opts.work_dir)):
        parser.error("--work-dir must be outside this repository: from a workspace in it, an agent could reach the "
                     "answer key")
    if opts.engine == "opencode":
        opts.model = opts.model or os.environ.get("OPENCODE_MODEL") or "deepseek/deepseek-flash"
    else:
        opts.model = opts.model or os.environ.get("ANTHROPIC_MODEL") or ""

    try:
        step = triage_step()
        if opts.max_turns:
            step["max_turns"] = opts.max_turns
        raw, all_cases, errors = read_cases(opts.cases)
        errors = [f"{opts.cases.name}: {error}" for error in errors]
        cases = all_cases
        if opts.only:
            wanted = {part.strip() for part in opts.only.split(",") if part.strip()}
            unknown = wanted - {case["id"] for case in cases}
            errors += [f"--only: no case {name!r}" for name in sorted(unknown)]
            cases = [case for case in cases if case["id"] in wanted]
        errors += workspace_leaks(all_cases)
        for error in errors:
            say(f"run-eval: {error}", sys.stderr)
        if errors:
            return 1
        for warning in fixture_warnings(cases):
            say(f"run-eval: warning: {warning}", sys.stderr)
        labels = Counter(case["expected"] for case in cases)
        if opts.check:
            say(f"run-eval: {len(cases)} cases OK ({', '.join(f'{n} {label}' for label, n in labels.most_common())}); "
                f"prompt and {step['max_turns']}-turn budget read from {WORKFLOW.name}.")
            say("run-eval: no file that goes into a workspace gives an answer away. With --hide-answers (the default "
                "when CI is set) these are deleted before the first agent starts:\n"
                + listing(answer_files(all_cases, opts.cases)))
            return 0

        hide = not opts.dry_run and (ci_is_set() if opts.hide_answers is None else opts.hide_answers)
        facts = {  # read now, while .git is there
            "platform_commit": git_info("rev-parse", "HEAD"),
            "triage_md": {"path": TRIAGE_AGENT, "blob": git_info("hash-object", TRIAGE_AGENT),
                          "commit": git_info("log", "-1", "--format=%H", "--", TRIAGE_AGENT),
                          "modified": bool(git_info("status", "--porcelain", "--", TRIAGE_AGENT))},
            "agent_rules_blob": git_info("hash-object", "AGENT-RULES.md"),
            "cases": {"file": relative(opts.cases), "count": len(cases), "sha256": hashlib.sha256(raw).hexdigest()},
        }
        project = load_project()
        version = "" if opts.dry_run else engine_version(opts.engine)
        work_dir = (opts.work_dir or Path(tempfile.mkdtemp(prefix="triage-eval-"))).resolve()
        (work_dir / "trials").mkdir(parents=True, exist_ok=True)
        bin_dir = None if opts.dry_run else transcript_wrapper(work_dir, opts.engine)
        repeats = 1 if opts.dry_run else opts.repeats
        total = len(cases) * repeats
        if not opts.dry_run:
            warm_up_mcp()
        hidden = []
        if hide:
            hidden, text = hide_answers(all_cases, opts.cases)
            say("run-eval: answer key hidden: deleted before the first agent starts:\n" + text)
        say(f"run-eval: {len(cases)} cases {TIMES} {repeats} run(s), {opts.jobs} at a time, engine {opts.engine} "
            f"{opts.model or 'default'}; each run's folder is in {work_dir / 'trials'}")
        trials, collected, stop = [], threading.Lock(), threading.Event()

        def finished(trial):
            with collected:
                trials.append(trial)
                done = len(trials)
            if opts.dry_run:
                outcome = "workspace OK"
            elif hide:  # no labels in the job's log, which is on this machine, while other agents still run
                outcome = f"got {trial['got']}"
            else:
                outcome = (f"expected {trial['expected']}, got {trial['got']}"
                           + ("" if trial["got"] == trial["expected"] else "  <- wrong"))
            outcome += (f" ({trial['error']})" if trial["error"] else "") + (
                f"  INVALID: {trial['invalid']}" if trial["invalid"] else "")
            say(f"[{done}/{total}] {trial['case']} run {trial['repeat']}: {outcome} ({trial['seconds']}s)")

        def case_runs(case):
            # A case's runs follow one another, never overlapping, so no run can watch another run of its case;
            # a finished run's folder is locked. Different cases run in parallel.
            for repeat in range(1, repeats + 1):
                if stop.is_set():
                    return
                finished(run_trial(case, repeat, opts, step, work_dir, bin_dir, project, all_cases))

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=opts.jobs) as pool:
                futures = [pool.submit(case_runs, case) for case in cases]
                for future in concurrent.futures.as_completed(futures):
                    try:
                        future.result()
                    except EvalError:
                        stop.set()
                        pool.shutdown(wait=False, cancel_futures=True)
                        raise
        finally:
            unlock(work_dir)
        for trial in trials:  # each run's record, labels included: only now that no agent is running
            write(work_dir / "trials" / f"{trial['case']}-r{trial['repeat']}" / "result.json",
                  json.dumps(trial, indent=2, ensure_ascii=False) + "\n")
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
    meta = {
        "date": today.strftime("%Y-%m-%d"),
        "finished_at": today.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "engine": opts.engine,
        "engine_version": version,
        "model": opts.model or "default",
        "repeats": opts.repeats,
        "max_turns": step["max_turns"],
        "prompt": step["prompt"],
        **facts,
        "deleted_before_agents": hidden,
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
