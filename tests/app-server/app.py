#!/usr/bin/env python3
"""app.py — a stand-in app for the app-server.sh tests: an HTTP server whose behaviour the test picks.

Usage: python3 app.py PORT [--status N] [--delay SECONDS] [--exit CODE] [--child] [--escape] [--body-env NAME]
  --status N       answer every request with this HTTP status (default 200)
  --delay SECONDS  wait this long before listening (a slow start)
  --exit CODE      exit with this code at once, after a line of output, instead of serving (a crash)
  --child          also run a child process that sleeps, in the app's own process group, and print "child <pid>":
                   stopping the app must stop it too
  --escape         serve from a child process in a session of its own, which a signal to the app's process group
                   doesn't reach, and print "escaped <pid>": something keeps answering after the app is stopped
  --body-env NAME  answer with the value of the environment variable NAME, or "unset"

Prints "listening on PORT" once it serves, and one line per request. Output is flushed at once, so the test can
read it from the app's log while the app runs.
"""

import argparse
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--delay", type=float, default=0)
    parser.add_argument("--exit", type=int, default=None)
    parser.add_argument("--child", action="store_true")
    parser.add_argument("--escape", action="store_true")
    parser.add_argument("--body-env", default=None)
    args = parser.parse_args()

    print(f"stub app starting (pid {os.getpid()})", flush=True)
    if args.exit is not None:
        print("stub app crashing", flush=True)
        sys.exit(args.exit)
    if args.child:
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
        print(f"child {child.pid}", flush=True)
    if args.escape:
        serve = [sys.executable, __file__, str(args.port), "--status", str(args.status)]
        escaped = subprocess.Popen(serve, start_new_session=True, stdout=sys.stdout, stderr=sys.stderr)
        print(f"escaped {escaped.pid}", flush=True)
        time.sleep(600)
        return
    if args.delay:
        time.sleep(args.delay)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = (os.environ.get(args.body_env, "unset") if args.body_env else "ok").encode("utf-8")
            self.send_response(args.status)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *values):  # noqa: A002 - the base class's signature
            print("request " + format % values, flush=True)

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"listening on {args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
