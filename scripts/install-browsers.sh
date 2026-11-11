#!/usr/bin/env bash
# install-browsers.sh — install the Playwright browsers a job's tests need, so that apt failing for a while (an
# unreachable Ubuntu mirror, DNS) doesn't fail the run.
#
#   install-browsers.sh key       Writes version=<the project's Playwright version> and
#                                 key=playwright-<OS>-<arch>-<version>-<browsers> to $GITHUB_OUTPUT, for actions/cache
#                                 on ~/.cache/ms-playwright: the workflows restore it before the install and save it
#                                 after. Without a version (no Playwright in the project) the key is empty.
#   install-browsers.sh [install] Runs npx playwright install --with-deps <browsers> up to 3 times, 15 s and then 45 s
#                                 apart, with sudo apt-get update before each retry. If that still fails, it installs
#                                 the browsers once without their system packages. Then each browser must launch
#                                 headless. If it does, the job goes on, with a warning when the system packages are
#                                 missing. If it doesn't, the job fails with an error that says whether apt (the
#                                 network) or the browser itself is the problem.
#
# Run it from the project root, after the install commands (install-deps.sh): it uses the project's own Playwright
# (npx --no), never another version.
#
# Environment:
#   FRAMEWORK             framework config name (required); nothing to do unless frameworks/<framework>.json lists
#                         playwright_browsers
#   BROWSERS              the browsers, space- or comma-separated: chromium, firefox, webkit. Default: the config's
#                         playwright_browsers. The workflows pass their playwright_browsers input, if set.
#   PLATFORM_DIR          agentic-qa-platform checkout (default .agentic-qa)
#   PLAYWRIGHT_VERSION    key: the version to use instead of asking the project's Playwright
#   INSTALL_RETRY_DELAYS  install: seconds to wait before each retry (default "15 45", which makes 3 attempts)
#
# Exit code: 0 when every browser launches (and always for key); 1 when the project has no Playwright, the browsers
# can't be downloaded, or one doesn't launch; 2 for a usage error.
set -euo pipefail

mode="${1:-install}"
die() { echo "install-browsers: $1" >&2; exit 2; }
case "$mode" in key|install) ;; *) die "unknown mode '$mode' (expected key or install)" ;; esac
framework="${FRAMEWORK:-}"
[[ "$framework" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "FRAMEWORK must be a framework config name, got '$framework'"
platform="${PLATFORM_DIR:-.agentic-qa}"
read -r -a delays <<< "${INSTALL_RETRY_DELAYS-15 45}"
for delay in ${delays[@]+"${delays[@]}"}; do
  [[ "$delay" =~ ^[0-9]+$ ]] || die "INSTALL_RETRY_DELAYS must be whole seconds, got '$delay'"
done
attempts=$(( ${#delays[@]} + 1 ))

wanted="${BROWSERS:-}"
if [ -z "${wanted//[ ,]/}" ]; then
  config="$platform/frameworks/$framework.json"
  [ -f "$config" ] || die "$config not found"
  wanted="$(python3 -c 'import json, sys
print(" ".join(json.load(open(sys.argv[1], encoding="utf-8")).get("playwright_browsers") or []))' "$config")"
fi
read -r -a words <<< "${wanted//,/ }"
browsers=()
while IFS= read -r browser; do
  [ -n "$browser" ] || continue
  case "$browser" in
    chromium|firefox|webkit) browsers+=("$browser") ;;
    *) die "unsupported browser '$browser' (chromium, firefox, webkit)" ;;
  esac
done < <(printf '%s\n' ${words[@]+"${words[@]}"} | sort -u)
if [ "${#browsers[@]}" -eq 0 ]; then
  echo "install-browsers: $framework installs no Playwright browsers; nothing to do."
  exit 0
fi

if [ "$mode" = key ]; then
  version="${PLAYWRIGHT_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(npx --no -- playwright --version 2> /dev/null | sed -n 's/^Version //p' | head -n 1)" || version=""
  fi
  key=""
  if [[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
    key="playwright-${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}-$version-$(IFS=-; echo "${browsers[*]}")"
  else
    version=""
    echo "::warning title=Browser install::Couldn't read the project's Playwright version, so the browsers aren't cached."
  fi
  echo "install-browsers: Playwright ${version:-unknown}, cache key ${key:-none}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'version=%s\nkey=%s\n' "$version" "$key" >> "$GITHUB_OUTPUT"; fi
  exit 0
fi

if ! npx --no -- playwright --version > /dev/null; then
  echo "::error title=Browser install::The project has no Playwright CLI (npx --no -- playwright --version failed). Install @playwright/test (npm ci) before the browsers."
  exit 1
fi

# 1. The browsers with their system packages, retried: apt is what fails when a mirror can't be reached.
attempt=1
system_packages=installed
while ! npx --no -- playwright install --with-deps "${browsers[@]}"; do
  if [ "$attempt" -ge "$attempts" ]; then
    system_packages=missing
    break
  fi
  delay="${delays[$((attempt - 1))]}"
  echo "install-browsers: attempt $attempt of $attempts failed; retrying in ${delay}s, after apt-get update."
  sleep "$delay"
  sudo apt-get update || echo "install-browsers: apt-get update failed as well; trying the install anyway."
  attempt=$((attempt + 1))
done
if [ "$system_packages" = installed ] && [ "$attempt" -gt 1 ]; then
  echo "::notice title=Browser install::Installed ${browsers[*]} with the system packages on attempt $attempt of $attempts."
fi

# 2. Without the system packages: the runner image has most of them, and the launch check below decides.
if [ "$system_packages" = missing ]; then
  echo "install-browsers: the system packages couldn't be installed in $attempts attempts; installing ${browsers[*]} without them."
  if ! npx --no -- playwright install "${browsers[@]}"; then
    echo "::error title=Browser install::Couldn't install ${browsers[*]}: apt-get failed $attempts times, and the browser download failed too. This is a network problem on the runner, not a test failure; re-run the job."
    exit 1
  fi
fi

# 3. Each browser must launch headless.
failed=()
for browser in "${browsers[@]}"; do
  if node -e 'const pw = (() => { try { return require("@playwright/test"); } catch { return require("playwright"); } })(); pw[process.argv[1]].launch({ timeout: 60000 }).then(b => b.close())' "$browser"; then
    echo "install-browsers: $browser launches."
  else
    failed+=("$browser")
  fi
done
if [ "${#failed[@]}" -gt 0 ]; then
  if [ "$system_packages" = missing ]; then
    echo "::error title=Browser install::${failed[*]} can't launch: its system packages couldn't be installed (apt-get failed $attempts times). This is an apt or network problem on the runner, not a test failure; re-run the job."
  else
    echo "::error title=Browser install::${failed[*]} can't launch, although the install with its system packages succeeded. See the launch error above."
  fi
  exit 1
fi
if [ "$system_packages" = missing ]; then
  echo "::warning title=Browser install::${browsers[*]} installed without the system packages (apt-get failed $attempts times: an apt or network problem on the runner). The browsers launch, so the run goes on; missing fonts can change how pages render."
fi
