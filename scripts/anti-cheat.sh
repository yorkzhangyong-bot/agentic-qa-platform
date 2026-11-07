#!/usr/bin/env bash
# anti-cheat.sh — fail the job if an agent "fixed" tests by cheating instead of repairing them.
#
# Usage:  anti-cheat.sh [FORBIDDEN_PATHS] [BASE_REF]
#   FORBIDDEN_PATHS  comma-separated paths or globs that must not change, e.g. "src/,cypress/support/commands.*"
#                    (default: $FORBIDDEN_PATHS). ".github/" is always forbidden.
#   BASE_REF         commit-ish to compare the working tree with (default: $BASE_REF, then origin/main).
#                    Untracked files are included unless they are git-ignored or in .git/info/exclude.
#
# The diff fails when it:
#   - touches a forbidden path;
#   - removes a line containing expect( / assert / .should( that is not re-added unchanged
#     (an assertion line that only changes the locator inside it is allowed);
#   - changes toBe / toEqual / toHaveText to toBeTruthy / toBeDefined;
#   - adds .skip, .only, xit, xdescribe, @Disabled or @Ignore;
#   - adds waitForTimeout, cy.wait(<number>) or Thread.sleep.
# Exit codes: 0 = clean, 1 = violations, 2 = usage or git error.
set -euo pipefail

forbidden="${1:-${FORBIDDEN_PATHS:-}}"
base="${2:-${BASE_REF:-origin/main}}"

command -v python3 >/dev/null 2>&1 || { echo "anti-cheat: python3 is required" >&2; exit 2; }
top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "anti-cheat: not inside a git repository" >&2; exit 2; }
cd "$top"
if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
  echo "anti-cheat: base ref '${base}' not found. Fetch it (git fetch origin main) or pass a commit SHA." >&2
  exit 2
fi

python3 - "$forbidden" "$base" <<'PY'
import fnmatch
import os
import re
import subprocess
import sys
from collections import Counter

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

forbidden_arg, base = sys.argv[1], sys.argv[2]
FORBIDDEN = [p.strip() for p in forbidden_arg.split(",") if p.strip()] + [".github/"]
CODE_EXT = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".java", ".kt", ".groovy", ".py", ".cs"}

ASSERTION = re.compile(r"\bexpect(?:\.soft|\.poll)?\s*\(|\b(?:assert|Assert)|\.should\s*\(")
STRONG = re.compile(r"\.(?:not\.)?(?:toBe|toEqual|toStrictEqual|toHaveText)\s*\(")
WEAK = re.compile(r"\.(?:not\.)?(?:toBeTruthy|toBeDefined)\s*\(")
ADDED_RULES = [
    ("disabled test", re.compile(r"\.(?:skip|only)\b"), "adds .skip/.only, which disables or focuses tests"),
    ("disabled test", re.compile(r"\b(?:xit|xdescribe)\s*\("), "adds xit/xdescribe, which disables tests"),
    ("disabled test", re.compile(r"@(?:Disabled|Ignore)\b"), "adds @Disabled/@Ignore, which disables tests"),
    ("fixed sleep", re.compile(r"\bwaitForTimeout\s*\("), "adds waitForTimeout (fixed sleep)"),
    ("fixed sleep", re.compile(r"\bcy\.wait\s*\(\s*\d"), "adds cy.wait(<number>) (fixed sleep)"),
    ("fixed sleep", re.compile(r"\bThread\.sleep\s*\("), "adds Thread.sleep (fixed sleep)"),
]
# Locator expressions the healer is allowed to change inside an assertion line.
LOCATOR_CALL = re.compile(
    r"(?<![\w$])(?:"
    r"cy\.get"
    r"|(?:(?:this\.)?(?:page|driver|browser|screen|frame)\.)?"
    r"(?:(?:get|query|find)(?:All)?By[A-Z]\w*|locator|frameLocator|findElements?|By\.\w+)"
    r"|(?<=\.)(?:filter|nth|first|last|find)"
    r")\s*\("
)
STRING = re.compile(r"""'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`""")
HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def git(*args):
    proc = subprocess.run(["git", *args], capture_output=True)
    if proc.returncode != 0:
        print(f"anti-cheat: git {' '.join(args)} failed: {proc.stderr.decode('utf-8', 'replace').strip()}", file=sys.stderr)
        sys.exit(2)
    return proc.stdout.decode("utf-8", "replace")


def mask_strings(s):
    """Blank out string contents but keep their length, so indexes still line up with the original."""
    return STRING.sub(lambda m: m.group(0)[0] + "_" * (len(m.group(0)) - 2) + m.group(0)[-1], s)


def split_code(line, ext):
    """Return (code, masked_code) without comments, or ("", "") for blank and comment-only lines."""
    raw = line.rstrip("\r")
    stripped = raw.strip()
    if not stripped or stripped.startswith(("//", "/*", "*")) or (ext == ".py" and stripped.startswith("#")):
        return "", ""
    masked = mask_strings(raw)
    cut = masked.find("#" if ext == ".py" else "//")
    if cut >= 0:
        raw, masked = raw[:cut], masked[:cut]
    return raw.strip(), masked.strip()


def find_close(s, start):
    depth = 0
    for i in range(start, len(s)):
        if s[i] in "([{":
            depth += 1
        elif s[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def normalize(code):
    """Canonical form of an assertion line: locators, await, whitespace and { timeout } options don't matter."""
    s = " ".join(code.split())
    s = re.sub(r"\bawait\s+", "", s)
    s = re.sub(r",?\s*\{\s*timeout\s*:\s*[\w.$]+\s*\}", "", s)
    masked = mask_strings(s)
    out, pos = [], 0
    for m in LOCATOR_CALL.finditer(masked):
        if m.start() < pos:
            continue
        close = find_close(masked, m.end() - 1)
        if close < 0:
            continue
        out.append(s[pos:m.start()])
        out.append("<locator>")
        pos = close + 1
    out.append(s[pos:])
    s = re.sub(r"<locator>(?:\s*\.\s*<locator>)+", "<locator>", "".join(out))
    return s.rstrip(";").strip()


def matcher_subject(code, matcher):
    """The normalized part of an assertion before its matcher, e.g. "expect(<locator>)"."""
    norm = normalize(code)
    m = matcher.search(norm)
    return norm[:m.start()] if m else None


def diff_lines(path):
    removed, added = [], []
    old = new = 0
    in_hunk = False
    for line in git("diff", "--no-color", "--no-ext-diff", "--no-renames", "-U0", base, "--", path).split("\n"):
        m = HUNK.match(line)
        if m:
            old, new, in_hunk = int(m.group(1)), int(m.group(2)), True
        elif line.startswith("diff --git"):
            in_hunk = False
        elif in_hunk and line.startswith("-"):
            removed.append((old, line[1:]))
            old += 1
        elif in_hunk and line.startswith("+"):
            added.append((new, line[1:]))
            new += 1
    return removed, added


def forbidden_match(path):
    for pattern in FORBIDDEN:
        p = pattern[2:] if pattern.startswith("./") else pattern
        if p.endswith("/"):
            if path.startswith(p):
                return pattern
        elif any(ch in p for ch in "*?["):
            if fnmatch.fnmatchcase(path, p) or fnmatch.fnmatchcase(path, p + "/*"):
                return pattern
        elif path == p or path.startswith(p + "/"):
            return pattern
    return None


changes = []
raw = git("diff", "--name-status", "--no-renames", "-z", base, "--").split("\0")
for status, path in zip(raw[0::2], raw[1::2]):
    if status and path:
        changes.append((status[0], path))
for path in git("ls-files", "--others", "--exclude-standard", "-z").split("\0"):
    if path:
        changes.append(("?", path))

violations = []


def flag(rule, path, line, message, snippet=""):
    violations.append((rule, path, line, message, " ".join(snippet.split())[:160]))


for status, path in changes:
    hit = forbidden_match(path)
    if hit:
        flag("forbidden path", path, None, f"touches forbidden path '{hit}'")
    ext = os.path.splitext(path)[1].lower()
    if ext not in CODE_EXT:
        continue
    if status == "?":
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if b"\0" in data[:8192] or len(data) > 2_000_000:
            continue
        removed, added = [], list(enumerate(data.decode("utf-8", "replace").split("\n"), 1))
    else:
        removed, added = diff_lines(path)

    rem = [(n, *split_code(text, ext)) for n, text in removed]
    add = [(n, *split_code(text, ext)) for n, text in added]

    # Every removed assertion must come back unchanged; only the locator inside it may differ.
    available = Counter(normalize(code) for _, code, masked in add if code and ASSERTION.search(masked))
    missing = []
    for n, code, masked in rem:
        if code and ASSERTION.search(masked):
            key = normalize(code)
            if available[key] > 0:
                available[key] -= 1
            else:
                missing.append((n, code))

    # A weak matcher replacing a strong one on the same subject is reported as a weakened assertion;
    # every other removed or changed assertion is reported below.
    strong_removed = [(n, code, matcher_subject(code, STRONG)) for n, code, masked in rem if code and STRONG.search(masked)]
    explained = set()
    for n, code, masked in add:
        if code and WEAK.search(masked):
            subject = matcher_subject(code, WEAK)
            match = next((r for r in strong_removed if r[2] == subject and r[0] not in explained), None)
            if match:
                explained.add(match[0])
                flag("weakened assertion", path, n,
                     f"changes toBe/toEqual/toHaveText to toBeTruthy/toBeDefined (was: {' '.join(match[1].split())})", code)
    missing = [(n, code) for n, code in missing if n not in explained]
    for n, code in missing:
        flag("removed assertion", path, None,
             f"removes or changes an assertion (base line {n}); only the locator inside an assertion may change", code)

    for n, code, masked in add:
        if not code:
            continue
        for rule, pattern, message in ADDED_RULES:
            if pattern.search(masked):
                flag(rule, path, n, message, code)

print(f"anti-cheat: compared the working tree with {base}: {len(changes)} changed file(s)")
for status, path in changes[:50]:
    print(f"  {status} {path}")
if len(changes) > 50:
    print(f"  ... and {len(changes) - 50} more")

if not violations:
    print("anti-cheat: PASSED (no forbidden paths, removed or weakened assertions, skipped tests or fixed sleeps)")
    sys.exit(0)

print(f"\nanti-cheat: FAILED with {len(violations)} violation(s)\n")
for rule in dict.fromkeys(v[0] for v in violations):
    print(f"[{rule}]")
    for _, path, line, message, snippet in (v for v in violations if v[0] == rule):
        print(f"  {path}{':' + str(line) if line else ''}  {message}")
        if snippet:
            print(f"      {snippet}")
    print()

if os.environ.get("GITHUB_ACTIONS") == "true":
    def prop(value):
        return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A").replace(":", "%3A").replace(",", "%2C")

    for rule, path, line, message, _ in violations:
        location = f"file={prop(path)}" + (f",line={line}" if line else "")
        print(f"::error {location},title={prop('anti-cheat (' + rule + ')')}::{message.replace('%', '%25')}")

print("The workflow will not open a pull request. Revert or fix the offending changes.")
sys.exit(1)
PY
