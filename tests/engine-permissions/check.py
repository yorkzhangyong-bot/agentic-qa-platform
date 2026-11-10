#!/usr/bin/env python3
"""check.py — test the agent permissions on a real agent engine, with a fake model in place of the API.

For each case, fake_model.py asks the agent for one tool call: a shell command, or writing, reading or searching a
file. The agent runs through scripts/run-agent.sh in a workspace staged by scripts/stage-agents.sh, as in CI, so the
engine enforces exactly the permissions a CI run gets. A case that must be denied passes when the engine refused it
and it left no trace: the canary (an environment variable only that command would print) shows up nowhere, and no
file was written. A case that must work passes when it ran.

The cases for paths outside the workspace take two steps: first reading a file next to the workspace that holds the
canary, then writing results/triage.json. They pass when the read is refused and the agent goes on to write the
file, so a refusal doesn't end the run; on OpenCode the refusal must come from its external_directory rule. A control
case puts back OpenCode's default for that rule, "ask": `opencode run` rejects every request it would have to ask
about, and a rejection ends the run, so there the file must not be written. OpenCode's own folder for truncated tool
output must stay readable.

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
# Folders outside the workspace, under the work folder. Each holds a secret.txt with the run's canary.
PLACES = {
    "outside": ("outside",),                                  # next to the workspace, like another run's folder
    "tool-output": ("xdg-data", "opencode", "tool-output"),   # where OpenCode saves a truncated tool output
}
OUTSIDE = "{outside}/secret.txt"
THEN_WRITE = "write:results/triage.json"
ASK_FOR_OUTSIDE = {"permission": {"external_directory": "ask"}}   # OpenCode's own default for paths outside
# (steps, expected, what shows that it ran, engines[, OpenCode config to add]). steps is one step or a tuple of them:
# a shell command, "write:<path>" (the write tool), "read:<path>" or "grep:<path>" (those tools); "{outside}" and
# "{tool-output}" stand for the folders in PLACES. In the marker, "{canary}" stands for the run's canary, "file:<path>"
# for a file in the workspace. expected: "allowed", "denied", "denied, continues" (the first step is refused, and the
# last one, THEN_WRITE, still runs) or "stops" (the first step is refused, and the run ends there).
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
    # Paths outside the workspace. Claude Code's Read, Grep and Glob aren't limited by path (run-agent.sh allows them
    # by name), so only OpenCode refuses those; both refuse `cat` outside the workspace.
    ((f"read:{OUTSIDE}", THEN_WRITE), "denied, continues", "{canary}", ("opencode",)),
    (("grep:{outside}", THEN_WRITE), "denied, continues", "{canary}", ("opencode",)),
    ((f"cat {OUTSIDE}", THEN_WRITE), "denied, continues", "{canary}", BOTH),
    ((f"read:{OUTSIDE}", THEN_WRITE), "stops", "{canary}", ("opencode",), ASK_FOR_OUTSIDE),
    ("read:{tool-output}/secret.txt", "allowed", "{canary}", ("opencode",)),  # OpenCode allows it after every rule
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


def engine_env(engine, work, ws, base_env, port, canary, bin_dir, config=None):
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
        extra.update(config or {})  # merged after opencode.json, so its permission keys replace the staged ones
        env.update(OPENCODE_MODEL="permtest/fake", OPENCODE_CONFIG_CONTENT=json.dumps(extra),
                   OPENCODE_DISABLE_AUTOUPDATE="1", OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_SECONDS_PER_TURN="30",
                   XDG_CONFIG_HOME=str(work / "xdg-config"), XDG_DATA_HOME=str(work / "xdg-data"),
                   XDG_STATE_HOME=str(work / "xdg-state"),
                   PATH=f"{bin_dir}{os.pathsep}{base_env.get('PATH', '')}")
    return env


TOOLS = {"write": ("Write", "write"), "read": ("Read", "read"), "grep": ("Grep", "grep")}  # (Claude Code, OpenCode)


def step_tool(step, engine):
    tools = TOOLS.get(step.partition(":")[0], ("Bash", "bash"))
    return tools[engine == "opencode"]


def run_case(engine, work, ws, base_env, bin_dir, steps, marker, config=None):
    """Run one case through the agent. Returns (tools offered, ran, canary leaked, refusals, the first step's
    refusal or None, engine output)."""
    steps = [steps] if isinstance(steps, str) else list(steps)
    record, port_file = work / "record.jsonl", work / "port"
    files = [ws / step[6:] for step in steps if step.startswith("write:")]
    for path in (record, port_file, ws / "leak.txt", *files, *([ws / marker[5:]] if marker.startswith("file:") else [])):
        path.unlink(missing_ok=True)
    canary = "canary-" + secrets.token_hex(6)
    places = {name: work.joinpath(*parts) for name, parts in PLACES.items()}
    for folder in places.values():
        write(folder / "secret.txt", f"{canary}\n")
    requests = []
    for step in steps:
        for name, folder in places.items():  # forward slashes, which Git Bash on Windows reads too
            step = step.replace("{%s}" % name, folder.as_posix())
        kind, _, path = step.partition(":")
        if kind in TOOLS:  # the tools get an absolute path in the platform's own form
            requests.append(f"{kind}:{Path(path) if Path(path).is_absolute() else ws / path}")
        else:
            requests.append(step)
    tools = {step_tool(step, engine) for step in steps}
    server = subprocess.Popen([sys.executable, str(FAKE_MODEL), json.dumps(requests), str(record), str(port_file)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if port_file.exists() and port_file.read_text(encoding="utf-8"):
                break
            time.sleep(0.05)
        env = engine_env(engine, work, ws, base_env, port_file.read_text(encoding="utf-8"), canary, bin_dir, config)
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
    offered = tools <= {name for entry in entries for name in entry.get("tools") or []}
    results = [entry for entry in entries if "tool_result" in entry]
    texts = [entry["tool_result"] for entry in results]
    refusals = [entry["tool_result"] for entry in results if entry.get("is_error")]
    first = next((entry["tool_result"] for entry in results if entry.get("step") == 0 and entry.get("is_error")), None)
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
                if part.get("callID") == "call_permtest_0":
                    first = str(state.get("error") or "")
    marker = marker.replace("{canary}", canary)
    if marker.startswith("file:"):
        ran = (ws / marker[5:]).exists()
    else:
        ran = marker in output or any(marker in text for text in texts)
    leaked = canary in output or any(canary in text for text in texts)
    return offered, ran, leaked, refusals, first, output


def short(text, length=110):
    return " ".join(str(text).split())[:length]


def judge_refusal(engine, expected, first, leaked, wrote, output):
    """(ok, detail) for a two-step case: the first step must be refused without reading the file. With "denied,
    continues" the agent must then write the file; with "stops" the run must end at the refusal."""
    if leaked:
        return False, "the file was read: its canary reached the model"
    if first is None:
        return False, "no refusal reported: " + short(output, 200)
    if engine == "opencode" and expected == "denied, continues" and '"permission":"external_directory"' not in first:
        if "rejected permission" in first:
            return False, ("OpenCode asked to allow it and `opencode run` rejected the request, instead of a deny "
                           "rule refusing it; " + ("then the agent wrote results/triage.json" if wrote
                                                   else "the run ended there"))
        return False, "refused by another rule than external_directory: " + short(first)
    if engine == "opencode" and expected == "stops" and "rejected permission" not in first:
        return False, "refused, but not by rejecting a permission request: " + short(first)
    if expected == "denied, continues" and not wrote:
        return False, "refused, but the run ended there: " + short(first)
    if expected == "stops" and wrote:
        return False, "refused, but the run went on: " + short(first)
    then = "then the agent wrote results/triage.json" if wrote else "and the run ended there"
    rule = " by the external_directory rule" if engine == "opencode" and expected == "denied, continues" else ""
    return True, f"refused{rule} ({short(first, 60)}); {then}"


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
    for steps, expected, marker, engines, *config in CASES:
        if engine not in engines:
            continue
        started = time.monotonic()
        offered, ran, leaked, refusals, first, output = run_case(engine, work, ws, base_env, bin_dir, steps, marker,
                                                                 *config)
        seconds = time.monotonic() - started
        if not offered:
            ok, detail = False, "the engine offered the model no such tool: " + short(output, 200)
        elif expected == "denied":
            ok = refusals and not ran and not leaked
            detail = ("the command ran" + (", and printed its canary" if leaked else "") if ran or leaked
                      else "refused: " + short(refusals[-1]) if refusals
                      else "no refusal reported: " + short(output, 200))
        elif expected in ("denied, continues", "stops"):
            wrote = (ws / THEN_WRITE[len("write:"):]).exists()
            ok, detail = judge_refusal(engine, expected, first, leaked, wrote, output)
        else:
            ok = ran and not refusals
            detail = ("ran" if ok else "refused: " + short(refusals[-1]) if refusals
                      else "it did not run: " + short(output, 200))
        failed += not ok
        label = steps if isinstance(steps, str) else " then ".join(steps)
        if config:
            label += f" (with {json.dumps(config[0], separators=(',', ':'))})"
        print(f"{'ok' if ok else 'FAIL'}\t{engine} {expected} {label!r}\t{detail} ({seconds:.0f}s)", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
