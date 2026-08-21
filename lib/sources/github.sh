# Source: GitHub issues and pull requests.
#
# Fetches the issues of one repository, and ships a stage-4 summariser that
# pulls each item's discussion. The badge tells an issue from a pull request, so
# `--badge issue` sweeps only issues and `--badge pr` only pull requests.

# shellcheck shell=bash
# The HERDR_INGEST_* variables this file sets (the source id/prefix/sort/badge
# order here, and HERDR_INGEST_OPT_SHIFT below) are the adapter's published
# interface: the engine reads them after it sources this file, so shellcheck
# cannot see the use from here. This directive precedes the first command, so
# it applies file-wide.
# shellcheck disable=SC2034
HERDR_INGEST_SOURCE_ID="github"
HERDR_INGEST_SOURCE_PREFIX="gh"
HERDR_INGEST_SOURCE_SORT="updated"
HERDR_INGEST_SOURCE_BADGE_ORDER='["pr","issue"]'

GITHUB_OPT_REPO="${HERDR_INGEST_GITHUB_REPO:-${GITHUB_REPO:-}}"
GITHUB_OPT_API="${HERDR_INGEST_GITHUB_API_BASE:-${GITHUB_API_BASE:-https://api.github.com}}"
GITHUB_OPT_STATE="${HERDR_INGEST_GITHUB_STATE:-open}"
GITHUB_OPT_LABELS="${HERDR_INGEST_GITHUB_LABELS:-}"
GITHUB_OPT_ASSIGNEE="${HERDR_INGEST_GITHUB_ASSIGNEE:-}"
GITHUB_OPT_FETCH_LIMIT="${HERDR_INGEST_GITHUB_FETCH_LIMIT:-100}"
GITHUB_OPT_COMMENTS="${HERDR_INGEST_GITHUB_COMMENTS:-6}"
GITHUB_OPT_TOKEN=""

ingest_source_describe() {
  printf 'id\tgithub\n'
  printf 'name\tGitHub\n'
  printf 'summary\tissues and pull requests of one repository\n'
  printf 'needs\tcurl jq\n'
}

ingest_source_usage() {
  cat <<EOF
github source flags:
  --repo OWNER/NAME    repository to fetch (required for a live fetch)
  --api-base URL       GitHub API host (default: $GITHUB_OPT_API)
  --gh-state STATE     open, closed or all (default: $GITHUB_OPT_STATE)
  --gh-labels CSV      server-side label filter
  --gh-assignee LOGIN  server-side assignee filter, or \`none\`
  --fetch-limit N      items to fetch, at most 100 per page (default: $GITHUB_OPT_FETCH_LIMIT)
  --comments N         comments the stage-4 summariser renders (default: $GITHUB_OPT_COMMENTS)

github environment:
  GITHUB_TOKEN         token for the API; GH_TOKEN is checked next, then \`gh auth token\`
  GITHUB_REPO          default for --repo
  GITHUB_API_BASE      default for --api-base
  HERDR_INGEST_GITHUB_*  every flag above, upper-cased, e.g.
                       HERDR_INGEST_GITHUB_STATE; set them in a profile

The badge is \`pr\` for a pull request and \`issue\` for an issue, so --badge issue
sweeps only issues. Stage 4 defaults to this source's own summariser, which
fetches the discussion; --no-summarise skips the extra request.
EOF
}

ingest_source_option() {
  case "$1" in
    --repo) GITHUB_OPT_REPO="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --api-base) GITHUB_OPT_API="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --gh-state)
      case "${2:-}" in
        open | closed | all) GITHUB_OPT_STATE="$2" ;;
        *) printf 'invalid value for --gh-state: %s (expected open, closed or all)\n' "${2:-}" >&2; return 1 ;;
      esac
      HERDR_INGEST_OPT_SHIFT=2 ;;
    --gh-labels) GITHUB_OPT_LABELS="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --gh-assignee) GITHUB_OPT_ASSIGNEE="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --fetch-limit)
      herdr_ingest_positive_int --fetch-limit "${2:-}" || return 1
      if [ "$2" -gt 100 ]; then
        printf 'invalid value for --fetch-limit: %s (one GitHub page holds at most 100)\n' "$2" >&2
        return 1
      fi
      GITHUB_OPT_FETCH_LIMIT="$2"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --comments)
      herdr_ingest_positive_int --comments "${2:-}" || return 1
      GITHUB_OPT_COMMENTS="$2"; HERDR_INGEST_OPT_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

ingest_source_check() {
  command -v curl >/dev/null || { echo "curl not found" >&2; return 1; }
  GITHUB_OPT_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$GITHUB_OPT_TOKEN" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_OPT_TOKEN="$(gh auth token 2>/dev/null || printf '')"
  fi
  if [ -z "$GITHUB_OPT_TOKEN" ]; then
    cat >&2 <<'EOF'
no GitHub token found. Either

  export GITHUB_TOKEN=<token>

or authenticate the gh CLI with `gh auth login`. To run without any token, pass
--items-json FILE with a GitHub issues payload.
EOF
    return 1
  fi
  if [ -z "$GITHUB_OPT_REPO" ]; then
    echo "github needs --repo OWNER/NAME" >&2
    return 1
  fi
  case "$GITHUB_OPT_REPO" in
    */*) ;;
    *) printf 'invalid --repo: %s (expected OWNER/NAME)\n' "$GITHUB_OPT_REPO" >&2; return 1 ;;
  esac
  return 0
}

github_get() {
  herdr_ingest_http_get "$GITHUB_OPT_API$1" 'github api' \
    -H "Authorization: Bearer $GITHUB_OPT_TOKEN" \
    -H 'X-GitHub-Api-Version: 2022-11-28'
}

ingest_source_fetch() {
  local path
  path="/repos/$GITHUB_OPT_REPO/issues"
  path+="?state=$(herdr_ingest_urlencode "$GITHUB_OPT_STATE")"
  path+="&per_page=$GITHUB_OPT_FETCH_LIMIT&sort=updated&direction=desc"
  [ -n "$GITHUB_OPT_LABELS" ] && path+="&labels=$(herdr_ingest_urlencode "$GITHUB_OPT_LABELS")"
  [ -n "$GITHUB_OPT_ASSIGNEE" ] && path+="&assignee=$(herdr_ingest_urlencode "$GITHUB_OPT_ASSIGNEE")"
  github_get "$path"
}

ingest_source_normalize() {
  jq -c '
    def nodes:
      if type == "array" then .
      elif has("items") then (.items // [])
      else [.] end;
    def s: if . == null then "" else tostring end;

    [ nodes[] | select((.number // null) != null) | . as $i | {
        key:      ($i.number | tostring),
        ref:      ("#" + ($i.number | tostring)),
        title:    ($i.title // "untitled"),
        subtitle: ([($i.user.login // ""), ($i.milestone.title // "")]
                   | map(select(. != "")) | join(" · ")),
        url:      ($i.html_url | s),
        branch:   "",
        badge:    (if ($i.pull_request // null) != null then "pr" else "issue" end),
        state:    ($i.state // "open"),
        created:  ($i.created_at | s),
        updated:  ($i.updated_at | s),
        labels:   ([($i.labels // [])[] | if type == "object" then (.name // "") else (. | s) end]
                   | map(select(. != ""))),
        fields: [
          {name: "kind",      value: (if ($i.pull_request // null) != null then "pull request" else "issue" end)},
          {name: "state",     value: ($i.state // "open")},
          {name: "author",    value: ($i.user.login // "-")},
          {name: "assignees", value: ([($i.assignees // [])[] | .login // ""] | map(select(. != ""))
                                      | if length == 0 then "unassigned" else join(", ") end)},
          {name: "comments",  value: (($i.comments // 0) | tostring)},
          {name: "milestone", value: ($i.milestone.title // "-")},
          {name: "link",      value: ($i.html_url // "-")}
        ],
        body:     ($i.body | s),
        raw:      $i
      } ]
  '
}

# Stage 4 for this source: the discussion. Best effort — a failure prints
# nothing and the engine carries on without a Context section.
ingest_source_summarise() {
  local item="$1" number comments
  number="$(jq -r '.key' "$item" 2>/dev/null)" || return 0
  [ -n "$number" ] || return 0
  [ -n "$GITHUB_OPT_TOKEN" ] || return 0
  [ "$(jq -r '(.raw.comments // 0) | tostring' "$item" 2>/dev/null)" != "0" ] || return 0

  comments="$(github_get \
    "/repos/$GITHUB_OPT_REPO/issues/$number/comments?per_page=$GITHUB_OPT_COMMENTS" \
    2>/dev/null)" || return 0
  [ -n "$comments" ] || return 0

  printf 'Discussion:\n\n'
  printf '%s' "$comments" | jq -r --argjson n "$GITHUB_OPT_COMMENTS" '
    if type != "array" or length == 0 then empty
    else (.[-$n:][] |
      "**\(.user.login // "someone")** · \((.created_at // "") | .[0:16])\n\n\(.body // "")\n")
    end' 2>/dev/null
}
