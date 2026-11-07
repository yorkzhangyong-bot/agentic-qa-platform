#!/usr/bin/env bash
# fetch-spec.sh — write the feature specification for the planner agent to spec.md.
#
# Inputs (environment variables). The first source that is set wins:
#   SPEC_PATH      path to an existing markdown file in the repository
#   ISSUE_NUMBER   GitHub issue number, read with `gh issue view <n> --json title,body`
#                  (needs GH_TOKEN with issues:read; uses $GITHUB_REPOSITORY when set, else the current repo)
#   JIRA_KEY       Jira issue key (e.g. QA-123), read from $JIRA_BASE_URL/rest/api/3/issue/<key>
#     JIRA_BASE_URL  e.g. https://your-company.atlassian.net (required with JIRA_KEY)
#     JIRA_TOKEN     API token (required with JIRA_KEY)
#     JIRA_EMAIL     Jira Cloud account email; enables basic auth. Leave it empty to send JIRA_TOKEN as a
#                    Bearer token (e.g. a Jira Data Center personal access token).
#
# Output: spec.md in the current directory (override with SPEC_OUT).
# Exits 1 with a clear message if no source is set or fetching fails.
set -euo pipefail

out="${SPEC_OUT:-spec.md}"

log() { printf '[fetch-spec] %s\n' "$*" >&2; }
die() { printf '[fetch-spec] ERROR: %s\n' "$*" >&2; exit 1; }

spec_path="${SPEC_PATH:-}"
issue="${ISSUE_NUMBER:-}"
issue="${issue#\#}"
jira_key="${JIRA_KEY:-}"

if [ -n "$spec_path" ]; then
  [ -f "$spec_path" ] || die "SPEC_PATH '$spec_path' does not exist (relative paths resolve from $(pwd))."
  if [ "$spec_path" -ef "$out" ]; then
    log "SPEC_PATH already is $out"
  else
    cp "$spec_path" "$out"
  fi
  log "wrote $out from file $spec_path"

elif [ -n "$issue" ]; then
  [[ "$issue" =~ ^[0-9]+$ ]] || die "ISSUE_NUMBER must be a number, got '${ISSUE_NUMBER}'."
  command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required to read ISSUE_NUMBER."
  repo_args=()
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    repo_args=(--repo "$GITHUB_REPOSITORY")
  fi
  if ! gh issue view "$issue" ${repo_args[@]+"${repo_args[@]}"} --json title,body \
      --jq '"# " + .title + "\n\n> Source: GitHub issue #'"$issue"'\n\n" + (.body // "")' > "$out"; then
    rm -f "$out"
    die "could not read GitHub issue #$issue. Check that it exists and that GH_TOKEN has issues:read."
  fi
  log "wrote $out from GitHub issue #$issue"

elif [ -n "$jira_key" ]; then
  [[ "$jira_key" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]] || die "JIRA_KEY must look like PROJ-123, got '$jira_key'."
  [ -n "${JIRA_BASE_URL:-}" ] || die "JIRA_BASE_URL is required with JIRA_KEY (e.g. https://your-company.atlassian.net)."
  [ -n "${JIRA_TOKEN:-}" ] || die "JIRA_TOKEN is required with JIRA_KEY."
  command -v python3 >/dev/null 2>&1 || die "python3 is required to convert the Jira description."
  base="${JIRA_BASE_URL%/}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  if [ -n "${JIRA_EMAIL:-}" ]; then
    auth=(--user "${JIRA_EMAIL}:${JIRA_TOKEN}")
  else
    auth=(--header "Authorization: Bearer ${JIRA_TOKEN}")
  fi
  status="$(curl --silent --show-error --location --output "$tmp" --write-out '%{http_code}' \
      "${auth[@]}" --header 'Accept: application/json' \
      "${base}/rest/api/3/issue/${jira_key}?fields=summary,description")" \
    || die "the request to ${base} failed."
  [ "$status" = "200" ] || die "Jira returned HTTP ${status} for ${jira_key}: $(head -c 300 "$tmp")"

  python3 - "$tmp" "$jira_key" "$base" > "$out" <<'PY'
import json
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

path, key, base = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    fields = json.load(fh).get("fields") or {}


def inline(nodes):
    return "".join(render(n) for n in nodes or [])


def render(node):
    """Convert an Atlassian Document Format (ADF) node to markdown."""
    if not isinstance(node, dict):
        return str(node or "")
    kind = node.get("type")
    content = node.get("content") or []
    attrs = node.get("attrs") or {}
    if kind == "text":
        text = node.get("text", "")
        for mark in node.get("marks") or []:
            mtype = mark.get("type")
            if mtype == "code":
                text = f"`{text}`"
            elif mtype == "strong":
                text = f"**{text}**"
            elif mtype == "em":
                text = f"_{text}_"
            elif mtype == "link":
                text = f"[{text}]({(mark.get('attrs') or {}).get('href', '')})"
        return text
    if kind == "hardBreak":
        return "\n"
    if kind == "paragraph":
        return inline(content) + "\n\n"
    if kind == "heading":
        return "#" * int(attrs.get("level", 2)) + " " + inline(content) + "\n\n"
    if kind in ("bulletList", "orderedList"):
        lines = []
        for number, item in enumerate(content, 1):
            marker = f"{number}." if kind == "orderedList" else "-"
            body = [line for line in inline(item.get("content")).strip().split("\n") if line.strip()]
            if body:
                lines.append(f"{marker} {body[0]}")
                lines.extend("   " + line for line in body[1:])
        return "\n".join(lines) + "\n\n"
    if kind == "codeBlock":
        return f"```{attrs.get('language') or ''}\n{inline(content)}\n```\n\n"
    if kind == "blockquote":
        return "\n".join("> " + line for line in inline(content).strip().split("\n")) + "\n\n"
    if kind == "rule":
        return "---\n\n"
    if kind == "table":
        rows = []
        for row in content:
            cells = [inline(cell.get("content")).strip().replace("\n", " ") for cell in row.get("content") or []]
            rows.append("| " + " | ".join(cells) + " |")
            if len(rows) == 1:
                rows.append("|" + "---|" * len(cells))
        return "\n".join(rows) + "\n\n"
    if kind in ("mention", "emoji", "status"):
        return attrs.get("text") or attrs.get("shortName") or ""
    if kind in ("inlineCard", "blockCard", "embedCard"):
        return attrs.get("url", "")
    return inline(content)


description = fields.get("description")
if isinstance(description, dict):
    body = render(description)
elif description:
    body = str(description)
else:
    body = "_No description._"
body = re.sub(r"\n{3,}", "\n\n", body).strip()

print(f"# {fields.get('summary') or key}\n")
print(f"> Source: Jira {key} — {base}/browse/{key}\n")
print(body)
PY
  log "wrote $out from Jira issue $jira_key"

else
  die "no spec source provided. Set SPEC_PATH (markdown file), ISSUE_NUMBER (GitHub issue) or JIRA_KEY (Jira issue)."
fi

[ -s "$out" ] || die "$out is empty."
log "$out: $(wc -c < "$out" | tr -d ' ') bytes, title: $(head -n 1 "$out")"
