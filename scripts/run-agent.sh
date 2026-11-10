#!/usr/bin/env bash
# run-agent.sh — run one platform agent non-interactively on the selected engine.
#
# Run it from the repository root, after stage-agents.sh staged the agents for the same ENGINE.
#
# Environment:
#   ENGINE           claude (default) | opencode
#   AGENT            agent name: triage, healer, planner, generator or pr-writer (required)
#   PROMPT           the task for the agent (required)
#   MAX_TURNS        turn budget (default 30)
#   EXPECTED_OUTPUT  file the agent must write; the script fails if it is missing or empty afterwards
#   PLATFORM_DIR     agentic-qa-platform checkout (default .agentic-qa); AGENT-RULES.md is read from there
#   claude only:     ALLOWED_TOOLS (default Read,Edit,Write,Glob,Grep,Agent,Task), MCP_SERVER (default browser)
#   opencode only:   OPENCODE_MODEL (default deepseek/deepseek-flash), OPENCODE_SECONDS_PER_TURN (default 30)
#
# Credentials come from the environment: ANTHROPIC_API_KEY for claude; for opencode the key of the model's
# provider (DEEPSEEK_API_KEY, OPENROUTER_API_KEY or OPENAI_API_KEY).
# Exit code: with EXPECTED_OUTPUT, 0 if the file was written (even if the engine stopped early, e.g. at the turn
# limit) and 1 otherwise; without it, the engine's exit code. 2 means a usage or setup error.
set -euo pipefail

engine="${ENGINE:-claude}"
agent="${AGENT:?AGENT is required}"
prompt="${PROMPT:?PROMPT is required}"
max_turns="${MAX_TURNS:-30}"
expected="${EXPECTED_OUTPUT:-}"
platform="${PLATFORM_DIR:-.agentic-qa}"

[[ "$max_turns" =~ ^[1-9][0-9]*$ ]] || { echo "run-agent: MAX_TURNS must be a positive number, got '$max_turns'" >&2; exit 2; }
[ -z "$expected" ] || rm -f -- "$expected"   # a stale file must not count as this run's output

status=0
case "$engine" in
  claude)
    agent_file=".claude/agents/${agent}.md"
    [ -f "$agent_file" ] || { echo "run-agent: $agent_file not found; run stage-agents.sh with ENGINE=claude first" >&2; exit 2; }
    tools="${ALLOWED_TOOLS:-Read,Edit,Write,Glob,Grep,Agent,Task}"   # no Bash: .claude/settings.json governs it
    server="${MCP_SERVER:-browser}"
    mcp_args=(--strict-mcp-config)                                    # agents without browser tools get no MCP
    if grep -qE "^tools:.*mcp__${server}__\*" "$agent_file"; then
      tools="$tools,mcp__${server}__*"
      mcp_args=(--mcp-config .mcp.json --strict-mcp-config)
    fi
    # --settings: Claude Code ignores the allow rules in a project's .claude/settings.json until someone accepts the
    # workspace trust dialog, which a `claude -p` run never shows, so a CI checkout never gets them; only deny and
    # ask rules apply there. Settings passed on the command line come from whoever runs Claude Code, so they apply.
    claude -p "$prompt" \
      --agent "$agent" \
      --append-system-prompt-file "$platform/AGENT-RULES.md" \
      --settings "$platform/settings/claude-settings.json" \
      --allowedTools "$tools" \
      "${mcp_args[@]}" \
      --permission-mode dontAsk \
      --max-turns "$max_turns" < /dev/null || status=$?
    ;;
  opencode)
    agent_file=".opencode/agents/${agent}.md"
    [ -f "$agent_file" ] || { echo "run-agent: $agent_file not found; run stage-agents.sh with ENGINE=opencode first" >&2; exit 2; }
    # `opencode run` has no turn cap like Claude Code's --max-turns (none this script relies on), so MAX_TURNS is
    # emulated with a wall-clock limit of MAX_TURNS x OPENCODE_SECONDS_PER_TURN seconds. Rules come from AGENTS.md,
    # MCP and permissions from opencode.json, both written by stage-agents.sh.
    seconds=$(( max_turns * ${OPENCODE_SECONDS_PER_TURN:-30} ))
    runner=()
    if command -v timeout >/dev/null 2>&1; then
      runner=(timeout --kill-after=30s "${seconds}s")
    else
      echo "::warning::timeout(1) not found; running opencode without the ${seconds}s limit that stands in for MAX_TURNS."
    fi
    ${runner[@]+"${runner[@]}"} opencode run --agent "$agent" --model "${OPENCODE_MODEL:-deepseek/deepseek-flash}" "$prompt" < /dev/null || status=$?
    [ "$status" -ne 124 ] || echo "::warning::opencode reached the ${seconds}s limit that stands in for MAX_TURNS=${max_turns}."
    ;;
  *)
    echo "run-agent: unknown ENGINE '$engine' (expected claude or opencode)" >&2
    exit 2
    ;;
esac

if [ -n "$expected" ]; then
  if [ ! -s "$expected" ]; then
    echo "::error::The $agent agent did not write $expected ($engine exit code $status)."
    exit 1
  fi
  [ "$status" -eq 0 ] || echo "::warning::$engine exited with code $status; using the $expected the $agent agent wrote."
  exit 0
fi
exit "$status"
