#!/usr/bin/env bash
# anti-cheat.sh — fail the job if an agent "fixed" tests by cheating instead of repairing them.
#
# Usage:  anti-cheat.sh [FORBIDDEN_PATHS] [BASE_REF]
#   FORBIDDEN_PATHS  comma-separated paths or globs from the framework config, e.g. "src/,cypress/support/commands.*"
#                    (default: $FORBIDDEN_PATHS)
#   BASE_REF         commit-ish to compare the working tree with (default: $BASE_REF, then origin/main).
#                    Untracked files are included unless they are git-ignored or listed in .git/info/exclude.
#
# Always forbidden, in addition to FORBIDDEN_PATHS (patterns without "/" match the file name at any depth):
#   .github/  *.config.{ts,js,mjs,cjs}  playwright.config.*  cypress.config.*  package.json  package-lock.json
#   pnpm-lock.yaml  yarn.lock  pom.xml  build.gradle*  tsconfig*.json  .env*
#
# The diff fails when it:
#   [forbidden path]              touches a forbidden path
#   [removed assertion]           removes or changes an assertion line: expect(…), assert(…) / assertEquals(…)-style
#                                 calls, Assert.…(…), Assertions.…(…), assert.…(…), an assert statement or .should(…).
#                                 Allowed only if the line is re-added with just its locator, await, whitespace or
#                                 { timeout } option changed.
#   [weakened assertion]          replaces toBe / toEqual / toStrictEqual / toHaveText with toBeTruthy / toBeDefined
#   [try/catch around assertion]  adds try or catch (including .catch) within 5 lines of an assertion
#   [disabled test]               adds .skip, .only, .fixme, xit, xdescribe, xtest, xcontext, xspecify, fit, fdescribe,
#                                 @Disabled…, @Ignore or @Test(enabled = false)
#   [test config]                 adds test.describe.configure(…) or test.slow()
#   [fixed sleep]                 adds waitForTimeout, cy.wait(<number>), cy.wait(Cypress.env(…)), Thread.sleep,
#                                 TimeUnit.*.sleep or setTimeout (e.g. new Promise(r => setTimeout(r, ms)))
#   [long timeout]                adds or raises a timeout above 60000 ms: timeout: N, { timeout: N },
#                                 setDefaultTimeout(N), setDefaultNavigationTimeout(N), test.setTimeout(N),
#                                 Duration.ofMillis/ofSeconds/ofMinutes(N)
#
# Residual risk: an assertion re-targeted to a different element (only its locator changed) passes. Such lines are
# listed under "review needed" so a human can confirm they still check the intended element.
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

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

forbidden_arg, base = sys.argv[1], sys.argv[2]

ALWAYS_FORBIDDEN = [
    ".github/", "*.config.{ts,js,mjs,cjs}", "playwright.config.*", "cypress.config.*",
    "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
    "pom.xml", "build.gradle*", "tsconfig*.json", ".env*",
]
FORBIDDEN = [p.strip() for p in forbidden_arg.split(",") if p.strip()] + ALWAYS_FORBIDDEN
CODE_EXT = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".java", ".kt", ".groovy", ".py", ".cs"}
TIMEOUT_LIMIT_MS = 60000
TRY_WINDOW = 5

# Assertion calls only: identifiers such as `assertion` or `assertive`, and import lines, don't count.
ASSERTION = re.compile(
    r"\bexpect(?:\.soft|\.poll)?\s*\("             # expect(…), expect.soft(…), expect.poll(…)
    r"|\bassert(?:[A-Z]\w*)?\s*\("                # assert(…), assertEquals(…), assertThat(…), assertTrue(…)
    r"|\bassert\s+[^\s=(:]"                        # assert statement: assert x > 0
    r"|\b(?:Assert|Assertions|assert)\.\w+\s*\("   # Assert.assertEquals(…), Assertions.assertTrue(…), assert.equal(…)
    r"|\.should\s*\("                              # Cypress chainers
)
IMPORT_LINE = re.compile(r"^(?:import|from)\s")
STRONG = re.compile(r"\.(?:not\.)?(?:toBe|toEqual|toStrictEqual|toHaveText)\s*\(")
WEAK = re.compile(r"\.(?:not\.)?(?:toBeTruthy|toBeDefined)\s*\(")
FREE = r"(?<![\w$.])"  # a free function call, not a method such as obj.fit(…)
ADDED_RULES = [
    ("disabled test", re.compile(r"\.(?:skip|only)\b"),
     "adds .skip/.only (e.g. test.skip, it.only, describe.skip), which disables or focuses tests"),
    ("disabled test", re.compile(r"\.fixme\b"), "adds .fixme, which skips the test as known-broken"),
    ("disabled test", re.compile(FREE + r"(?:xit|xdescribe|xtest|xcontext|xspecify)\s*\("),
     "adds xit/xdescribe/xtest/xcontext/xspecify, which disables tests"),
    ("disabled test", re.compile(FREE + r"(?:fit|fdescribe)\s*\("), "adds fit/fdescribe, which skips every other test"),
    ("disabled test", re.compile(r"@(?:Disabled\w*|Ignore)\b"), "adds @Disabled/@Ignore, which disables tests"),
    ("disabled test", re.compile(r"@Test\s*\([^)]*\benabled\s*=\s*false"), "adds @Test(enabled = false), which disables a TestNG test"),
    ("test config", re.compile(r"\btest\.describe\.configure\s*\("),
     "adds test.describe.configure(), which can change retries, mode and timeouts"),
    ("test config", re.compile(r"\btest\.slow\s*\("), "adds test.slow(), which triples the test timeout"),
    ("fixed sleep", re.compile(r"\bwaitForTimeout\s*\("), "adds waitForTimeout (fixed sleep)"),
    ("fixed sleep", re.compile(r"\bcy\.wait\s*\(\s*\d"), "adds cy.wait(<number>) (fixed sleep)"),
    ("fixed sleep", re.compile(r"\bcy\.wait\s*\(\s*Cypress\.env\s*\("), "adds cy.wait(Cypress.env(...)) (fixed sleep)"),
    ("fixed sleep", re.compile(r"\bThread\.sleep\s*\("), "adds Thread.sleep (fixed sleep)"),
    ("fixed sleep", re.compile(r"\bTimeUnit\.\w+\.sleep\s*\("), "adds TimeUnit.*.sleep (fixed sleep)"),
    ("fixed sleep", re.compile(FREE + r"setTimeout\s*\(|\b(?:window|globalThis)\.setTimeout\s*\("),
     "adds setTimeout (timer-based sleep, e.g. new Promise(r => setTimeout(r, ms)))"),
]
TRY_CATCH = re.compile(r"\btry\b|\bcatch\b")
NUMBER = r"(\d[\d_]*(?:\s*\*\s*\d[\d_]*)*)"  # 90000, 90_000 or 2 * 60 * 1000
TIMEOUTS = [
    re.compile(r"\btimeout\s*:\s*" + NUMBER),
    re.compile(r"\b(?:setDefaultTimeout|setDefaultNavigationTimeout)\s*\(\s*" + NUMBER),
    re.compile(r"(?<=\.)setTimeout\s*\(\s*" + NUMBER),  # test.setTimeout(N); a bare setTimeout() is a sleep
]
DURATION = re.compile(r"\bDuration\.of(Millis|Seconds|Minutes)\s*\(\s*(\d[\d_]*)L?\s*\)")
DURATION_MS = {"Millis": 1, "Seconds": 1000, "Minutes": 60000}
# Locator expressions the healer may change inside an assertion line.
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


def expand_braces(pattern):
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    return [x for alt in m.group(1).split(",") for x in expand_braces(pattern[:m.start()] + alt + pattern[m.end():])]


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


def is_assertion(code, masked):
    return bool(code) and bool(ASSERTION.search(masked)) and not IMPORT_LINE.match(masked)


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


def normalize(code, locators=True):
    """Canonical form of an assertion line: await, whitespace and { timeout } options don't matter, and with
    locators=True neither do the locators inside it."""
    s = " ".join(code.split())
    s = re.sub(r"\bawait\s+", "", s)
    s = re.sub(r",?\s*\{\s*timeout\s*:\s*[\w.$]+\s*\}", "", s)
    if not locators:
        return s.rstrip(";").strip()
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


def to_ms(expr):
    value = 1
    for part in expr.split("*"):
        value *= int(part.strip().replace("_", ""))
    return value


def timeout_values(masked):
    values = [to_ms(m.group(1)) for rx in TIMEOUTS for m in rx.finditer(masked)]
    values += [int(m.group(2).replace("_", "")) * DURATION_MS[m.group(1)] for m in DURATION.finditer(masked)]
    return values


def timeout_shape(masked):
    return " ".join(re.sub(r"\d[\d_]*", "#", masked).split())


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


def read_text(path):
    """Working-tree content: "" for a deleted file, None for binary or very large files."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return ""
    except OSError:
        return None
    if b"\0" in data[:8192] or len(data) > 2_000_000:
        return None
    return data.decode("utf-8", "replace")


def forbidden_match(path):
    name = path.rsplit("/", 1)[-1]
    for pattern in FORBIDDEN:
        for p in expand_braces(pattern[2:] if pattern.startswith("./") else pattern):
            if p.endswith("/"):
                hit = path.startswith(p)
            elif "/" in p:
                hit = fnmatch.fnmatchcase(path, p) or path.startswith(p + "/")
            else:
                hit = fnmatch.fnmatchcase(name, p) or fnmatch.fnmatchcase(path, p)
            if hit:
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
retargeted = []


def flag(rule, path, line, message, snippet=""):
    violations.append((rule, path, line, message, " ".join(snippet.split())[:160]))


for status, path in changes:
    hit = forbidden_match(path)
    if hit:
        flag("forbidden path", path, None, f"touches forbidden path '{hit}'")
    ext = os.path.splitext(path)[1].lower()
    if ext not in CODE_EXT:
        continue
    new_text = read_text(path)
    if new_text is None:
        continue
    if status == "?":
        removed, added = [], list(enumerate(new_text.split("\n"), 1))
    else:
        removed, added = diff_lines(path)

    rem = [(n, *split_code(text, ext)) for n, text in removed]
    add = [(n, *split_code(text, ext)) for n, text in added]
    new_is_assertion = [is_assertion(*split_code(line, ext)) for line in new_text.split("\n")] if new_text else []

    # Every removed assertion must come back; only its locator (and await/whitespace/{ timeout }) may differ.
    available = {}
    for n, code, masked in add:
        if is_assertion(code, masked):
            available.setdefault(normalize(code), []).append((n, code))
    missing = []
    for n, code, masked in rem:
        if not is_assertion(code, masked):
            continue
        candidates = available.get(normalize(code))
        if candidates:
            new_n, new_code = candidates.pop(0)
            if normalize(new_code, locators=False) != normalize(code, locators=False):
                retargeted.append((path, new_n, " ".join(new_code.split())[:160]))
        else:
            missing.append((n, code))

    # A weak matcher replacing a strong one on the same subject is reported as a weakened assertion.
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
    for n, code in missing:
        if n not in explained:
            flag("removed assertion", path, None,
                 f"removes or changes an assertion (base line {n}); only the locator inside an assertion may change", code)

    for n, code, masked in add:
        if not code:
            continue
        for rule, pattern, message in ADDED_RULES:
            if pattern.search(masked):
                flag(rule, path, n, message, code)
        if TRY_CATCH.search(masked):
            lo, hi = max(1, n - TRY_WINDOW), min(len(new_is_assertion), n + TRY_WINDOW)
            if any(new_is_assertion[i - 1] for i in range(lo, hi + 1)):
                flag("try/catch around assertion", path, n,
                     f"adds try/catch within {TRY_WINDOW} lines of an assertion, which can swallow its failure", code)

    # Timeouts above the limit may only stay where the same line already had an equal or higher value.
    previous = {}
    for _, code, masked in rem:
        values = timeout_values(masked)
        if values:
            shape = timeout_shape(masked)
            previous[shape] = max(previous.get(shape, 0), max(values))
    for n, code, masked in add:
        values = [v for v in timeout_values(masked) if v > TIMEOUT_LIMIT_MS]
        if values and previous.get(timeout_shape(masked), -1) < max(values):
            flag("long timeout", path, n, f"sets a timeout of {max(values)} ms (limit {TIMEOUT_LIMIT_MS} ms)", code)

print(f"anti-cheat: compared the working tree with {base}: {len(changes)} changed file(s)")
for status, path in changes[:50]:
    print(f"  {status} {path}")
if len(changes) > 50:
    print(f"  ... and {len(changes) - 50} more")

if retargeted:
    print("\nanti-cheat: review needed: locators changed inside assertions. This script cannot tell whether the new")
    print("locator still points at the intended element (residual risk); a reviewer must check each line:")
    for path, line, code in retargeted:
        print(f"  {path}:{line}  {code}")

if not violations:
    print("\nanti-cheat: PASSED (no forbidden paths, removed or weakened assertions, try/catch around assertions,")
    print("disabled tests, test config changes, fixed sleeps or long timeouts)")
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
