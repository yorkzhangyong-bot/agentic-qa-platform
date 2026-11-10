#!/usr/bin/env python3
"""check.py — test the agent permissions on a real agent engine, with a fake model in place of the API.

For each case, fake_model.py asks the agent to run one shell command, or to write one file. The agent runs through
scripts/run-agent.sh in a workspace staged by scripts/stage-agents.sh, as in CI, so the engine enforces exactly the
permissions a CI run gets. A case that must be denied passes when the engine refused it and it left no trace: the
canary (an environment variable only that command would print) shows up nowhere, and no file was written. A case
that must work passes when it ran.

No real model is called and no key is needed. The engine gets its own configuration and data directories, so your
own settings, logins and plugins take no part, and no environment variable that looks like a secret reaches it.
The browser MCP server is switched off, and opencode's turn limit and Claude Code's -p run are kept short.

Usage: python3 tests/engine-permissions/check.py claude|opencode WORK_DIR
Prints one tab-separated line per case, "ok|FAIL <TAB> engine expectation command <TAB> detail", and exits 0 if
every case passed, 1 if one failed, 3 if the engine CLI isn't installed.
"""

import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAKE_MODEL = Path(__file__).with_name("fake_model.py")
PLATFORM_PARTS = ("AGENT-RULES.md", "agents", "frameworks", "scripts", "settings")
BASH = shutil.which("bash") or "bash"
# Nothing that looks like a credential, and no engine or CI setting of the machine running the test.
HIDDEN = re.compile(r"KEY|TOKEN|SECRET|PASSW|CREDENTIAL|AUTH|COOKIE|SESSION|PRIVATE|ANTHROPIC|CLAUDE|OPENCODE|"
                    r"OPENAI|DEEPSEEK|OPENROUTER|GITHUB|^GH_|^ACTIONS_|^RUNNER_|AWS|AZURE|GOOGLE|NPM_CONFIG|^XDG_|"
                    r"^CI$", re.I)
FAKE_KEY = "sk-ant-api03-" + "permission-test-key-not-real-".ljust(93, "0") + "AA"
SHIM = "PLAYWRIGHT-STUB-RAN"

BOTH = ("claude", "opencode")
# (command, expected, what shows that it ran, engines). "{canary}" stands for the run's canary; "file:<path>" for a
# file in the workspace; "write:<path>" asks for the write tool instead of the shell.
CASES = [
    ("ls && env", "denied", "{canary}", BOTH),
    ("ls; env", "denied", "{canary}", BOTH),
    ("ls | env", "denied", "{canary}", BOTH),
    ("echo $(env)", "denied", "{canary}", BOTH),
    ("ls\nenv", "denied", "{canary}", BOTH),
    ("echo `env`", "denied", "{canary}", BOTH),
    ("ls $PERMTEST_CANARY", "denied", "{canary}", BOTH),
    ("ls > leak.txt", "denied", "file:leak.txt", BOTH),
    ("npx playwright test x.spec.ts > leak.txt", "denied", "file:leak.txt", BOTH),
    ('npx playwright test x.spec.ts --grep "a|b"', "denied", SHIM, BOTH),
    ("npx playwright test x.spec.ts", "allowed", f"{SHIM} test x.spec.ts", BOTH),
    ("git status", "allowed", "branch", BOTH),
    ("write:results/triage.json", "allowed", "file:results/triage.json", BOTH),
    ("write:src/app.js", "denied", "file:src/app.js", ("opencode",)),  # Claude Code's edits aren't limited by path
]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def check_run(cmd, **kwargs):
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", **kwargs)
    if proc.returncode:
        sys.exit(f"check: {' '.join(map(str, cmd))} failed: {(proc.stdout + proc.stderr).strip()[:400]}")
    return proc.stdout


def workspace(work, engine, base_env):
    """A git repository with one Playwright test, a stub `playwright` for npx, and the platform staged for engine."""
    ws = work / "workspace"
    write(ws / "tests" / "x.spec.ts", "import { test } from '@playwright/test';\n\ntest('x', async () => {});\n")
    write(ws / "package.json", '{"name": "permission-test", "private": true}\n')
    write(ws / "results" / "failures.json", "[]\n")
    shim = ws / "node_modules" / ".bin" / "playwright"
    write(shim, f'#!/usr/bin/env bash\necho "{SHIM} $*"\n')
    shim.chmod(0o755)
    write(shim.with_suffix(".cmd"), '@ECHO off\r\nbash "%~dp0playwright" %*\r\n')  # how npx runs it on Windows
    for part in PLATFORM_PARTS:
        source, target = ROOT / part, ws / ".agentic-qa" / part
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    git = dict(base_env, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@example.com")
    check_run(["git", "init", "-q"], cwd=ws, env=git)
    check_run(["git", "add", "-A"], cwd=ws, env=git)
    check_run(["git", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "tests"], cwd=ws, env=git)
    check_run([BASH, ".agentic-qa/scripts/stage-agents.sh"], cwd=ws,
              env=dict(base_env, ENGINE=engine, FRAMEWORK="playwright", TEST_DIR="tests", PLATFORM_DIR=".agentic-qa",
                       SKIP_MCP_WARMUP="1"))
    return ws


def opencode_wrapper(work, base_env):
    """bin/opencode: the real one with --format json, so the log has each tool call's state (completed or error)."""
    real = check_run([BASH, "-c", "command -v opencode"], env=base_env).strip().splitlines()[-1]
    wrapper = work / "bin" / "opencode"
    write(wrapper, "#!/usr/bin/env bash\n"
                   f'if [ "${{1:-}}" = run ]; then exec {shlex.quote(real)} "$@" --format json; fi\n'
                   f'exec {shlex.quote(real)} "$@"\n')
    wrapper.chmod(0o755)
    return wrapper.parent


def engine_env(engine, work, ws, base_env, port, canary, bin_dir):
    env = dict(base_env, ENGINE=engine, AGENT="triage", PROMPT="Run the command you were given.", MAX_TURNS="4",
               PLATFORM_DIR=".agentic-qa", PERMTEST_CANARY=canary, CI="true", GITHUB_ACTIONS="true")
    if engine == "claude":
        env.update(MCP_SERVER="none", CLAUDE_CONFIG_DIR=str(work / "claude-config"), ANTHROPIC_API_KEY=FAKE_KEY,
                   ANTHROPIC_BASE_URL=f"http://127.0.0.1:{port}", DISABLE_AUTOUPDATER="1", DISABLE_TELEMETRY="1",
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
        if os.name == "nt":  # Claude Code on Windows offers PowerShell instead of Bash unless it's pointed at Git Bash
            env["CLAUDE_CODE_GIT_BASH_PATH"] = check_run(["cygpath", "-w", BASH], env=base_env).strip()
    else:
        servers = json.loads((ws / "opencode.json").read_text(encoding="utf-8")).get("mcp", {})
        extra = {"provider": {"permtest": {
                     "npm": "@ai-sdk/openai-compatible", "name": "Permission test",
                     "options": {"baseURL": f"http://127.0.0.1:{port}/v1", "apiKey": "permission-test"},
                     "models": {"fake": {"name": "fake", "tool_call": True,
                                         "limit": {"context": 100000, "output": 4096}}}}},
                 "mcp": {name: {"enabled": False} for name in servers}}
        env.update(OPENCODE_MODEL="permtest/fake", OPENCODE_CONFIG_CONTENT=json.dumps(extra),
                   OPENCODE_DISABLE_AUTOUPDATE="1", OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_SECONDS_PER_TURN="30",
                   XDG_CONFIG_HOME=str(work / "xdg-config"), XDG_DATA_HOME=str(work / "xdg-data"),
                   XDG_STATE_HOME=str(work / "xdg-state"),
                   PATH=f"{bin_dir}{os.pathsep}{base_env.get('PATH', '')}")
    return env


def run_case(engine, work, ws, base_env, bin_dir, command, marker):
    """Run one case through the agent; return (tool offered, ran, canary leaked, refusals, engine output)."""
    record, port_file = work / "record.jsonl", work / "port"
    for path in (record, port_file, ws / "leak.txt", *([ws / marker[5:]] if marker.startswith("file:") else [])):
        path.unlink(missing_ok=True)
    canary = "canary-" + secrets.token_hex(6)
    write = command.startswith("write:")
    request = f"write:{ws / command[6:]}" if write else command
    tools = ("Write", "write") if write else ("Bash", "bash")
    server = subprocess.Popen([sys.executable, str(FAKE_MODEL), request, str(record), str(port_file)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if port_file.exists() and port_file.read_text(encoding="utf-8"):
                break
            time.sleep(0.05)
        env = engine_env(engine, work, ws, base_env, port_file.read_text(encoding="utf-8"), canary, bin_dir)
        try:
            proc = subprocess.run([BASH, ".agentic-qa/scripts/run-agent.sh"], cwd=ws, env=env,
                                  stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
            output = (proc.stdout + proc.stderr).decode("utf-8", "replace")
        except subprocess.TimeoutExpired as exc:
            output = ((exc.stdout or b"") + (exc.stderr or b"")).decode("utf-8", "replace") + "\n[timed out]"
    finally:
        server.kill()
        server.wait()
    entries = [json.loads(line) for line in record.read_text(encoding="utf-8").splitlines()] if record.exists() else []
    offered = any(name in tools for entry in entries for name in entry.get("tools") or [])
    results = [entry for entry in entries if "tool_result" in entry]
    texts = [entry["tool_result"] for entry in results]
    refusals = [entry["tool_result"] for entry in results if entry.get("is_error")]
    for line in output.splitlines():  # opencode's JSON events: the tool's state
        try:
            event = json.loads(line)
        except ValueError:
            continue
        part = event.get("part") if isinstance(event, dict) and isinstance(event.get("part"), dict) else {}
        state = part.get("state") if isinstance(part.get("state"), dict) else {}
        if event.get("type") == "tool_use" and part.get("tool") in tools:
            texts.append(str(state.get("output") or state.get("error") or ""))
            if state.get("status") == "error":
                refusals.append(str(state.get("error") or ""))
    marker = marker.replace("{canary}", canary)
    if marker.startswith("file:"):
        ran = (ws / marker[5:]).exists()
    else:
        ran = marker in output or any(marker in text for text in texts)
    leaked = canary in output or any(canary in text for text in texts)
    return offered, ran, leaked, refusals, output


def main():
    engine, work = sys.argv[1], Path(sys.argv[2]).resolve()
    base_env = {key: value for key, value in os.environ.items() if not HIDDEN.search(key)}
    if subprocess.run([BASH, "-c", f"command -v {engine}"], env=base_env, capture_output=True).returncode:
        print(f"skip\t{engine}\tnot installed")
        return 3
    work.mkdir(parents=True, exist_ok=True)
    ws = workspace(work, engine, base_env)
    bin_dir = opencode_wrapper(work, base_env) if engine == "opencode" else None
    failed = 0
    for command, expected, marker, engines in CASES:
        if engine not in engines:
            continue
        started = time.monotonic()
        offered, ran, leaked, refusals, output = run_case(engine, work, ws, base_env, bin_dir, command, marker)
        seconds = time.monotonic() - started
        if not offered:
            ok, detail = False, "the engine offered the model no such tool: " + " ".join(output.split())[:200]
        elif expected == "denied":
            ok = refusals and not ran and not leaked
            detail = ("the command ran" + (", and printed its canary" if leaked else "") if ran or leaked
                      else "refused: " + " ".join(refusals[-1].split())[:110] if refusals
                      else "no refusal reported: " + " ".join(output.split())[:200])
        else:
            ok = ran and not refusals
            detail = ("ran" if ok else "refused: " + " ".join(refusals[-1].split())[:110] if refusals
                      else "it did not run: " + " ".join(output.split())[:200])
        failed += not ok
        print(f"{'ok' if ok else 'FAIL'}\t{engine} {expected} {command!r}\t{detail} ({seconds:.0f}s)", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
