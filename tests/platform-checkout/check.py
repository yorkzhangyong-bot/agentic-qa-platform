#!/usr/bin/env python3
"""check.py — the platform checkout in the workflows a consumer calls: sparse, without the answer key, and enough.

The reusable workflows (on: workflow_call) check agentic-qa-platform out into .agentic-qa/ with a sparse checkout.
Each check builds that checkout from the workflow's own sparse-checkout list, with git, the way actions/checkout
does it (sparse-checkout-cone-mode: false), from the platform as it is on disk:

  sparse    every platform checkout has a list and doesn't use cone mode (which adds every top-level file); none
            of evals/, tests/, BACKLOG.md, README.md and .github/ is in it, and every entry names something;
            test-and-heal.yml and generate-tests.yml use one list; and each job that runs an agent runs
            scripts/check-platform-checkout.sh after the checkout and before its first agent.
  covers    every platform path a job reads is in that job's checkout:
              - the paths its steps name (.agentic-qa/..., $PLATFORM_DIR/..., ${{ env.PLATFORM_DIR }}/...);
              - what the platform scripts among them read ($platform/..., platform / "..." in their Python, and
                the platform files they name in quotes), and the scripts those name in turn;
              - in a job that runs agents, the paths AGENT-RULES.md and the agents name (the framework configs)
                and every framework's agents_dir, which stage-agents.sh reads.
            Each path must also be in the platform at all, so a stale or mistyped name fails too.
  eval      the triage eval builds its workspace from the same platform parts (PLATFORM_PARTS in
            evals/triage/run-eval.py), so it sees what a consumer's triage job sees.
  checkout  prints the folder of the checkout the agent jobs get, for the tests in tests/run-tests.sh that run the
            scripts from it.

Usage: python3 tests/platform-checkout/check.py <check> <platform root> <work folder>
The work folder keeps the snapshot and the checkouts between calls. Exit code: 0 if the check passes, 1 if it
doesn't (each problem on its own line), 2 for a usage error. Needs git and PyYAML.
"""
import ast
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("check.py: needs PyYAML (python3 -m pip install pyyaml, or apt install python3-yaml)")

FORBIDDEN = ("evals", "tests", "BACKLOG.md", "README.md", ".github")
SAME_LIST = ("test-and-heal.yml", "generate-tests.yml")
GUARD = "check-platform-checkout.sh"
AGENT = "run-agent.sh"

# A variable part of a path: ${{ … }}, ${VAR}, $VAR, <placeholder> or an f-string field.
VAR = r"(?:\$\{\{[^}]*\}\}|\$\{[A-Za-z_]\w*\}|\$[A-Za-z_]\w*|<[A-Za-z_-]+>|\{[^{}\n]*\})"
PREFIXED = re.compile(r"(?:\.agentic-qa|\$\{\{\s*env\.PLATFORM_DIR\s*\}\}|\$\{?(?:PLATFORM_DIR|platform)\}?)/"
                      rf"((?:[\w.*-]|{VAR}|/)*)")
OPERAND = r"(?:f?\"[^\"\n]*\"|f?'[^'\n]*'|[A-Za-z_][\w.]*(?:\[[^\]\n]*\])*)"
JOIN = re.compile(rf"\b(?:platform|PLATFORM)\b((?:\s+/\s+{OPERAND})+)")
PART = re.compile(r"\s+/\s+(?:(f?)\"([^\"\n]*)\"|(f?)'([^'\n]*)'|[A-Za-z_][\w.]*(?:\[[^\]\n]*\])*)")
QUOTED = re.compile(r"[\"']((?:[\w.-]+/)+[\w.-]+)[\"']")


def git(*args, cwd):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def as_glob(path):
    """A path as a glob relative to the platform root: each variable part becomes *."""
    return re.sub(VAR, "*", path).rstrip("/.,:;")


def usable(ref):
    parts = ref.split("/")
    return bool(ref) and parts[0] not in ("", ".git") and not all(part == "*" for part in parts)


def present(base, ref):
    """The files and folders under base that ref names."""
    if any(char in ref for char in "*?["):
        return sorted(base.glob(ref))
    path = base / ref
    return [path] if path.exists() else []


def refs_in(text, script=False, tracked=frozenset()):
    """The platform paths a text names. In a script, also its Python path joins and the platform files it quotes."""
    found = {as_glob(m.group(1)) for m in PREFIXED.finditer(text)}
    if script:
        for m in JOIN.finditer(text):
            parts = []
            for part in PART.finditer(m.group(1)):
                literal = part.group(2) if part.group(2) is not None else part.group(4)
                fstring = part.group(1) or part.group(3)
                parts.append("*" if literal is None else (as_glob(literal) if fstring else literal))
            found.add("/".join(parts))
        found |= {m.group(1) for m in QUOTED.finditer(text) if m.group(1) in tracked}
    return {ref for ref in found if usable(ref)}


def strings(value):
    """Every string in a parsed YAML value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def platform_checkout(step):
    settings = step.get("with") or {}
    return str(step.get("uses", "")).startswith("actions/checkout@") and (
        settings.get("path") == ".agentic-qa" or "workflow_repository" in str(settings.get("repository", "")))


def sparse_list(step):
    raw = (step.get("with") or {}).get("sparse-checkout")
    lines = (line.strip() for line in raw.splitlines()) if isinstance(raw, str) else ()
    return [line for line in lines if line and not line.startswith("#")]


def cone_mode(step):
    value = (step.get("with") or {}).get("sparse-checkout-cone-mode", True)
    return not (value is False or str(value).strip().lower() == "false")


def runs(step, name):
    return name in str(step.get("run", ""))


def jobs(root):
    """(workflow, job id, job) for each job with steps in the workflows a consumer calls (on: workflow_call)."""
    for path in sorted((root / ".github" / "workflows").glob("*.yml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        triggers = data.get("on", data.get(True))  # YAML 1.1 reads a bare `on` as true
        if not isinstance(triggers, dict) or "workflow_call" not in triggers:
            continue
        for job_id, job in (data.get("jobs") or {}).items():
            if isinstance(job, dict) and job.get("steps"):
                yield path.name, job_id, job


def add(named, refs, origin):
    for ref in refs:
        named.setdefault(ref, set()).add(origin)


class Platform:
    def __init__(self, root, work):
        self.root = root
        self.work = work
        self.source = self.snapshot()
        self.tracked = frozenset(git("ls-files", cwd=self.source).splitlines())

    def snapshot(self):
        """A git repository with the platform's files as they are on disk (tracked and new ones), committed."""
        source = self.work / "source"
        if (source / ".git").is_dir():
            return source
        tmp = pathlib.Path(tempfile.mkdtemp(dir=self.work, prefix="source-"))
        for name in git("ls-files", "-z", "--cached", "--others", "--exclude-standard", cwd=self.root).split("\0"):
            if name and (self.root / name).is_file():
                (tmp / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(self.root / name, tmp / name)
        git("init", "-q", cwd=tmp)
        git("config", "core.autocrlf", "false", cwd=tmp)
        git("add", "-A", cwd=tmp)
        git("-c", "user.name=check", "-c", "user.email=check@example.com", "-c", "commit.gpgsign=false",
            "commit", "-q", "-m", "platform", cwd=tmp)
        os.replace(tmp, source)
        return source

    def checkout(self, patterns):
        """The checkout actions/checkout makes with these patterns and sparse-checkout-cone-mode: false: it sets
        core.sparseCheckout, appends the patterns to info/sparse-checkout and checks out (sparseCheckoutNonConeMode
        in its src/git-command-manager.ts). An empty list is a full checkout."""
        if not patterns:
            return self.source
        dest = self.work / ("checkout-" + hashlib.sha1("\n".join(patterns).encode()).hexdigest()[:10])
        if (dest / ".git").is_dir():
            return dest
        tmp = pathlib.Path(tempfile.mkdtemp(dir=self.work, prefix="checkout-"))
        git("init", "-q", cwd=tmp)
        git("config", "core.autocrlf", "false", cwd=tmp)
        git("fetch", "-q", "--depth=1", self.source.as_uri(), "HEAD", cwd=tmp)
        git("config", "core.sparseCheckout", "true", cwd=tmp)
        info = tmp / git("rev-parse", "--git-path", "info/sparse-checkout", cwd=tmp).strip()
        info.parent.mkdir(parents=True, exist_ok=True)
        with open(info, "a", encoding="utf-8", newline="\n") as fh:
            fh.write("\n" + "\n".join(patterns) + "\n")
        git("checkout", "-q", "--force", "FETCH_HEAD", cwd=tmp)
        os.replace(tmp, dest)
        return dest

    def with_scripts(self, named):
        """named, plus what the platform scripts among them read, and the scripts those name, and so on."""
        named = {ref: set(origins) for ref, origins in named.items()}
        queue = [ref for ref in named if ref.startswith("scripts/")]
        done = set()
        while queue:
            for path in present(self.source, queue.pop()):
                if not path.is_file() or path in done:
                    continue
                done.add(path)
                origin = path.relative_to(self.source).as_posix()
                for ref in refs_in(path.read_text(encoding="utf-8", errors="replace"), True, self.tracked):
                    if ref.startswith("scripts/") and ref not in named:
                        queue.append(ref)
                    named.setdefault(ref, set()).add(origin)
        return named

    def agent_refs(self):
        """What the agents read from .agentic-qa/ (AGENT-RULES.md and the agents), and each agents_dir."""
        named = {}
        for path in [self.source / "AGENT-RULES.md", *sorted((self.source / "agents").rglob("*.md"))]:
            add(named, refs_in(path.read_text(encoding="utf-8")), path.relative_to(self.source).as_posix())
        for config in sorted((self.source / "frameworks").glob("*.json")):
            agents_dir = str(json.loads(config.read_text(encoding="utf-8")).get("agents_dir") or "").strip("/")
            if agents_dir:
                add(named, {agents_dir}, f"{config.relative_to(self.source).as_posix()} (agents_dir)")
        return named

    def agent_lists(self):
        return [sparse_list(step) for _, _, job in jobs(self.root) if any(runs(s, AGENT) for s in job["steps"])
                for step in job["steps"] if platform_checkout(step)]


def check_sparse(platform):
    problems = []
    found = 0
    lists = {}
    for workflow, job_id, job in jobs(platform.root):
        steps = job["steps"]
        where = f"{workflow} job {job_id}"
        checkouts = [n for n, step in enumerate(steps) if platform_checkout(step)]
        if not checkouts:
            continue
        found += len(checkouts)
        if len(checkouts) > 1:
            problems.append(f"{where}: {len(checkouts)} platform checkouts, expected one")
        step = steps[checkouts[0]]
        patterns = sparse_list(step)
        if not patterns:
            problems.append(f"{where}: the platform checkout has no sparse-checkout list, so it checks out everything")
            continue
        if cone_mode(step):
            problems.append(f"{where}: sparse-checkout-cone-mode must be false; cone mode adds every top-level file")
        dest = platform.checkout(patterns)
        problems += [f"{where}: {path} is in the checkout" for path in FORBIDDEN if (dest / path).exists()]
        problems += [f"{where}: the entry {pattern} names nothing in the platform"
                     for pattern in patterns if not present(dest, pattern.strip("/"))]
        if workflow in SAME_LIST:
            lists.setdefault(tuple(patterns), []).append(where)
        if any(runs(s, AGENT) for s in steps):
            guard = next((n for n, s in enumerate(steps) if runs(s, GUARD)), None)
            first = next(n for n, s in enumerate(steps) if runs(s, AGENT))
            if guard is None or not checkouts[0] < guard < first:
                problems.append(f"{where}: must run scripts/{GUARD} after the platform checkout and before its "
                                f"first agent")
    if not found:
        problems.append("no platform checkout in the workflows a consumer calls")
    if len(lists) > 1:
        problems.append(f"{' and '.join(SAME_LIST)} must use one sparse-checkout list; found "
                        + "; ".join(f"{list(patterns)} in {', '.join(where)}" for patterns, where in lists.items()))
    return problems


def check_covers(platform):
    problems = []
    agents = platform.agent_refs()
    for workflow, job_id, job in jobs(platform.root):
        steps = job["steps"]
        where = f"{workflow} job {job_id}"
        named = {}
        add(named, refs_in("\n".join(strings(job.get("env")))), f"{workflow} job {job_id} env")
        for step in steps:
            if not platform_checkout(step):
                add(named, refs_in("\n".join(strings(step))), f"{workflow} step {step.get('name', '?')!r}")
        if any(runs(s, AGENT) for s in steps):
            for ref, origins in agents.items():
                named.setdefault(ref, set()).update(origins)
        named = platform.with_scripts(named)
        if not named:
            continue
        checkouts = [step for step in steps if platform_checkout(step)]
        if not checkouts:
            problems.append(f"{where}: reads {', '.join(sorted(named))} from .agentic-qa/ but has no platform checkout")
            continue
        dest = platform.checkout(sparse_list(checkouts[0]))
        before = len(problems)
        for ref, origins in sorted(named.items()):
            source = ", ".join(sorted(origins))
            if not present(platform.source, ref):
                problems.append(f"{where}: {ref} (named in {source}) is not in the platform at all")
            elif not present(dest, ref):
                problems.append(f"{where}: {ref} (named in {source}) is not in the job's checkout")
        if len(problems) == before:
            print(f"{where}: all {len(named)} platform paths it reads are in its checkout: {', '.join(sorted(named))}")
    return problems


def check_eval(platform):
    text = (platform.source / "evals" / "triage" / "run-eval.py").read_text(encoding="utf-8")
    m = re.search(r"^PLATFORM_PARTS\s*=\s*(\([^)]*\))", text, re.M)
    if not m:
        return ["evals/triage/run-eval.py has no PLATFORM_PARTS"]
    parts = set(ast.literal_eval(m.group(1)))
    lists = {tuple(patterns) for patterns in platform.agent_lists()}
    if not lists:
        return ["no job that runs an agent has a platform checkout"]
    return [f"the triage eval's workspace gets {sorted(parts)} (PLATFORM_PARTS in evals/triage/run-eval.py), but the "
            f"agent jobs check out {list(patterns)}; keep them the same, so the eval sees what triage sees in CI"
            for patterns in lists if {p.strip("/") for p in patterns} != parts]


def main(argv):
    checks = {"sparse": check_sparse, "covers": check_covers, "eval": check_eval}
    if len(argv) != 4 or argv[1] not in (*checks, "checkout"):
        print(__doc__.split("\n\n")[0], f"\nUsage: {argv[0]} sparse|covers|eval|checkout <root> <work>", file=sys.stderr)
        return 2
    root = pathlib.Path(argv[2]).resolve()
    work = pathlib.Path(argv[3]).resolve()
    work.mkdir(parents=True, exist_ok=True)
    platform = Platform(root, work)
    if argv[1] == "checkout":
        lists = platform.agent_lists()
        if not lists:
            print("no job that runs an agent has a platform checkout", file=sys.stderr)
            return 1
        print(platform.checkout(lists[0]).as_posix())
        return 0
    problems = checks[argv[1]](platform)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
