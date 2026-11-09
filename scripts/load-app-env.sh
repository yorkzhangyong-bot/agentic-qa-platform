#!/usr/bin/env bash
# load-app-env.sh — load the consumer's APP_ENV secret for the app and tests under test. Never use it for an agent.
#
# Usage:  load-app-env.sh                 append the variables to $GITHUB_ENV, for the job's following steps. Only in
#                                         a job without agent steps: $GITHUB_ENV reaches every later step of the job.
#         load-app-env.sh -- CMD [ARG]…   run CMD with the variables in its environment only. Nothing is written to
#                                         $GITHUB_ENV or to disk: use this for a test run in a job that runs agents.
#         load-app-env.sh --check         only validate APP_ENV and mask its values, e.g. before any agent runs.
#
# APP_ENV holds one KEY=value per line. Blank lines and lines starting with "#" are skipped, leading whitespace is
# ignored and a trailing carriage return is dropped. The value is everything after the first "=", taken literally:
# quotes and "#" are part of it. KEY must match ^[A-Z_][A-Z0-9_]*$ and must not be reserved: GITHUB_*, RUNNER_*,
# ACTIONS_*, PATH, HOME or NODE_OPTIONS. Provider keys such as OPENROUTER_API_KEY are allowed, because APP_ENV never
# reaches an agent step and so can't replace an engine key.
# Inside GitHub Actions every non-empty value is masked with ::add-mask:: before it is used. Values are never
# printed: an error names only the line number (and, for a reserved key, the key). An empty APP_ENV loads nothing.
# Exit code: 1 if a line is malformed or reserved, and then nothing is loaded; 2 for a usage error; otherwise 0, or
# CMD's exit code.
set -euo pipefail

mode="github-env"
case "${1:-}" in
  --check) mode="check"; shift ;;
  --) mode="exec"; shift ;;
esac
if { [ "$mode" = exec ] && [ "$#" -eq 0 ]; } || { [ "$mode" != exec ] && [ "$#" -gt 0 ]; }; then
  echo "usage: load-app-env.sh [--check | -- COMMAND [ARG...]]" >&2
  exit 2
fi

key_ok() (  # key_ok KEY: KEY matches ^[A-Z_][A-Z0-9_]*$, byte by byte whatever the locale
  LC_ALL=C
  [[ "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]]
)

keys=() values=() numbers=()
errors=0
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in "" | "#"*) continue ;; esac
  key="${line%%=*}"
  if [ "$key" = "$line" ] || ! key_ok "$key"; then
    echo "::error::APP_ENV line $n is not KEY=value with KEY matching ^[A-Z_][A-Z0-9_]*\$ (the line is not shown)."
    errors=$((errors + 1))
    continue
  fi
  case "$key" in
    GITHUB_* | RUNNER_* | ACTIONS_* | PATH | HOME | NODE_OPTIONS)
      echo "::error::APP_ENV line $n sets $key, which is reserved for the runner and the workflow."
      errors=$((errors + 1))
      continue
      ;;
  esac
  keys+=("$key")
  values+=("${line#*=}")
  numbers+=("$n")
done <<< "${APP_ENV:-}"
if [ "$errors" -gt 0 ]; then
  echo "load-app-env: APP_ENV has $errors invalid line(s); nothing was loaded." >&2
  exit 1
fi

for i in "${!keys[@]}"; do
  if [ -z "${values[$i]}" ]; then
    echo "::warning::APP_ENV line ${numbers[$i]} sets ${keys[$i]} to an empty value; does the secret it refers to exist?"
  elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    printf '::add-mask::%s\n' "${values[$i]//%/%25}"  # the runner unescapes %25, so a literal % must be escaped
  fi
done

case "$mode" in
  check)
    if [ "${#keys[@]}" -gt 0 ]; then echo "load-app-env: APP_ENV is valid: ${keys[*]}."; fi
    ;;
  github-env)
    if [ "${#keys[@]}" -gt 0 ]; then
      if [ -z "${GITHUB_ENV:-}" ]; then
        echo "load-app-env: GITHUB_ENV is not set; outside GitHub Actions, use: load-app-env.sh -- COMMAND" >&2
        exit 2
      fi
      for i in "${!keys[@]}"; do printf '%s=%s\n' "${keys[$i]}" "${values[$i]}" >> "$GITHUB_ENV"; done
      echo "load-app-env: ${keys[*]} set for the following steps."
    fi
    ;;
  exec)
    for i in "${!keys[@]}"; do export "${keys[$i]}=${values[$i]}"; done
    unset APP_ENV
    exec "$@"
    ;;
esac
