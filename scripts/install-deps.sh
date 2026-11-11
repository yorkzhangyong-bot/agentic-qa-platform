#!/usr/bin/env bash
# install-deps.sh — run the framework's install commands (the "install" list of frameworks/<framework>.json), each
# retried when it fails, so a registry or mirror that fails for a moment doesn't fail the run: up to 3 attempts,
# 15 s and then 45 s apart. For Cypress this covers the binary that npm ci downloads; for Selenium, the Maven
# dependencies. The Playwright browsers are installed afterwards, by install-browsers.sh.
#
# Environment:
#   INSTALL_SCRIPT        the install commands, one per line (the workflows pass _select-framework.yml's
#                         install_script output)
#   INSTALL_RETRY_DELAYS  seconds to wait before each retry (default "15 45", which makes 3 attempts)
#
# Each command runs with bash -c and no input. Exit code: 0 when every command succeeded; otherwise that of the
# command that failed every attempt (the commands after it don't run); 2 for a usage error.
set -euo pipefail

read -r -a delays <<< "${INSTALL_RETRY_DELAYS-15 45}"
for delay in ${delays[@]+"${delays[@]}"}; do
  [[ "$delay" =~ ^[0-9]+$ ]] || { echo "install-deps: INSTALL_RETRY_DELAYS must be whole seconds, got '$delay'" >&2; exit 2; }
done
attempts=$(( ${#delays[@]} + 1 ))

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  echo "::group::$cmd"
  attempt=1
  while true; do
    status=0
    bash -c "$cmd" < /dev/null || status=$?
    [ "$status" -ne 0 ] || break
    if [ "$attempt" -ge "$attempts" ]; then
      echo "::endgroup::"
      echo "::error title=Install::'$cmd' failed $attempts times (exit code $status). If the errors above are about the network (a registry, a mirror, DNS), re-run the job."
      exit "$status"
    fi
    delay="${delays[$((attempt - 1))]}"
    echo "::warning title=Install::'$cmd' failed (exit code $status, attempt $attempt of $attempts); retrying in ${delay}s."
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  echo "::endgroup::"
done <<< "${INSTALL_SCRIPT:-}"
