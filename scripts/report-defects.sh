#!/usr/bin/env bash
# report-defects.sh — turn REAL_BUG failures into GitHub issues. There is no AI in this script: the defect-reporter
# agent writes the reports between the two modes.
#
# Usage:  report-defects.sh prepare   results/triage.json + results/failures.json -> results/defect-candidates.json
#         report-defects.sh publish   results/defects/<slug>.md -> GitHub issues, results/defects-report.json and a
#                                     "Defects reported" section in the job summary
#
# prepare: one candidate per REAL_BUG item of triage.json, matched to its failures.json entry by name + classname. Each
#   candidate has a slug, its report path (results/defects/<slug>.md), its fingerprint and the marker
#   <!-- agentic-qa-defect: <fingerprint> -->, the failing step (file:line), the error and the triage reason. A
#   context block adds the commit, app URL, framework, engine, model, run URL and artifact names.
#   Fingerprint: sha1 of "<test file>\n<test name>\n<first error line>", where UUIDs, 0x… values, hex ids (7+ hex
#   characters with a digit and a letter) and numbers are removed from the error line and whitespace is collapsed.
#   The test file is the classname when the file is unknown. Changing this changes every fingerprint, and the open
#   issues no longer match.
# publish: for the report of each candidate (other files in results/defects/ are ignored):
#   - the candidate's marker becomes the first line, and the report's "# " heading becomes the issue title;
#   - the open agentic-qa issue with the fingerprint is looked up with gh issue list --search "<fingerprint> in:body",
#     then in the bodies of the 200 newest open agentic-qa issues, because search lags behind new issues;
#   - found: it gets the comment "Still failing on <sha> — <run url>". Not found: gh issue create, with DEFECT_LABELS
#     (missing labels are created; agentic-qa is always added) and DEFECT_ASSIGNEES (dropped if GitHub rejects them).
#   A failed gh call is reported in the summary and in results/defects-report.json; it never fails the job.
#
# Environment:
#   TRIAGE_JSON, FAILURES_JSON  prepare inputs (default results/triage.json, results/failures.json)
#   DEFECT_CANDIDATES           candidates file (default results/defect-candidates.json)
#   DEFECTS_DIR                 report directory (default results/defects)
#   DEFECTS_REPORT              publish result file (default results/defects-report.json)
#   COMMIT_SHA                  tested commit (default $GITHUB_SHA)
#   RUN_URL                     workflow run URL (default built from GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID)
#   APP_URL, FRAMEWORK, ENGINE, OPENCODE_MODEL  run details for the reports' Environment section (prepare)
#   DEFECT_LABELS               comma-separated labels for new issues (default bug,agentic-qa)
#   DEFECT_ASSIGNEES            comma-separated assignees for new issues (default none)
#   GH_TOKEN, GH_REPO           used by gh (publish)
#   GITHUB_STEP_SUMMARY         the summary section is appended here; printed if unset
# Exit code: 0, also when issues could not be opened; 1 if the input files can't be read; 2 for a usage error.
set -euo pipefail

mode="${1:-}"
candidates="${DEFECT_CANDIDATES:-results/defect-candidates.json}"
reports_dir="${DEFECTS_DIR:-results/defects}"
sha="${COMMIT_SHA:-${GITHUB_SHA:-}}"
run_url="${RUN_URL:-}"
if [ -z "$run_url" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
fi
command -v python3 > /dev/null 2>&1 || { echo "report-defects: python3 is required" >&2; exit 1; }

case "$mode" in
  prepare)
    mkdir -p "$(dirname "$candidates")" "$reports_dir"
    python3 - "${TRIAGE_JSON:-results/triage.json}" "${FAILURES_JSON:-results/failures.json}" "$candidates" \
      "$reports_dir" "$sha" "$run_url" <<'PY'
import hashlib
import json
import os
import re
import sys

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

triage_path, failures_path, out_path, reports_dir, sha, run_url = sys.argv[1:7]

# The fingerprint identifies a failure across runs (see the header). Changing it orphans the open issues.
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
HEX_LITERAL = re.compile(r"\b0x[0-9a-f]+\b", re.I)
HEX_ID = re.compile(r"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,}\b", re.I)
NUMBER = re.compile(r"\d+")


def first_line(text):
    return next((line.strip() for line in str(text or "").splitlines() if line.strip()), "")


def normalise(error_line):
    for pattern in (UUID, HEX_LITERAL, HEX_ID, NUMBER):
        error_line = pattern.sub("", error_line)
    return " ".join(error_line.split())


def fingerprint(test_file, test_name, error_line):
    return hashlib.sha1("\n".join([test_file, test_name, normalise(error_line)]).encode("utf-8")).hexdigest()


def loose(name):
    return re.sub(r"\W+", "", str(name).casefold())


def slug(name, fp):
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:50].strip("-")
    return f"{base or 'defect'}-{fp[:8]}"


def location(test_file, stack):
    """file:line of the failing step: the first stack frame in the test file."""
    if not test_file:
        return ""
    base = re.escape(os.path.basename(test_file))
    m = re.search(rf"\bat\b[^\n]*?{base}:(\d+)", stack) or re.search(rf"{base}:(\d+)", stack)
    return f"{test_file}:{m.group(1)}" if m else test_file


def load(path):
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


try:
    triage = load(triage_path)
except (OSError, ValueError) as exc:
    sys.exit(f"report-defects: cannot read {triage_path}: {exc}")
items = triage.get("items") if isinstance(triage, dict) else triage
if not isinstance(items, list):
    sys.exit(f'report-defects: {triage_path} has no "items" array')
try:
    failures = load(failures_path)
except (OSError, ValueError) as exc:
    print(f"report-defects: cannot read {failures_path} ({exc}); using the triage items alone", file=sys.stderr)
    failures = []
failures = [f for f in failures if isinstance(f, dict)] if isinstance(failures, list) else []


def failure_for(item):
    """The failures.json entry of a triage item: the same name + classname, else the only entry with the same name,
    else the only one whose name matches when case and punctuation are ignored."""
    name, classname = str(item.get("name") or ""), str(item.get("classname") or "")
    exact = [f for f in failures if f.get("name") == name and (f.get("classname") or "") == classname]
    if exact:
        return exact[0]
    for same in (lambda f: f.get("name") == name, lambda f: loose(f.get("name") or "") == loose(name)):
        hits = [f for f in failures if same(f)]
        if len(hits) == 1:
            return hits[0]
    return {}


engine = os.environ.get("ENGINE") or "claude"
context = {
    "commit": sha,
    "app_url": os.environ.get("APP_URL", ""),
    "framework": os.environ.get("FRAMEWORK", ""),
    "engine": engine,
    "model": (os.environ.get("OPENCODE_MODEL") or "deepseek/deepseek-flash") if engine == "opencode"
             else "Claude Code's default model",
    "run_url": run_url,
    "artifacts": {
        "test-results": "the JUnit reports",
        "triage": "results/failures.json and results/triage.json",
        "defects": "results/defect-candidates.json, the defect reports and results/defects-report.json",
    },
}
candidates, seen = [], set()
for item in items:
    if not isinstance(item, dict) or item.get("classification") != "REAL_BUG":
        continue
    failure = failure_for(item)  # the script's own data wins over what the agent copied into triage.json
    name = str(failure.get("name") or item.get("name") or "")
    classname = str(failure.get("classname") or item.get("classname") or "")
    test_file = str(failure.get("file") or item.get("file") or classname)
    error = first_line(failure.get("message"))
    fp = fingerprint(test_file, name, error)
    if fp in seen:
        continue
    seen.add(fp)
    report_slug = slug(name, fp)
    candidates.append({
        "slug": report_slug,
        "report": f"{reports_dir.rstrip('/')}/{report_slug}.md",
        "fingerprint": fp,
        "marker": f"<!-- agentic-qa-defect: {fp} -->",
        "test": name,
        "classname": classname,
        "file": test_file,
        "location": location(test_file, str(failure.get("stack") or "")),
        "error": error,
        "message": str(failure.get("message") or ""),
        "reason": str(item.get("reason") or ""),
        "page_url": str(item.get("page_url") or ""),
    })

with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump({"context": context, "candidates": candidates}, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(f"report-defects: {len(candidates)} REAL_BUG failure(s) to report -> {out_path}")
for c in candidates:
    print(f"  - {c['test']} [{c['location'] or '?'}] fingerprint {c['fingerprint'][:12]}")
PY
    exit 0
    ;;
  publish) ;;
  *)
    echo "usage: report-defects.sh prepare|publish" >&2
    exit 2
    ;;
esac

report="${DEFECTS_REPORT:-results/defects-report.json}"
summary="${GITHUB_STEP_SUMMARY:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Plan: for every candidate, "<n> ok|missing <fingerprint>" in plan.tsv, plus <n>.title and <n>.body for the issue.
python3 - "$candidates" "$reports_dir" "$tmp" <<'PY'
import json
import os
import pathlib
import re
import sys

candidates_path, reports_dir, tmp = sys.argv[1:4]
FINGERPRINT = re.compile(r"[0-9a-f]{40}")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]*")
MARKER = re.compile(r"\s*<!--\s*agentic-qa-defect:.*?-->\s*")
MENTION = re.compile(r"(?<![\w`/])@(?=[A-Za-z0-9])")
MAX_TITLE, MAX_BODY = 250, 60000


def write(name, text):
    with open(os.path.join(tmp, name), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def quiet_mentions(markdown):
    """Put a zero-width space after "@" outside code, so that "@name" in a report can't notify anyone."""
    parts = re.split(r"(^```.*?^```[^\n]*$)", markdown, flags=re.M | re.S)
    for i in range(0, len(parts), 2):  # even items lie outside fenced code blocks
        spans = re.split(r"(`+[^`\n]*`+)", parts[i])
        spans[::2] = [MENTION.sub("@\N{ZERO WIDTH SPACE}", span) for span in spans[::2]]
        parts[i] = "".join(spans)
    return "".join(parts)


try:
    with open(candidates_path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    sys.exit(f"report-defects: cannot read {candidates_path}: {exc}")
candidates = data.get("candidates") if isinstance(data, dict) else None
if not isinstance(candidates, list):
    sys.exit(f'report-defects: {candidates_path} has no "candidates" array')

reports = pathlib.Path(reports_dir)
expected, plan = set(), []
for n, candidate in enumerate(candidates):
    fingerprint, slug = str(candidate.get("fingerprint", "")), str(candidate.get("slug", ""))
    if not FINGERPRINT.fullmatch(fingerprint) or not SLUG.fullmatch(slug):
        sys.exit(f"report-defects: candidate {n + 1} in {candidates_path} has no valid fingerprint and slug")
    path = reports / f"{slug}.md"
    expected.add(path.name)
    if not path.is_file():
        plan.append(f"{n}\tmissing\t{fingerprint}")
        continue
    # The candidate's marker replaces whatever marker the agent wrote: the script owns the fingerprint.
    lines = [line for line in path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").split("\n")
             if not MARKER.fullmatch(line)]
    heading = next((i for i, line in enumerate(lines) if line.startswith("# ")), None)
    title = " ".join(lines.pop(heading)[2:].split()) if heading is not None else ""
    if not title:
        title = f"Failure classified as REAL_BUG ({candidate.get('test') or slug})"
    if not title.startswith("[Agentic QA]"):
        title = f"[Agentic QA] {title}"
    body = f"<!-- agentic-qa-defect: {fingerprint} -->\n" + quiet_mentions("\n".join(lines).strip()) + "\n"
    if len(body) > MAX_BODY:
        body = body[:MAX_BODY] + "\n\n_(Report truncated.)_\n"
    write(f"{n}.title", title[:MAX_TITLE])
    write(f"{n}.body", body)
    plan.append(f"{n}\tok\t{fingerprint}")

write("plan.tsv", "".join(line + "\n" for line in plan))
ignored = sorted(p.name for p in reports.glob("*.md") if p.name not in expected) if reports.is_dir() else []
write("ignored.txt", "".join(name + "\n" for name in ignored))
PY

normalise_list() {  # normalise_list "a, b,,c" prints "a,b,c": items trimmed, empty ones dropped
  local item items=() out=()
  IFS=, read -r -a items <<< "$1"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ -n "$item" ]; then out+=("$item"); fi
  done
  local IFS=,
  printf '%s' "${out[*]}"
}

error_text() {  # error_text <file>: a gh error message on one line, at most 300 characters
  tr '\r\n\t' '   ' < "$1" | cut -c1-300
}

warn() {  # warn <message>: an annotation in the log and a warning in the summary
  echo "::warning::report-defects: $1"
  printf '%s\n' "$1" >> "$tmp/warnings.txt"
}

record() {  # record <n> created|commented|failed|missing [number] [url] [detail]: the outcome for candidate <n>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$tmp/results.tsv"
  if [ -n "${5:-}" ]; then printf '%s\n' "$5" > "$tmp/$1.detail"; fi
  if [ "$2" = failed ] || [ "$2" = missing ]; then
    echo "::warning::report-defects: defect $(( $1 + 1 )): ${5:-the defect-reporter wrote no report}"
  fi
}

ensure_labels() {  # create the labels the repository doesn't have yet, once per run
  [ "$labels_ready" = 0 ] || return 0
  labels_ready=1
  local existing label wanted=()
  if ! existing="$(gh label list --limit 1000 --json name --jq '.[].name' 2> "$tmp/err" < /dev/null)"; then
    warn "could not list the repository's labels, so missing ones were not created: $(error_text "$tmp/err")"
    return 0
  fi
  IFS=, read -r -a wanted <<< "$labels"
  for label in "${wanted[@]}"; do
    grep -qixF -- "$label" <<< "$existing" && continue
    gh label create "$label" --description "Used by agentic-qa-platform defect reports" > /dev/null 2> "$tmp/err" < /dev/null \
      || warn "could not create the label '$label': $(error_text "$tmp/err")"
  done
}

find_issue() {  # find_issue <fingerprint>: prints "<number> <url>" of the open issue that carries it, or nothing
  local found
  found="$(gh issue list --state open --label agentic-qa --search "$1 in:body" --json number,url \
    --jq '.[0] | select(. != null) | "\(.number) \(.url)"' 2> "$tmp/err" < /dev/null)" || return 1
  if [ -z "$found" ]; then  # search can lag behind an issue opened minutes ago: check the newest bodies too
    found="$(gh issue list --state open --label agentic-qa --limit 200 --json number,url,body \
      --jq 'map(select((.body // "") | contains("agentic-qa-defect: '"$1"'"))) | .[0] | select(. != null) | "\(.number) \(.url)"' \
      2> "$tmp/err" < /dev/null)" || return 1
  fi
  printf '%s' "$found"
}

create_issue() {  # create_issue <n>: open the issue and print its URL; if GitHub rejects the assignees, retry without
  local title args=()
  title="$(cat "$tmp/$1.title")"
  args=(issue create --title "$title" --body-file "$tmp/$1.body" --label "$labels")
  if [ -n "$assignees" ]; then
    gh "${args[@]}" --assignee "$assignees" 2> "$tmp/err" < /dev/null && return 0
    printf 'not assigned: %s\n' "$(error_text "$tmp/err")" > "$tmp/$1.detail"
  fi
  gh "${args[@]}" 2> "$tmp/err" < /dev/null
}

labels="$(normalise_list "${DEFECT_LABELS-bug,agentic-qa}")"
case ",${labels,,}," in
  *,agentic-qa,*) ;;
  *) labels="${labels:+$labels,}agentic-qa" ;;  # open issues are found again by this label
esac
assignees="$(normalise_list "${DEFECT_ASSIGNEES:-}")"
labels_ready=0
: > "$tmp/results.tsv"
: > "$tmp/warnings.txt"

while IFS=$'\t' read -r n status fingerprint <&3; do
  if [ "$status" = missing ]; then
    record "$n" missing
    continue
  fi
  if ! found="$(find_issue "$fingerprint")"; then
    record "$n" failed "" "" "could not look for an open issue, so none was opened: $(error_text "$tmp/err")"
    continue
  fi
  if [ -n "$found" ]; then
    read -r number url <<< "$found"
    if gh issue comment "$number" --body "Still failing on ${sha:-an unknown commit} — ${run_url:-(no workflow run URL)}" \
        > /dev/null 2> "$tmp/err" < /dev/null; then
      record "$n" commented "$number" "$url"
    else
      record "$n" failed "$number" "$url" "could not comment on #$number: $(error_text "$tmp/err")"
    fi
    continue
  fi
  ensure_labels
  if url="$(create_issue "$n")"; then
    url="$(printf '%s\n' "$url" | tail -n 1)"
    number="${url##*/}"
    [[ "$number" =~ ^[0-9]+$ ]] || number=""
    record "$n" created "$number" "$url"
  else
    record "$n" failed "" "" "could not open the issue: $(error_text "$tmp/err")"
  fi
done 3< "$tmp/plan.tsv"

# results/defects-report.json and the "Defects reported" summary section.
if ! python3 - "$candidates" "$tmp" "$report" "$summary" <<'PY'
import json
import os
import re
import sys

for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

candidates_path, tmp, report_path, summary_path = sys.argv[1:5]
MARKDOWN = re.compile(r"([\\`*_\[\]<>|~&$])")  # escaped in table cells, as in write-summary.sh
NONE = "\N{EM DASH}"


def one_line(text):
    return " ".join(str(text).split())


def md(text):
    return MARKDOWN.sub(r"\\\1", one_line(text))


def code(text):
    return "`" + one_line(text).replace("`", "'") + "`"


def read(name):
    path = os.path.join(tmp, name)
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().strip()


with open(candidates_path, encoding="utf-8") as fh:
    candidates = json.load(fh)["candidates"]
result = {"created": [], "updated": [], "failed": [], "missing": [], "ignored": [], "warnings": []}
rows = []
for line in read("results.tsv").splitlines():
    n, action, number, url = (line.split("\t") + [""] * 4)[:4]
    candidate = candidates[int(n)]
    entry = {"test": candidate.get("test", ""), "file": candidate.get("file", ""),
             "fingerprint": candidate.get("fingerprint", "")}
    issue = {"number": int(number), "url": url} if number.isdigit() else {}
    detail = read(f"{n}.detail")
    if action == "created":
        result["created"].append({**entry, **issue, "title": read(f"{n}.title"), **({"note": detail} if detail else {})})
        outcome = "opened" + (f" ({md(detail)})" if detail else "")
    elif action == "commented":
        result["updated"].append({**entry, **issue, "title": read(f"{n}.title")})
        outcome = "still failing: commented"
    elif action == "missing":
        result["missing"].append({**entry, "report": candidate.get("report", "")})
        outcome = f"**no report**: the defect-reporter didn't write {code(candidate.get('report', ''))}"
    else:
        result["failed"].append({**entry, **issue, "error": detail})
        outcome = f"**failed**: {md(detail)}"
    link = f"[#{issue['number']}]({issue['url']})" if issue else NONE
    rows.append(f"| {md(entry['test']) or NONE} | {outcome} | {link} |")
result["ignored"] = read("ignored.txt").splitlines()
result["warnings"] = read("warnings.txt").splitlines()

with open(report_path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(result, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

lines = ["## Defects reported", ""]
if rows:
    lines += ["| Test | Result | Issue |", "| --- | --- | --- |", *rows]
else:
    lines.append("No REAL_BUG failures to report.")
for warning in result["warnings"]:
    lines += ["", f"> **Warning:** {md(warning)}"]
if result["ignored"]:
    lines += ["", "Ignored, because no REAL_BUG failure matches them: "
              + ", ".join(code(name) for name in result["ignored"]) + "."]
text = "\n".join(lines) + "\n\n"
if summary_path:
    with open(summary_path, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
else:
    sys.stdout.write(text)
print(f"report-defects: {len(result['created'])} opened, {len(result['updated'])} commented, "
      f"{len(result['failed'])} failed, {len(result['missing'])} without a report -> {report_path}", file=sys.stderr)
PY
then
  echo "::warning::report-defects: could not write $report or the job summary section."
fi
exit 0
