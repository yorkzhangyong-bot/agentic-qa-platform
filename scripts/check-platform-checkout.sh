#!/usr/bin/env bash
# check-platform-checkout.sh — fail if the platform checkout holds parts of the platform that only its own
# development uses, which the agents must never see: the evals and tests folders and BACKLOG.md. The workflows check
# out only the parts the jobs use at run time (a sparse checkout); this catches a checkout that isn't sparse after
# all. The agents can read this file, so it names those parts only as far as it must.
#
# Run it from the repository root, after the platform checkout and before the first agent (each agent job does).
#
# Environment:
#   PLATFORM_DIR  agentic-qa-platform checkout (default .agentic-qa)
#
# Exit code: 0 if none of them is there, 1 if any is, 2 if there is no checkout.
set -euo pipefail

platform="${PLATFORM_DIR:-.agentic-qa}"
[ -d "$platform" ] || { echo "check-platform-checkout: $platform not found" >&2; exit 2; }

status=0
for path in evals tests BACKLOG.md; do
  if [ -e "$platform/$path" ] || [ -L "$platform/$path" ]; then
    echo "::error::$platform/$path is in the platform checkout, where an agent could read it. Check out only the parts the jobs use (sparse-checkout in the workflow)."
    status=1
  fi
done
[ "$status" -ne 0 ] || echo "check-platform-checkout: none of evals, tests and BACKLOG.md is in $platform."
exit "$status"
