#!/usr/bin/env bash
# locator-check.sh — after healing, check that every locator the healer changed still points to the same kind of
# element: the same role and accessible name as before. A script compares them, not an agent.
#
#   before  what the old locator asked for, found on the failing run's page snapshot (error-context.md); where the
#           page no longer has it, what the old locator itself names (getByRole with a name). Unknown for a test ID,
#           CSS or XPath, which a page snapshot can't show, and for a locator built from variables.
#   after   the element the new locator resolved to in the heal job's verification run, as recorded by the probe
#           (scripts/locator-probe/<framework>.cjs).
#
# The role must match exactly; the accessible name after normalising whitespace and case. For an element without an
# accessible name, such as a paragraph, its text stands in for the name. LOCATOR_RENAMES accepts listed name changes;
# each use is logged. Only a mismatch makes the pull request a draft: an unknown side is shown for a reviewer to
# confirm. Playwright only so far: another framework needs an adapter below, and a probe.
#
# Usage:  locator-check.sh targets   before the verification run: list the changed locators for the probe
#         locator-check.sh report    after it: compare, write the "Locator check" section
# Environment:
#   FRAMEWORK          framework name, as in frameworks/<name>.json (default playwright)
#   TEST_DIR           test directory: the healer's diff is read there (default tests)
#   BASE_SHA           the commit the healer started from (default HEAD)
#   PLATFORM_DIR       agentic-qa-platform checkout, for the probe's path (default .agentic-qa)
#   LOCATOR_CHECK_DIR  working folder outside the workspace (default $RUNNER_TEMP/locator-check):
#                        targets.json        written by targets: each changed locator, old and new
#                        probe-targets.json  the new locators as Playwright describes them, for the probe
#                        after.jsonl         written by the probe during the verification run
#                        before/             the failing run: results/failures.json and the error-context.md files
#                                            under test-results/, freshly downloaded so no agent touched them
#   LOCATOR_RENAMES    accepted accessible-name changes, one "old -> new" per line
#   PR_BODY            pull request body the section is appended to, if it exists (default PR_BODY.md)
# Writes (report): results/locator-check.json and results/locator-check.md, the section in PR_BODY and in
# $GITHUB_STEP_SUMMARY. Outputs ($GITHUB_OUTPUT, also printed):
#   targets  supported=true|false, count=<changed locators>, probe=<absolute path of the probe, or empty>
#   report   status=pass|mismatch|unknown|none|unsupported, draft=true|false, mismatches=<n>, unknown=<n>
# Exit code: 0, also when locators differ; 2 for a usage error.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  targets|report) ;;
  *) echo "usage: locator-check.sh targets|report" >&2; exit 2 ;;
esac
command -v python3 > /dev/null 2>&1 || { echo "locator-check: python3 is required" >&2; exit 2; }

python3 - "$mode" <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")
MODE = sys.argv[1]
FRAMEWORK = (os.environ.get("FRAMEWORK") or "playwright").strip()
TEST_DIR = (os.environ.get("TEST_DIR") or "tests").strip().strip("/") or "."
BASE = (os.environ.get("BASE_SHA") or "HEAD").strip()
PLATFORM = Path(os.environ.get("PLATFORM_DIR") or ".agentic-qa")
WORK = Path(os.environ.get("LOCATOR_CHECK_DIR") or Path(os.environ.get("RUNNER_TEMP") or "/tmp") / "locator-check")
PR_BODY = Path(os.environ.get("PR_BODY") or "PR_BODY.md")
RESULTS = Path("results")
SOURCES = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs")


def say(text):
    print(f"locator-check: {text}", flush=True)


def output(**values):
    lines = [f"{key}={value}" for key, value in values.items()]
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    for line in lines:
        say(line)


def git(*args):
    proc = subprocess.run(["git", *args], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode:
        sys.exit(f"locator-check: git {' '.join(args)} failed: {proc.stderr.strip()[:300]}")
    return proc.stdout


def norm(text):
    return " ".join(str(text).split())


# --- JavaScript and TypeScript locator expressions ---------------------------------------------------------------

STARTERS = ("getByRole", "getByText", "getByLabel", "getByPlaceholder", "getByAltText", "getByTitle", "getByTestId",
            "locator", "frameLocator")
MODIFIERS = ("first", "last", "nth", "filter", "and", "or", "contentFrame")
TEXT_KINDS = {"getByText": "text", "getByLabel": "label", "getByPlaceholder": "placeholder",
              "getByAltText": "alt", "getByTitle": "title"}
ROLE_ATTRS = ("checked", "disabled", "selected", "expanded", "includeHidden", "level", "pressed")  # Playwright's order
DYNAMIC = object()   # a value only known at run time: a variable, a call, a template literal with ${…}
OPAQUE = "\0opaque"  # marks an object literal with an entry the script can't read
IDENT = re.compile(r"[A-Za-z_$][\w$]*")
NUMBER = re.compile(r"\d+(?:\.\d+)?")
ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}
REGEX_BEFORE = set("(,=:[!&|?{};+-*%<>~^")


class Token:
    def __init__(self, kind, value, start, end):
        self.kind, self.value, self.start, self.end = kind, value, start, end

    def punct(self, char):
        return self.kind == "punct" and self.value == char


class Regex:
    def __init__(self, source):
        body, _, flags = source[1:].rpartition("/")
        self.pattern, self.flags = body, "".join(sorted(flags, key="dgimsuvy".find))

    def source(self):  # as Playwright prints it: String(re), without needless escapes before quotes
        return re.sub(r"(^|[^\\])((?:\\\\)*)\\(['\"`])", r"\1\2\3", f"/{self.pattern}/{self.flags}")

    def search(self, text):
        flags = (re.I if "i" in self.flags else 0) | (re.S if "s" in self.flags else 0) | (re.M if "m" in self.flags else 0)
        try:
            return re.search(self.pattern, text or "", flags) is not None
        except re.error:
            return False


class Chain:
    """root.locatorMethod(args).modifier(args)…: steps are (method, args); tail_start is where the first method is."""
    def __init__(self, root, steps, start, tail_start, end):
        self.root, self.steps, self.start, self.tail_start, self.end = root, steps, start, tail_start, end


def decode(raw):
    out, i = [], 0
    while i < len(raw):
        ch = raw[i]
        if ch != "\\" or i + 1 >= len(raw):
            out.append(ch)
            i += 1
            continue
        nxt = raw[i + 1]
        try:
            if nxt in ESCAPES:
                out.append(ESCAPES[nxt])
                i += 2
            elif nxt == "x" and re.fullmatch(r"[0-9a-fA-F]{2}", raw[i + 2:i + 4]):
                out.append(chr(int(raw[i + 2:i + 4], 16)))
                i += 4
            elif nxt == "u" and raw[i + 2:i + 3] == "{":
                end = raw.index("}", i + 3)
                out.append(chr(int(raw[i + 3:end], 16)))
                i = end + 1
            elif nxt == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", raw[i + 2:i + 6]):
                out.append(chr(int(raw[i + 2:i + 6], 16)))
                i += 6
            elif nxt in "\r\n":
                i += 3 if raw[i + 1:i + 3] == "\r\n" else 2
            else:
                out.append(nxt)
                i += 2
        except ValueError:
            out.append(nxt)
            i += 2
    text = "".join(out)
    try:  # join surrogate pairs from 😀 escapes
        return text.encode("utf-16", "surrogatepass").decode("utf-16")
    except UnicodeError:
        return text


def tokenize(text):
    toks, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif ch in "'\"":
            j, raw = i + 1, []
            while j < n and text[j] not in (ch, "\n"):
                raw.append(text[j:j + 2] if text[j] == "\\" else text[j])
                j += 2 if text[j] == "\\" else 1
            toks.append(Token("str", decode("".join(raw)), i, min(j + 1, n)))
            i = min(j + 1, n)
        elif ch == "`":
            j, raw, dynamic = i + 1, [], False
            while j < n and text[j] != "`":
                if text[j] == "\\":
                    raw.append(text[j:j + 2])
                    j += 2
                elif text.startswith("${", j):
                    dynamic, depth, j = True, 1, j + 2
                    while j < n and depth:
                        depth += {"{": 1, "}": -1}.get(text[j], 0)
                        j += 1
                else:
                    raw.append(text[j])
                    j += 1
            toks.append(Token("str", None if dynamic else decode("".join(raw)), i, min(j + 1, n)))
            i = min(j + 1, n)
        elif ch == "/" and (not toks or (toks[-1].kind == "punct" and toks[-1].value in REGEX_BEFORE)
                            or (toks[-1].kind == "ident" and toks[-1].value in ("return", "typeof", "case"))):
            j, in_class = i + 1, False
            while j < n and text[j] != "\n":
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == "[":
                    in_class = True
                elif text[j] == "]":
                    in_class = False
                elif text[j] == "/" and not in_class:
                    break
                j += 1
            if j < n and text[j] == "/":
                j += 1
                while j < n and text[j].isalpha():
                    j += 1
                toks.append(Token("regex", text[i:j], i, j))
                i = j
            else:
                toks.append(Token("punct", ch, i, i + 1))
                i += 1
        elif IDENT.match(text, i):
            m = IDENT.match(text, i)
            toks.append(Token("ident", m.group(), i, m.end()))
            i = m.end()
        elif NUMBER.match(text, i):
            m = NUMBER.match(text, i)
            toks.append(Token("num", m.group(), i, m.end()))
            i = m.end()
        else:
            toks.append(Token("punct", ch, i, i + 1))
            i += 1
    return toks


def skip(toks, j):
    """Index of the next ',', ')' or '}' at this nesting depth."""
    depth = 0
    while j < len(toks):
        t = toks[j]
        if t.kind == "punct" and t.value in "([{":
            depth += 1
        elif t.kind == "punct" and t.value in ")]}":
            if depth == 0:
                return j
            depth -= 1
        elif t.punct(",") and depth == 0:
            return j
        j += 1
    return j


def parse_value(toks, k):
    t, value, j = toks[k], DYNAMIC, k + 1
    if t.kind == "str":
        value = DYNAMIC if t.value is None else t.value
    elif t.kind == "regex":
        value = Regex(t.value)
    elif t.kind == "num":
        value = float(t.value) if "." in t.value else int(t.value)
    elif t.punct("-") and k + 1 < len(toks) and toks[k + 1].kind == "num" and "." not in toks[k + 1].value:
        value, j = -int(toks[k + 1].value), k + 2
    elif t.kind == "ident" and t.value in ("true", "false"):
        value = t.value == "true"
    elif t.punct("{"):
        value, j = parse_object(toks, k)
    elif t.kind == "ident":
        chain, end = parse_chain(toks, k)
        if chain is not None:
            value, j = chain, end
    if j < len(toks) and not (toks[j].punct(",") or toks[j].punct(")") or toks[j].punct("}")):
        value, j = DYNAMIC, skip(toks, j)  # part of a bigger expression, e.g. 'a' + b
    return value, j


def parse_object(toks, k):
    obj, j = {}, k + 1
    while j < len(toks) and not toks[j].punct("}"):
        key = toks[j]
        if key.kind in ("ident", "str") and key.value is not None and j + 1 < len(toks) and toks[j + 1].punct(":"):
            obj[key.value], j = parse_value(toks, j + 2)
        else:  # shorthand, spread or computed key
            obj[OPAQUE] = DYNAMIC
            j = skip(toks, j)
        if j < len(toks) and toks[j].punct(","):
            j += 1
    return obj, j + 1


def parse_args(toks, k):
    args = []
    while k < len(toks) and not toks[k].punct(")"):
        value, k = parse_value(toks, k)
        args.append(value)
        if k < len(toks) and toks[k].punct(","):
            k += 1
    return args, min(k + 1, len(toks))


def parse_chain(toks, i):
    """The locator chain that starts at the identifier toks[i], and the index after it; (None, i + 1) if none."""
    root, steps, tail_start, j = [toks[i].value], [], None, i + 1
    while j + 1 < len(toks) and toks[j].punct(".") and toks[j + 1].kind == "ident":
        name = toks[j + 1].value
        if not (j + 2 < len(toks) and toks[j + 2].punct("(")):
            if steps:
                break
            root.append(name)
            j += 2
            continue
        if name not in STARTERS and not (steps and name in MODIFIERS):
            break
        if not steps:
            tail_start = toks[j + 1].start  # the first locator method, right after "<root>."
        args, j = parse_args(toks, j + 3)
        steps.append((name, args))
    if not steps:
        return None, i + 1
    return Chain(".".join(root), steps, toks[i].start, tail_start, toks[j - 1].end), j


def find_chains(text):
    toks, found, i = tokenize(text), [], 0
    while i < len(toks):
        if toks[i].kind == "ident" and not (i and toks[i - 1].punct(".")):
            chain, i = parse_chain(toks, i)
            if chain is not None:
                found.append(chain)
            continue
        i += 1
    return found


def js_quote(text):  # Playwright's escapeWithQuotes(text, "'")
    body = json.dumps(text, ensure_ascii=False)[1:-1].replace('\\"', '"')
    return "'" + body.replace("'", "\\'") + "'"


def text_arg(value):
    if isinstance(value, str):
        return js_quote(value)
    if isinstance(value, Regex):
        return value.source()
    return None


def is_xpath(selector):
    return selector.startswith(("//", "..", "xpath=", "(//"))


def canonical_step(name, args):
    if any(arg is DYNAMIC or (isinstance(arg, dict) and OPAQUE in arg) for arg in args):
        return None
    if name == "getByRole":
        options = args[1] if len(args) > 1 else {}
        if not args or not isinstance(args[0], str) or not isinstance(options, dict) or len(args) > 2:
            return None
        if set(options) - {"name", "description", "exact", *ROLE_ATTRS}:
            return None
        attrs = []
        for key in ("name", "description"):
            if key in options:
                text = text_arg(options[key])
                if text is None:
                    return None
                attrs.append(f"{key}: {text}")
        if options.get("exact") is True and (isinstance(options.get("name"), str) or
                                             isinstance(options.get("description"), str)):
            attrs.append("exact: true")
        for key in ROLE_ATTRS:
            if key not in options:
                continue
            value = options[key]
            if isinstance(value, bool):
                attrs.append(f"{key}: {'true' if value else 'false'}")
            elif isinstance(value, int) and key == "level":
                attrs.append(f"level: {value}")
            elif isinstance(value, str):
                attrs.append(f"{key}: {js_quote(value)}")
            else:
                return None
        return f"getByRole({js_quote(args[0])}" + (", { " + ", ".join(attrs) + " }" if attrs else "") + ")"
    if name in TEXT_KINDS:
        options = args[1] if len(args) > 1 else {}
        text = text_arg(args[0]) if args else None
        if text is None or not isinstance(options, dict) or set(options) - {"exact"} or len(args) > 2:
            return None
        return f"{name}({text}, {{ exact: true }})" if isinstance(args[0], str) and options.get("exact") is True \
            else f"{name}({text})"
    if name == "getByTestId":
        text = text_arg(args[0]) if len(args) == 1 else None
        return None if text is None else f"getByTestId({text})"
    if name == "locator":
        if len(args) != 1:
            return None  # with options, Playwright's own text can differ
        if isinstance(args[0], Chain):
            inner = canonical(args[0])
            return None if inner is None else f"locator({inner})"
        return f"locator({js_quote(args[0])})" if isinstance(args[0], str) and not is_xpath(args[0]) else None
    if name == "frameLocator":
        ok = len(args) == 1 and isinstance(args[0], str) and not is_xpath(args[0])
        return f"locator({js_quote(args[0])}).contentFrame()" if ok else None
    if name in ("first", "last", "contentFrame"):
        return None if args else f"{name}()"
    if name == "nth":
        return f"nth({args[0]})" if len(args) == 1 and isinstance(args[0], int) and not isinstance(args[0], bool) \
            else None
    if name in ("and", "or"):
        inner = canonical(args[0]) if len(args) == 1 and isinstance(args[0], Chain) else None
        return None if inner is None else f"{name}({inner})"
    if name == "filter":
        options = args[0] if len(args) == 1 else None
        if not isinstance(options, dict) or set(options) - {"hasText", "hasNotText", "has", "hasNot", "visible"}:
            return None
        parts = []
        for key in ("hasText", "hasNotText"):  # the order Playwright builds the selector in
            if key in options:
                text = text_arg(options[key])
                if text is None:
                    return None
                parts.append(f"filter({{ {key}: {text} }})")
        for key in ("has", "hasNot"):
            if key in options:
                inner = canonical(options[key]) if isinstance(options[key], Chain) else None
                if inner is None:
                    return None
                parts.append(f"filter({{ {key}: {inner} }})")
        if "visible" in options:
            if not isinstance(options["visible"], bool):
                return None
            parts.append(f"filter({{ visible: {'true' if options['visible'] else 'false'} }})")
        return ".".join(parts) or None
    return None


def canonical(chain):
    """The chain without its root, as Playwright's locator.toString() prints it; None if it can't be known here."""
    parts = [canonical_step(name, args) for name, args in chain.steps]
    return None if any(part is None for part in parts) else ".".join(parts)


def target(chain):
    """What the chain's element is asked to be: (kind, role, name, exact). name is a str, a Regex, DYNAMIC or None."""
    found = ("unknown", None, None, False)
    for name, args in chain.steps:
        options = args[1] if len(args) > 1 and isinstance(args[1], dict) else {}
        if name == "getByRole":
            role = args[0] if args and isinstance(args[0], str) else DYNAMIC
            value = options.get("name")
            if value is not None and not isinstance(value, (str, Regex)):
                value = DYNAMIC
            found = ("role", role, value, options.get("exact") is True)
        elif name in TEXT_KINDS:
            value = args[0] if args and isinstance(args[0], (str, Regex)) else DYNAMIC
            found = (TEXT_KINDS[name], None, value, options.get("exact") is True)
        elif name == "getByTestId":
            found = ("testid", None, None, False)
        elif name == "locator":
            if args and isinstance(args[0], Chain):
                found = target(args[0])
            else:
                found = ("xpath" if args and isinstance(args[0], str) and is_xpath(args[0]) else "css", None, None, False)
        elif name in ("frameLocator", "contentFrame"):
            found = ("frame", None, None, False)
    return found


# --- page snapshots (Playwright's aria snapshot YAML) -------------------------------------------------------------

NODE = re.compile(r"^(\s*)- (.*)$")
FORM_ROLES = {"textbox", "searchbox", "combobox", "listbox", "checkbox", "radio", "switch", "spinbutton", "slider"}
CONTEXT_LINE = re.compile(r"Error Context: (\S+)")
CONTEXT_PATH = re.compile(r"(?:\.\./)*(test-results/[^/\s]+/error-context\.md)$")
SNAPSHOT = re.compile(r"^# Page snapshot\n\n```yaml\n(.*?)\n```", re.S | re.M)


def yaml_value(value):
    value = value.strip()
    if value.startswith('"'):
        try:
            return json.loads(value)
        except ValueError:
            return value.strip('"')
    if value.startswith("'") and value.endswith("'") and len(value) > 1:
        return value[1:-1].replace("''", "'")
    return value


def split_key(body):
    """An aria snapshot line's key and its inline text (None for a node without text)."""
    if body[:1] == "'":  # a key in single quotes
        j, key = 1, []
        while j < len(body):
            if body[j] == "'" and body[j + 1:j + 2] == "'":
                key.append("'")
                j += 2
            elif body[j] == "'":
                break
            else:
                key.append(body[j])
                j += 1
        rest = body[j + 1:]
        return "".join(key), (yaml_value(rest[1:]) if rest.startswith(":") and rest[1:].strip() else None)
    in_string, j = False, 0
    while j < len(body):
        ch = body[j]
        if in_string:
            if ch == "\\":
                j += 1
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == ":" and (j + 1 == len(body) or body[j + 1] == " "):
            text = body[j + 1:].strip()
            return body[:j], (yaml_value(text) if text else None)
        j += 1
    return body, None


def parse_aria(yaml):
    """The snapshot's nodes, in order: role, name, own text, props (/url, /placeholder), depth, parent, children."""
    nodes, stack = [], []
    for line in yaml.splitlines():
        m = NODE.match(line)
        if not m:
            continue
        depth = len(m.group(1)) // 2
        key, text = split_key(m.group(2))
        while stack and nodes[stack[-1]]["depth"] >= depth:
            stack.pop()
        parent = stack[-1] if stack else None
        if key.startswith("/"):
            if parent is not None:
                nodes[parent]["props"][key[1:]] = "" if text is None else str(text)
            continue
        role, _, rest = key.partition(" ")
        name, rest = None, rest.lstrip()
        if rest.startswith('"'):
            try:
                name, end = json.JSONDecoder().raw_decode(rest)
                rest = rest[end:]
            except ValueError:
                pass
        if role == "text":
            name, text = None, text if text is not None else ""
        nodes.append({"role": role, "name": name, "text": None if text is None else str(text), "props": {},
                      "depth": depth, "parent": parent, "children": 0})
        if parent is not None:
            nodes[parent]["children"] += 1
        stack.append(len(nodes) - 1)
    return nodes


def label(node):
    """What identifies the element: its accessible name, else its own text."""
    return node["name"] if node["name"] else (node["text"] or "")


def name_matches(actual, wanted, exact):
    if isinstance(wanted, Regex):
        return wanted.search(actual or "")
    if exact:
        return norm(actual or "") == norm(wanted)
    return norm(wanted).casefold() in norm(actual or "").casefold()


def candidates(goal, nodes):
    kind, role, wanted, exact = goal
    found = []
    for node in nodes:
        r = node["role"]
        if kind == "role":
            hit = r == role and (wanted is None or name_matches(label(node), wanted, exact))
        elif kind == "label":
            hit = r in FORM_ROLES and name_matches(node["name"], wanted, exact)
        elif kind == "placeholder":
            hit = (name_matches(node["props"].get("placeholder"), wanted, exact) if "placeholder" in node["props"]
                   else r in FORM_ROLES and name_matches(node["name"], wanted, exact))
        elif kind == "alt":
            hit = r == "img" and name_matches(node["name"], wanted, exact)
        elif kind == "title":
            hit = name_matches(node["name"], wanted, exact)
        else:  # text: the element holding it
            hit = ((node["text"] is not None and name_matches(node["text"], wanted, exact)) or
                   (r != "text" and not node["children"] and name_matches(node["name"], wanted, exact)))
        if hit:
            found.append(nodes[node["parent"]] if r == "text" and node["parent"] is not None else node)
    return found


def failing_snapshots(path, failures, before_dir):
    """The page snapshots of the failures the changed file took part in: its own tests, and tests whose stack runs
    through it (a page object)."""
    snapshots = []
    for failure in failures:
        stack = f"{failure.get('stack') or ''}\n{failure.get('message') or ''}"
        if failure.get("file") != path and path not in stack:
            continue
        for printed in dict.fromkeys(CONTEXT_LINE.findall(stack)):
            m = CONTEXT_PATH.search(printed)
            if not m:
                continue
            try:
                text = (before_dir / m.group(1)).read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            found = SNAPSHOT.search(text)
            if found:
                snapshots.append(parse_aria(found.group(1)))
    return snapshots


def element(snapshot):
    """(role, label) of the element an aria snapshot of one locator starts with."""
    top = [node for node in parse_aria(snapshot) if node["depth"] == 0]
    if len(top) == 1 and top[0]["role"] != "text":
        return top[0]["role"], label(top[0])
    texts = [node["text"] for node in top if node["role"] == "text" and node["text"]]
    return "generic", norm(" ".join(texts)) if len(texts) == len(top) else ""  # an element without a role


# --- the check -------------------------------------------------------------------------------------------------

OPAQUE_KINDS = {"testid": "a test ID", "css": "a CSS selector", "xpath": "an XPath", "frame": "a frame",
                "unknown": "not a locator the check can read"}


def before(goal, snapshots):
    """(element or None, reason): what the old locator asked for."""
    kind, role, wanted, exact = goal
    if kind in OPAQUE_KINDS:
        return None, f"The old locator is {OPAQUE_KINDS[kind]}, which a page snapshot can't show."
    if wanted is DYNAMIC or role is DYNAMIC:
        return None, "The old locator is built from variables."
    from_locator = {"role": role, "name": wanted, "from": "locator"} if kind == "role" and wanted is not None else None
    if not snapshots:
        if from_locator:
            return from_locator, None
        what = "accessible name" if kind == "role" else "role"
        return None, f"There is no page snapshot from the failing run, and the old locator names no {what}."
    found = {(node["role"], label(node)) for nodes in snapshots for node in candidates(goal, nodes)}
    if len(found) == 1:
        role_, name_ = found.pop()
        return {"role": role_, "name": name_, "from": "page"}, None
    if from_locator:
        return from_locator, None
    if found:
        listed = ", ".join(describe({"role": r, "name": n}) for r, n in sorted(found))
        return None, f"The old locator matches different elements on the failing page: {listed}."
    what = "accessible name" if kind == "role" else "role"
    return None, f"The failing page has no element the old locator matches, and it names no {what}."


def after(chain, records):
    """(elements or None, reason): what the new locator resolved to in the verification run."""
    tail = canonical(chain)
    if tail is None:
        return None, "The new locator is built from variables or options the check can't follow."
    found, errors = set(), []
    for record in records:
        if record.get("target") != tail:
            continue
        if record.get("snapshot"):
            found.add(element(record["snapshot"]))
        elif record.get("error"):
            errors.append(norm(record["error"]))
    if found:
        return [{"role": role, "name": name} for role, name in sorted(found)], None
    if errors:
        return None, f"The verification run couldn't read its element: {errors[0][:160]}"
    return None, "The verification run didn't act on the new locator."


def describe(side):
    if side is None:
        return "unknown"
    name = side["name"]
    if isinstance(name, Regex):
        return f"{side['role']} {name.source()}"
    return f"{side['role']} {json.dumps(name, ensure_ascii=False)}" if name else f"{side['role']} (no name)"


def renames():
    pairs = {}
    for n, line in enumerate((os.environ.get("LOCATOR_RENAMES") or "").splitlines(), 1):
        if not line.strip() or line.strip().startswith("#"):
            continue
        old, arrow, new = line.replace("→", "->").partition("->")
        old, new = (side.strip().strip("\"'").strip() for side in (old, new))
        if not arrow or not old or not new:
            print(f"::warning title=Locator check::locator_renames line {n} isn't \"old -> new\"; ignored.")
            continue
        pairs[(norm(old).casefold(), norm(new).casefold())] = (old, new)
    return pairs


def compare(old, new, allowed, used, where):
    if old["role"] != new["role"]:
        names_differ = (not isinstance(old["name"], Regex) and
                        norm(old["name"]).casefold() != norm(new["name"]).casefold())
        return "mismatch", "The role and the accessible name differ." if names_differ else "The role differs."
    if isinstance(old["name"], Regex):
        return ("pass", "The name matches the old locator's pattern.") if old["name"].search(new["name"]) \
            else ("mismatch", "The accessible name doesn't match the old locator's pattern.")
    if norm(old["name"]).casefold() == norm(new["name"]).casefold():
        return "pass", "Same role and accessible name."
    rename = allowed.get((norm(old["name"]).casefold(), norm(new["name"]).casefold()))
    if rename:
        used.append({"where": where, "old": rename[0], "new": rename[1]})
        print(f"::notice title=Locator check::{where}: accepted rename \"{rename[0]}\" -> \"{rename[1]}\" from "
              "locator_renames.")
        return "pass", f"Accepted rename from locator_renames: \"{rename[0]}\" → \"{rename[1]}\"."
    return "mismatch", "The accessible name differs."


def code(text):
    text = norm(text)
    text = text if len(text) <= 90 else text[:89] + "…"
    return f"`` {text} ``" if "`" in text else f"`{text}`"


# --- the hunks the healer changed --------------------------------------------------------------------------------

HUNK = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def side(lines):
    """The locator chains in one side of a hunk, with the line each starts on."""
    text = "\n".join(content for _, content in lines)
    starts, offset = [], 0
    for number, content in lines:
        starts.append((offset, number))
        offset += len(content) + 1
    found = []
    for chain in find_chains(text):
        line = next((number for start, number in reversed(starts) if start <= chain.tail_start), 0)
        found.append((chain, norm(text[chain.tail_start:chain.end]), line))
    return found


def changed_locators():
    """Pairs (path, line, old chain or None, old text, new chain, new text) for each locator the diff changed."""
    pairs = []
    paths = git("diff", "--name-only", "--no-renames", BASE, "--", TEST_DIR).splitlines()
    for path in sorted(p for p in paths if p.endswith(SOURCES)):
        hunks, current = [], None
        for line in git("diff", "--no-color", "--no-ext-diff", "--no-renames", "-U3", BASE, "--", path).splitlines():
            m = HUNK.match(line)
            if m:
                current = {"old": [], "new": []}
                hunks.append(current)
                old_no, new_no = int(m.group(1)), int(m.group(2))
                continue
            if current is None:
                continue
            tag, content = line[:1], line[1:].rstrip("\r")
            if tag in (" ", "-"):
                current["old"].append((old_no, content))
                old_no += 1
            if tag in (" ", "+"):
                current["new"].append((new_no, content))
                new_no += 1
        for hunk in hunks:
            old, new = side(hunk["old"]), side(hunk["new"])
            for entry in list(new):  # a locator on both sides didn't change
                same = next((o for o in old if o[1] == entry[1]), None)
                if same is not None:
                    old.remove(same)
                    new.remove(entry)
            for n, (chain, text, line) in enumerate(new):
                previous = old[n] if n < len(old) else (None, "", 0)
                pairs.append((path, line, previous[0], previous[1], chain, text))
    return pairs


# --- modes -------------------------------------------------------------------------------------------------------

ADAPTERS = {"playwright": {"probe": "scripts/locator-probe/playwright.cjs"}}  # Cypress, Selenium: not yet


def run_targets():
    adapter = ADAPTERS.get(FRAMEWORK)
    if adapter is None:
        say(f"not available for {FRAMEWORK} yet; nothing to record.")
        output(supported="false", count=0, probe="")
        return
    WORK.mkdir(parents=True, exist_ok=True)
    pairs = changed_locators()
    listed = [{"file": path, "line": line, "old": old_text or None, "new": new_text, "probe": canonical(new)}
              for path, line, _, old_text, new, new_text in pairs]
    (WORK / "targets.json").write_text(json.dumps({"framework": FRAMEWORK, "base": BASE, "locators": listed},
                                                  indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    probes = sorted({entry["probe"] for entry in listed if entry["probe"]})
    (WORK / "probe-targets.json").write_text(json.dumps(probes, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for entry in listed:
        say(f"{entry['file']}:{entry['line']}: {entry['old'] or '(new)'} -> {entry['new']}")
    probe = PLATFORM / adapter["probe"]
    output(supported="true", count=len(listed), probe=str(probe.resolve()) if probes and probe.is_file() else "")


def run_report():
    if FRAMEWORK not in ADAPTERS:
        say(f"not available for {FRAMEWORK} yet; the pull request is unchanged.")
        output(status="unsupported", draft="false", mismatches=0, unknown=0)
        return
    before_dir = WORK / "before"
    try:
        failures = json.loads((before_dir / "results" / "failures.json").read_text(encoding="utf-8-sig"))
        failures = [f for f in failures if isinstance(f, dict)] if isinstance(failures, list) else []
    except (OSError, ValueError):
        failures = []
    records = []
    try:
        for line in (WORK / "after.jsonl").read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict):
                records.append(record)
    except OSError:
        pass
    allowed, used, rows, entries = renames(), [], [], []
    marks = {"pass": "✅", "mismatch": "❌", "unknown": "❓"}
    for path, line, old, old_text, new, new_text in changed_locators():
        where = f"{path}:{line}"
        old_side, old_reason = (before(target(old), failing_snapshots(path, failures, before_dir)) if old is not None
                                else (None, "The healer added this locator; there is no old one."))
        new_sides, new_reason = after(new, records)
        if old_side and new_sides:
            results = [compare(old_side, side_, allowed, used, where) for side_ in new_sides]
            bad = [reason for result, reason in results if result == "mismatch"]
            result, reason = ("mismatch", bad[0]) if bad else ("pass", results[0][1])
        else:
            result = "unknown"
            reason = " ".join(part for part in (old_reason, new_reason) if part)
        shown = f"{describe(old_side)} → {' / '.join(describe(s) for s in new_sides or [None])}"
        rows.append({"file": path, "line": line, "old": old_text or None, "new": new_text,
                     "before": None if old_side is None else {
                         "role": old_side["role"], "from": old_side["from"],
                         "name": old_side["name"].source() if isinstance(old_side["name"], Regex) else old_side["name"]},
                     "after": new_sides, "result": result, "reason": reason})
        entries.append(f"- {marks[result]} `{where}` {code(old_text) if old_text else '(new)'} → {code(new_text)}: "
                       f"{shown}. {reason}")
        if result == "mismatch":
            print(f"::warning title=Locator check::{where}: {shown.replace('→', '->')}. {reason} The pull request is "
                  "a draft.")
    mismatches = sum(row["result"] == "mismatch" for row in rows)
    unknown = sum(row["result"] == "unknown" for row in rows)
    status = "none" if not rows else "mismatch" if mismatches else "unknown" if unknown else "pass"
    if status == "none":
        summary = "✅ The healer changed no locator."
    elif status == "mismatch":
        summary = (f"❌ {mismatches} of {len(rows)} changed locators point to an element with a different role or "
                   "accessible name, so this pull request is a draft until a reviewer has checked them.")
    elif status == "unknown":
        summary = (f"❓ {unknown} of {len(rows)} changed locators couldn't be compared; each shows the element it "
                   "points to now, for a reviewer to confirm.")
    else:
        summary = "✅ Every changed locator points to an element with the same role and accessible name as before."
    lines = ["## Locator check", "", summary, "", *entries]
    lines += ["", "Before: what the old locator asked for, on the failing run's page snapshot. After: the element the "
              "new locator resolved to in the verification run. A script compares role and accessible name "
              "(`scripts/locator-check.sh`)."]
    section = "\n".join(lines) + "\n"
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "locator-check.json").write_text(json.dumps(
        {"framework": FRAMEWORK, "status": status, "draft": status == "mismatch", "locators": rows,
         "renames_used": used}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (RESULTS / "locator-check.md").write_text(section, encoding="utf-8")
    if PR_BODY.is_file():
        with open(PR_BODY, "a", encoding="utf-8") as fh:
            fh.write("\n" + section)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(section + "\n")
    print(section)
    output(status=status, draft="true" if status == "mismatch" else "false", mismatches=mismatches, unknown=unknown)


run_targets() if MODE == "targets" else run_report()
PY
