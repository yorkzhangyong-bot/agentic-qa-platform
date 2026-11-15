#!/usr/bin/env bash
# app-server.sh — start the consumer's app for the steps of a job, wait until it answers, and stop it again.
#
# The reusable workflows run it when the caller sets app_start_command: once for the agents' steps, without the
# consumer's APP_ENV, and once more for the workflow's own test run, with APP_ENV (see "Starting the app in the
# workflow" in the README). Playwright's webServer reuses the running app when reuseExistingServer is true.
#
# Usage:  app-server.sh start   run APP_START_COMMAND in the background, detached from the step, and wait until
#                               APP_READY_URL answers. Fails if something already answers there before the start,
#                               if the command exits before the app answers, or if the app doesn't answer within
#                               APP_READY_TIMEOUT seconds; then the command is stopped again and the end of its
#                               output is printed.
#         app-server.sh stop    stop the app `start` started: SIGTERM to its process group, SIGKILL 10 s later,
#                               then wait until the URL no longer answers. Nothing to do when no app runs. Fails if
#                               something still answers at the URL afterwards, because a restart would then test
#                               the wrong instance. The app's log is deleted, so no later step can read it.
#
# Environment:
#   APP_START_COMMAND   the command, run with `bash -c` from the current directory (start)
#   APP_READY_URL       URL that answers once the app is up (start). Ready means an HTTP status of 2xx, 3xx or
#                       400-403, as Playwright's webServer takes it: a login page or a 403 counts, 404 and 5xx don't.
#   APP_READY_TIMEOUT   seconds to wait for it (default 120)
#   APP_SERVER_DIR      folder for the pid, URL and log files (default $RUNNER_TEMP/app-server, else /tmp/app-server;
#                       outside the workspace, so the agents don't work on them)
#
# The app's output goes to $APP_SERVER_DIR/app.log. Its last lines are printed when the start fails and when the app
# is stopped: in GitHub Actions that is the step's log, where the APP_ENV values are masked. The file is never
# uploaded. The command itself is printed, so it must not contain secrets; use APP_ENV for them.
# Exit code: 0; 1 when the app didn't start, or still answers after stop; 2 for a usage error.
set -euo pipefail

usage() {
  echo "app-server.sh: $1" >&2
  echo "usage: APP_START_COMMAND=... APP_READY_URL=... app-server.sh start | app-server.sh stop" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage "expected one argument: start or stop"
mode="$1"
case "$mode" in start | stop) ;; *) usage "unknown mode '$mode'" ;; esac

dir="${APP_SERVER_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/app-server}"
pid_file="$dir/pid"
url_file="$dir/url"
log="$dir/app.log"
status=000

probe() {  # probe URL: sets status to the HTTP status the URL answers with, or 000 when nothing answers there
  status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2> /dev/null)" || true
  status="${status:-000}"
}

ready() {  # ready URL: the app answers and is up, by Playwright's rule for a webServer: 2xx, 3xx or 400-403
  probe "$1"
  [[ "$status" =~ ^(2[0-9][0-9]|3[0-9][0-9]|40[0-3])$ ]]
}

alive() {  # alive PID
  kill -0 "$1" 2> /dev/null
}

signal_group() {  # signal_group SIGNAL PID: the whole process group of the app, or just the process if it has none
  kill "-$1" -- "-$2" 2> /dev/null || kill "-$1" "$2" 2> /dev/null || true
}

wait_gone() {  # wait_gone PID TENTHS: wait until the process is gone, at most TENTHS tenths of a second
  local n
  for ((n = 0; n < $2; n++)); do
    alive "$1" || return 0
    sleep 0.1
  done
  ! alive "$1"
}

print_log() {
  if [ -s "$log" ]; then
    echo "app-server: last lines of the app's output ($(wc -l < "$log") in all):"
    tail -n 30 "$log" | sed 's/^/  | /'
  else
    echo "app-server: the app wrote no output."
  fi
}

cleanup() {
  rm -f "$pid_file" "$url_file" "$log"
}

stop_app() {  # stop_app PID: SIGTERM to the app's process group, SIGKILL when it ignores that for 10 s
  if ! alive "$1"; then
    return 1
  fi
  signal_group TERM "$1"
  if ! wait_gone "$1" 100; then
    echo "app-server: the app ignored SIGTERM for 10 s; sending SIGKILL."
    signal_group KILL "$1"
    wait_gone "$1" 50 || true
  fi
}

start() {
  local cmd="${APP_START_COMMAND:-}" url="${APP_READY_URL:-}" timeout="${APP_READY_TIMEOUT:-120}"
  local pid waited=0 code
  [ -n "$cmd" ] || usage "APP_START_COMMAND is required for start"
  [ -n "$url" ] || usage "APP_READY_URL is required for start"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || usage "APP_READY_TIMEOUT must be a positive number of seconds, got '$timeout'"
  command -v curl > /dev/null 2>&1 || usage "curl is required to check APP_READY_URL"
  if [ -f "$pid_file" ] && alive "$(cat "$pid_file")"; then
    echo "::error::The app is already running (process group $(cat "$pid_file")). Stop it with app-server.sh stop first."
    exit 1
  fi
  probe "$url"
  if [ "$status" != 000 ]; then
    echo "::error::Something already answers at $url (HTTP $status) before the app was started. The workflow starts the app itself, so nothing else may listen there; check app_ready_url and app_start_command."
    exit 1
  fi
  mkdir -p "$dir"
  : > "$log"
  printf '%s\n' "$url" > "$url_file"
  echo "app-server: starting the app: $cmd"
  # Job control: the command gets a process group of its own, so stop can signal the app and everything it spawned
  # at once, and the step's shell can exit without it.
  set -m
  bash -c "$cmd" > "$log" 2>&1 < /dev/null &
  pid=$!
  set +m
  printf '%s\n' "$pid" > "$pid_file"
  while :; do
    if ready "$url"; then
      echo "app-server: $url answers (HTTP $status) after ${waited}s; the app runs as process group $pid."
      return 0
    fi
    if ! alive "$pid"; then
      code=0
      wait "$pid" || code=$?
      echo "::error::The app command exited with code $code before $url answered (its last HTTP status: $status)."
      print_log
      cleanup
      exit 1
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "::error::$url did not answer within ${timeout}s (last HTTP status: $status; ready means 2xx, 3xx or 400-403). Check app_ready_url, or raise app_ready_timeout if the app needs longer to start."
      stop_app "$pid" || true
      print_log
      cleanup
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

stop() {
  local pid url n
  if [ ! -f "$pid_file" ]; then
    echo "app-server: no app to stop."
    return 0
  fi
  pid="$(cat "$pid_file")"
  url="$(cat "$url_file" 2> /dev/null || true)"
  if stop_app "$pid"; then
    echo "app-server: stopped the app (process group $pid)."
  else
    echo "::warning::The app (process group $pid) had already exited before it was stopped."
  fi
  if [ -n "$url" ]; then
    for ((n = 0; n < 100; n++)); do
      probe "$url"
      [ "$status" != 000 ] || break
      sleep 0.1
    done
    if [ "$status" != 000 ]; then
      print_log
      cleanup
      echo "::error::$url still answers (HTTP $status) after the app was stopped, so a restart would test the wrong instance. Something outside the app's process group is listening there; check app_start_command."
      exit 1
    fi
  fi
  print_log
  cleanup
}

"$mode"
