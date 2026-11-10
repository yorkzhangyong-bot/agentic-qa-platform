#!/usr/bin/env bash
# stage-agents.sh — stage the platform's agents, shared rules, permissions and MCP config for one agent engine.
#
# Run it from the root of the repository under test (the workflows run it from $GITHUB_WORKSPACE).
#
# Environment:
#   ENGINE                  claude (default) | opencode
#   FRAMEWORK               framework config name, e.g. playwright (required)
#   PLATFORM_DIR            agentic-qa-platform checkout (default: .agentic-qa)
#   TEST_DIR                test directory (default: the framework's default_test_dir). OpenCode may only edit
#                           files there, in results/ and PR_BODY.md.
#   PLAYWRIGHT_MCP_VERSION  @playwright/mcp version to pin (default: the version in settings/claude-mcp.json)
#   OPENCODE_MODEL          provider/model for the OpenCode agents (default: deepseek/deepseek-flash)
#   SKIP_MCP_WARMUP=1       don't pre-download the MCP server (offline use, tests)
#
# ENGINE=claude    .claude/agents/<file>.md   copies of agents/common/*.md and agents/<framework>/*.md
#                  .claude/settings.json      copy of settings/claude-settings.json (Bash allow/deny list). In a
#                                             -p run Claude Code applies only its deny rules, so run-agent.sh also
#                                             passes the file with --settings.
#                  .mcp.json                  settings/claude-mcp.json with the MCP version pinned
# ENGINE=opencode  .opencode/agents/<name>.md the same agents, front matter converted to OpenCode's format; its
#                                             permission map only denies the tools the agent doesn't list
#                  AGENTS.md                  copy of AGENT-RULES.md
#                  opencode.json              the MCP servers in OpenCode's format, merged with
#                                             settings/opencode-permissions.json ({TEST_DIR} filled in), which
#                                             alone decides what a listed tool may do
# Both engines: staged files and run artefacts are added to .git/info/exclude, so they never reach a pull request.
set -euo pipefail

engine="${ENGINE:-claude}"
framework="${FRAMEWORK:?FRAMEWORK is required, e.g. playwright}"
platform="${PLATFORM_DIR:-.agentic-qa}"

case "$engine" in
  claude|opencode) ;;
  *) echo "stage-agents: unknown ENGINE '$engine' (expected claude or opencode)" >&2; exit 2 ;;
esac
[[ "$framework" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "stage-agents: invalid FRAMEWORK '$framework'" >&2; exit 2; }
[ -f "$platform/frameworks/$framework.json" ] || { echo "stage-agents: $platform/frameworks/$framework.json not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "stage-agents: python3 is required" >&2; exit 2; }
exclude="$(git rev-parse --git-path info/exclude)"

warmup="$(python3 - "$engine" "$framework" "$platform" "$exclude" <<'PY'
import json
import os
import pathlib
import re
import sys

engine, framework, platform, exclude_path = sys.argv[1:5]
platform = pathlib.Path(platform)
config = json.loads((platform / "frameworks" / f"{framework}.json").read_text(encoding="utf-8"))
test_dir = (os.environ.get("TEST_DIR") or config["default_test_dir"]).strip().strip("/") or "."
mcp_name = config.get("mcp", "browser")
version = os.environ.get("PLAYWRIGHT_MCP_VERSION", "").strip()

servers = json.loads((platform / "settings" / "claude-mcp.json").read_text(encoding="utf-8"))["mcpServers"]
if version:
    for server in servers.values():
        server["args"] = [f"@playwright/mcp@{version}" if a.startswith("@playwright/mcp@") else a
                          for a in server.get("args", [])]
if mcp_name not in servers:
    sys.exit(f"stage-agents: MCP server '{mcp_name}' (frameworks/{framework}.json) is not defined in settings/claude-mcp.json")

agents = sorted((platform / "agents" / "common").glob("*.md")) + sorted((platform / config["agents_dir"]).glob("*.md"))
if not agents:
    sys.exit("stage-agents: no agent files found")


def write(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def front_matter(path):
    text = path.read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        sys.exit(f"stage-agents: {path} has no YAML front matter")
    fields = {}
    for line in m.group(1).splitlines():
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip()] = value.strip()
    return fields, text[m.end():].lstrip("\n")


staged = []
if engine == "claude":
    for src in agents:
        write(f".claude/agents/{src.name}", src.read_text(encoding="utf-8"))
        staged.append(f".claude/agents/{src.name}")
    write(".claude/settings.json", (platform / "settings" / "claude-settings.json").read_text(encoding="utf-8"))
    write(".mcp.json", json.dumps({"mcpServers": servers}, indent=2) + "\n")
    staged += [".claude/settings.json", ".mcp.json"]
else:
    model = os.environ.get("OPENCODE_MODEL") or "deepseek/deepseek-flash"
    # OpenCode permission -> the agent tools that use it; Write and Edit share "edit".
    uses = {"read": {"Read"}, "edit": {"Write", "Edit"}, "bash": {"Bash"}, "glob": {"Glob"}, "grep": {"Grep"}}
    for src in agents:
        fields, body = front_matter(src)
        listed = {t.strip() for t in fields.get("tools", "").split(",") if t.strip()}
        servers_listed = set()
        for tool in sorted(listed):
            mcp = re.fullmatch(r"mcp__(.+)__\*", tool)
            if mcp:
                servers_listed.add(mcp.group(1))
            elif not any(tool in tools for tools in uses.values()):
                print(f"stage-agents: {src.name}: no OpenCode equivalent for tool '{tool}'; skipped", file=sys.stderr)
        # The agent file only switches tools off. OpenCode applies an agent's own rules after opencode.json's and the
        # last matching rule wins, so any allow here would override the shared rules: the deprecated `tools: {bash:
        # true}` became "bash: allow" for every command, deny rules included. A listed tool gets no rule of its own,
        # and settings/opencode-permissions.json alone decides what it may do.
        deny = [permission for permission, tools in uses.items() if not tools & listed] + ["webfetch"]
        deny += [f"{name}_*" for name in servers if name not in servers_listed]  # OpenCode names MCP tools <server>_<tool>
        # mode "all" (primary + subagent): `opencode run --agent <name>` needs an agent it may use as primary.
        lines = ["---", f"description: {json.dumps(fields['description'], ensure_ascii=False)}", "mode: all",
                 f"model: {json.dumps(model)}", "permission:"]
        lines += [f"  {json.dumps(permission)}: deny" for permission in deny]
        write(f".opencode/agents/{fields['name']}.md", "\n".join(lines) + "\n---\n\n" + body)
        staged.append(f".opencode/agents/{fields['name']}.md")
    write("AGENTS.md", (platform / "AGENT-RULES.md").read_text(encoding="utf-8"))

    def fill(node):
        if isinstance(node, dict):
            return {fill(k): fill(v) for k, v in node.items()}
        if isinstance(node, list):
            return [fill(v) for v in node]
        return node.replace("{TEST_DIR}", test_dir) if isinstance(node, str) else node

    opencode = {
        "$schema": "https://opencode.ai/config.json",
        "mcp": {name: {"type": "local", "command": [s["command"], *s.get("args", [])], "enabled": True}
                for name, s in servers.items()},
    }
    opencode.update(fill(json.loads((platform / "settings" / "opencode-permissions.json").read_text(encoding="utf-8"))))
    write("opencode.json", json.dumps(opencode, indent=2) + "\n")
    staged += ["AGENTS.md", "opencode.json"]

# Keep staged files and run artefacts out of git status, anti-cheat and the pull request (both engines' files).
# "/.opencode/" covers the staged .opencode/agents/ and anything else OpenCode may write under .opencode/.
entries = [f"/.claude/agents/{src.name}" for src in agents] + [
    "/.claude/settings.json", "/.mcp.json", "/.opencode/", "/AGENTS.md", "/opencode.json",
    "/results/", "/spec.md", "/PR_BODY.md", "/.playwright-mcp/",
    "node_modules/", "test-results/", "playwright-report/", "blob-report/",
    "cypress/screenshots/", "cypress/videos/", "cypress/downloads/", "target/",
]
try:
    platform_rel = os.path.relpath(platform.resolve(), pathlib.Path.cwd().resolve()).replace(os.sep, "/")
except ValueError:  # different drive on Windows
    platform_rel = ".."
if not platform_rel.startswith(".."):
    entries.append(f"/{platform_rel}/")
exclude = pathlib.Path(exclude_path)
exclude.parent.mkdir(parents=True, exist_ok=True)
current = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
missing = [e for e in entries if e not in current.splitlines()]
with open(exclude, "a", encoding="utf-8", newline="\n") as fh:
    if current and not current.endswith("\n"):
        fh.write("\n")
    fh.writelines(e + "\n" for e in missing)

print(f"stage-agents: engine {engine}, framework {framework}, test dir {test_dir}. Staged:", file=sys.stderr)
for path in staged:
    print(f"  {path}", file=sys.stderr)
server = servers[mcp_name]
print(next((a for a in server.get("args", []) if not a.startswith("-")), "") if server.get("command") == "npx" else "")
PY
)"

if [ -n "$warmup" ] && [ "${SKIP_MCP_WARMUP:-0}" != 1 ]; then
  echo "stage-agents: pre-downloading $warmup"
  npx -y "$warmup" --version > /dev/null || echo "::warning::Could not pre-download $warmup; the first agent run may be slow."
fi
