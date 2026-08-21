# Source: Linear issues.
#
# Fetches every issue of one project, following the cursor, and folds the
# description and the discussion into the item body. There is no stage-4
# summariser here on purpose: Linear already ships the prose, so the default run
# has stage 4 off and the brief is built from the body alone. Add one with
# --summarise CMD when you want a model to compress a long thread.
#
# This source does not track a triage FSM. herdr-linear owns that; this is the
# ingestion half only.

# shellcheck shell=bash
# The HERDR_INGEST_* variables this file sets (the source id/prefix/sort/badge
# order here, and HERDR_INGEST_OPT_SHIFT below) are the adapter's published
# interface: the engine reads them after it sources this file, so shellcheck
# cannot see the use from here. This directive precedes the first command, so
# it applies file-wide.
# shellcheck disable=SC2034
HERDR_INGEST_SOURCE_ID="linear"
HERDR_INGEST_SOURCE_PREFIX="linear"
HERDR_INGEST_SOURCE_SORT="badge"
HERDR_INGEST_SOURCE_BADGE_ORDER='["urgent","high","medium","low","none"]'

LINEAR_OPT_PROJECT="${HERDR_INGEST_LINEAR_PROJECT:-${LINEAR_PROJECT:-}}"
LINEAR_OPT_TEAM="${HERDR_INGEST_LINEAR_TEAM:-${LINEAR_TEAM:-}}"
LINEAR_OPT_API="${HERDR_INGEST_LINEAR_API_BASE:-${LINEAR_API_BASE:-https://api.linear.app/graphql}}"
LINEAR_OPT_STATES="${HERDR_INGEST_LINEAR_STATE_TYPES:-triage,backlog,unstarted,started}"
LINEAR_OPT_FETCH_LIMIT="${HERDR_INGEST_LINEAR_FETCH_LIMIT:-100}"
LINEAR_OPT_TOKEN=""
LINEAR_PAGE_SIZE=50

ingest_source_describe() {
  printf 'id\tlinear\n'
  printf 'name\tLinear\n'
  printf 'summary\tissues of one team or project, with description and discussion\n'
  printf 'needs\tcurl jq\n'
}

ingest_source_usage() {
  cat <<EOF
linear source flags:
  --project REF        Linear project: a uuid, a project URL, a slug id or a name
  --team KEY           Linear team key, e.g. ENG (default: ${LINEAR_OPT_TEAM:-none})
                       --team or --project is required for a live fetch; give
                       both to narrow to that project within that team
  --api-base URL       Linear GraphQL endpoint (default: $LINEAR_OPT_API)
  --state-types CSV    workflow state types to fetch: triage, backlog, unstarted,
                       started, completed, canceled (default: $LINEAR_OPT_STATES)
  --fetch-limit N      issues to fetch across all pages (default: $LINEAR_OPT_FETCH_LIMIT)

linear environment:
  LINEAR_API_KEY       personal API key, or an OAuth access token
  LINEAR_PROJECT       default for --project
  LINEAR_TEAM          default for --team
  LINEAR_API_BASE      default for --api-base
  HERDR_INGEST_LINEAR_*  every flag above, upper-cased, e.g.
                       HERDR_INGEST_LINEAR_STATE_TYPES; set them in a profile

The badge is the priority label, ranked urgent > high > medium > low > none, so
the default --sort badge is most-urgent-first and --badge urgent,high keeps only
those. --state filters on the state name (\`In Progress\`), --state-types filters
on the state type Linear groups them under.

Each item carries Linear's own branch name, so a worktree is cut on the branch
the Linear UI would have suggested. Stage 4 is off unless you supply a
summariser: the description and the comments are already in the brief.
EOF
}

ingest_source_option() {
  case "$1" in
    --project) LINEAR_OPT_PROJECT="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --team) LINEAR_OPT_TEAM="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --api-base) LINEAR_OPT_API="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --state-types) LINEAR_OPT_STATES="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --fetch-limit)
      herdr_ingest_positive_int --fetch-limit "${2:-}" || return 1
      LINEAR_OPT_FETCH_LIMIT="$2"; HERDR_INGEST_OPT_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

ingest_source_check() {
  command -v curl >/dev/null || { echo "curl not found" >&2; return 1; }
  LINEAR_OPT_TOKEN="${LINEAR_API_KEY:-${HERDR_INGEST_LINEAR_TOKEN:-}}"
  if [ -z "$LINEAR_OPT_TOKEN" ]; then
    cat >&2 <<'EOF'
no Linear API key found. Create one under Settings -> Security & access -> API
-> Personal API keys, then

  export LINEAR_API_KEY=<key>

To run without any key, pass --items-json FILE with a Linear issues payload.
EOF
    return 1
  fi
  if [ -z "$LINEAR_OPT_PROJECT" ] && [ -z "$LINEAR_OPT_TEAM" ]; then
    echo "linear needs --team (a team key like ENG) or --project (a uuid, a project URL, a slug id or a name)" >&2
    return 1
  fi
  return 0
}

# Linear sends a personal API key bare and an OAuth access token with a Bearer
# prefix. The two are told apart by shape: keys start with `lin_api_`.
linear_auth_header() {
  case "$LINEAR_OPT_TOKEN" in
    lin_api_*) printf 'Authorization: %s' "$LINEAR_OPT_TOKEN" ;;
    *) printf 'Authorization: Bearer %s' "$LINEAR_OPT_TOKEN" ;;
  esac
}

# The GraphQL project filter for a reference: a uuid matches by id, a URL or a
# bare slug id matches by slugId, anything else matches by name.
linear_project_filter() {
  local ref="$1" slug
  if [[ "$ref" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    jq -nc --arg v "$ref" '{project: {id: {eq: $v}}}'
    return 0
  fi
  case "$ref" in
    http*://*)
      slug="${ref%%\?*}"
      slug="${slug##*/}"
      jq -nc --arg v "$slug" '{project: {slugId: {eq: $v}}}'
      return 0 ;;
  esac
  if [[ "$ref" =~ ^[0-9a-f]{8,}$ ]]; then
    jq -nc --arg v "$ref" '{project: {slugId: {eq: $v}}}'
    return 0
  fi
  jq -nc --arg v "$ref" '{project: {name: {eqIgnoreCase: $v}}}'
}

LINEAR_QUERY='query Issues($filter: IssueFilter, $first: Int!, $after: String) {
  issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) {
    pageInfo { hasNextPage endCursor }
    nodes {
      id identifier title description url branchName priority priorityLabel
      estimate createdAt updatedAt dueDate
      state { name type }
      assignee { displayName email }
      creator { displayName }
      labels { nodes { name } }
      project { id name }
      team { key name }
      parent { identifier }
      attachments { nodes { title url } }
      comments { nodes { createdAt body user { displayName } } }
    }
  }
}'

# Every issue of the project, following the cursor until the page is the last one
# or the fetch limit is in hand. The raw nodes land on stdout as one array.
ingest_source_fetch() {
  local filter base='{}' states payload page pages cursor="" have=0 want page_size
  states="$(herdr_ingest_csv_json "$LINEAR_OPT_STATES")"
  if [ -n "$LINEAR_OPT_PROJECT" ]; then
    base="$(linear_project_filter "$LINEAR_OPT_PROJECT")"
  fi
  if [ -n "$LINEAR_OPT_TEAM" ]; then
    base="$(printf '%s' "$base" | jq -c --arg v "$LINEAR_OPT_TEAM" '. + {team: {key: {eq: $v}}}')"
  fi
  filter="$(printf '%s' "$base" \
    | jq -c --argjson types "$states" \
      'if ($types | length) > 0 then . + {state: {type: {in: $types}}} else . end')"

  # One page's nodes array per line, then one `add`: no string splicing, so a
  # description carrying a comma or a brace cannot corrupt the payload.
  pages="$(mktemp)" || return 1
  while :; do
    want=$((LINEAR_OPT_FETCH_LIMIT - have))
    [ "$want" -gt 0 ] || break
    page_size=$((want < LINEAR_PAGE_SIZE ? want : LINEAR_PAGE_SIZE))
    payload="$(jq -nc --arg q "$LINEAR_QUERY" --argjson f "$filter" \
      --argjson n "$page_size" --arg c "$cursor" \
      '{query: $q, variables: {filter: $f, first: $n, after: (if $c == "" then null else $c end)}}')"
    page="$(herdr_ingest_http_post_json "$LINEAR_OPT_API" 'linear api' "$payload" \
      -H "$(linear_auth_header)")" || { rm -f "$pages"; return 1; }

    printf '%s' "$page" | jq -c '.data.issues.nodes // []' >>"$pages"
    have=$((have + $(printf '%s' "$page" | jq '(.data.issues.nodes // []) | length')))

    if [ "$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage')" != "true" ]; then break; fi
    cursor="$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.endCursor // ""')"
    [ -n "$cursor" ] || break
  done

  jq -sc --argjson n "$LINEAR_OPT_FETCH_LIMIT" '(add // []) | .[0:$n]' "$pages"
  rm -f "$pages"
}

# One shape for every payload. A GraphQL response, a bare array of nodes, and the
# flatter payload a Linear MCP client emits all normalise to the same items.
ingest_source_normalize() {
  jq -c '
    def nodes:
      if type == "array" then .
      elif has("data") then (.data.issues.nodes // .data.issues // [])
      elif has("issues") then (.issues | if type == "array" then . else (.nodes // []) end)
      elif has("nodes") then .nodes
      else [.] end;
    def s: if . == null then "" else tostring end;
    def person:
      if type == "object" and . != null then (.displayName // .name // "" | s)
      elif type == "string" then .
      else "" end;
    def names:
      if type == "object" and . != null then [(.nodes // [])[] | (.name // "" | s)]
      elif type == "array" then [.[] | if type == "object" then (.name // "" | s) else (. | s) end]
      else [] end;
    def listed:
      if type == "object" and . != null then (.nodes // [])
      elif type == "array" then .
      else [] end;

    def prio: if (.priority | type) == "number" then .priority
              elif (.priority | type) == "object" then (.priority.value // 0)
              else 0 end;
    def prio_label:
      if (.priorityLabel // "") != "" then (.priorityLabel | ascii_downcase)
      elif (.priority | type) == "object" and (.priority.name // "") != "" then (.priority.name | ascii_downcase)
      else (prio | if . == 1 then "urgent" elif . == 2 then "high"
                   elif . == 3 then "medium" elif . == 4 then "low" else "none" end)
      end;

    def ident:
      if (.identifier // "") != "" then .identifier
      elif ((.id // "") | tostring | test("^[A-Za-z]+-[0-9]+$")) then (.id | ascii_upcase)
      else "" end;

    def discussion:
      (.comments | listed) as $cs
      | if ($cs | length) == 0 then ""
        else "\n\n### Discussion\n\n"
             + ([$cs[] |
                 "**" + ((.user // .author) | person | if . == "" then "someone" else . end) + "**"
                 + (if (.createdAt // .at // "") != "" then " · " + ((.createdAt // .at) | .[0:16]) else "" end)
                 + "\n\n" + (.body // "" | s) ] | join("\n\n"))
        end;

    [ nodes[] | select(ident != "") | . as $i | {
        key:      ($i | ident),
        ref:      ($i | ident),
        title:    ($i.title // "untitled"),
        subtitle: ([ (if ($i.team | type) == "object" then ($i.team.name // "") else "" end),
                     (if ($i.project | type) == "object" then ($i.project.name // "") else "" end) ]
                   | map(select(. != "")) | join(" · ")),
        url:      ($i.url | s),
        branch:   ($i.branchName // $i.gitBranchName // "" | s),
        badge:    ($i | prio_label),
        state:    (if ($i.state | type) == "object" then ($i.state.name // "?") else ($i.status // "?" | s) end),
        created:  ($i.createdAt | s),
        updated:  ($i.updatedAt | s),
        labels:   ($i.labels | names),
        fields: ([
          {name: "priority", value: ($i | prio_label)},
          {name: "state",    value: (if ($i.state | type) == "object" then ($i.state.name // "-") else "-" end)},
          {name: "assignee", value: (($i.assignee | person) | if . == "" then "unassigned" else . end)},
          {name: "creator",  value: (($i.creator | person) | if . == "" then "-" else . end)},
          {name: "estimate", value: (if ($i.estimate | type) == "number" then ($i.estimate | tostring) else "-" end)},
          {name: "due",      value: ($i.dueDate // "-" | s)},
          {name: "parent",   value: (if ($i.parent | type) == "object" then ($i.parent.identifier // "-") else "-" end)},
          {name: "link",     value: ($i.url // "-" | s)}
        ] + [ ($i.attachments | listed)[] | {name: "attachment", value: ((.title // "link") + " " + (.url // ""))} ]),
        body:     (($i.description // "" | s) + ($i | discussion)),
        raw:      $i
      } ]
  '
}
