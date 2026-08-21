# Source: any pipeline at all.
#
# This is the escape hatch, and it is the reason the product is not tied to a
# tracker. Point --json-cmd at anything that prints JSON — a Jira curl, a `gh
# api` call, a psql query, a Python script, a saved payload — and give
# --json-map the jq expression that turns it into canonical items.
#
# The canonical item is:
#   key      required, unique, stable; becomes the worktree and branch name
#   ref      short handle; becomes the space label     (default: key)
#   title    one line                                 (default: "untitled")
#   subtitle one line of location or context
#   url      where a human reads the item
#   branch   the branch to cut; empty lets the engine derive one
#   badge    one word of severity or priority
#   state    one word of workflow position
#   created  ISO 8601
#   updated  ISO 8601
#   labels   array of strings
#   fields   array of {name, value}; the brief table and the preview
#   body     markdown
#   raw      anything a hook may want later
#
# Every field but `key` is optional. Whatever you omit, the engine fills in.

# shellcheck shell=bash
# The HERDR_INGEST_* variables this file sets (the source id/prefix/sort/badge
# order here, and HERDR_INGEST_OPT_SHIFT below) are the adapter's published
# interface: the engine reads them after it sources this file, so shellcheck
# cannot see the use from here. This directive precedes the first command, so
# it applies file-wide.
# shellcheck disable=SC2034
HERDR_INGEST_SOURCE_ID="json"
HERDR_INGEST_SOURCE_PREFIX="item"
HERDR_INGEST_SOURCE_SORT="none"
HERDR_INGEST_SOURCE_BADGE_ORDER='[]'

JSON_OPT_CMD="${HERDR_INGEST_JSON_CMD:-}"
JSON_OPT_MAP="${HERDR_INGEST_JSON_MAP:-.}"

ingest_source_describe() {
  printf 'id\tjson\n'
  printf 'name\tJSON\n'
  printf 'summary\tany command or file that prints JSON, mapped by a jq expression\n'
  printf 'needs\tjq\n'
}

ingest_source_usage() {
  cat <<'EOF'
json source flags:
  --json-cmd CMD       shell command whose stdout is the raw payload; omit it and
                       pass --items-json FILE instead
  --json-map EXPR      jq expression from the raw payload to canonical items
                       (default: `.`, i.e. the payload already holds items)

json environment:
  HERDR_INGEST_JSON_CMD  default for --json-cmd
  HERDR_INGEST_JSON_MAP  default for --json-map

The canonical item is one object with these keys, and `key` is the only required
one:

  key ref title subtitle url branch badge state created updated
  labels[] fields[{name,value}] body raw

Everything you leave out is filled in by the engine, so the smallest useful
mapping is one key and one title:

  herdr-ingest --source json \
    --json-cmd 'jira-export --project ENG' \
    --json-map '[.issues[] | {key: .key, title: .fields.summary,
                              url: .self, badge: (.fields.priority.name|ascii_downcase),
                              state: .fields.status.name, updated: .fields.updated,
                              body: .fields.description}]' \
    --prefix jira --dry-run

Set --prefix to namespace the worktrees and branches this source produces; it
defaults to `item`.
EOF
}

ingest_source_option() {
  case "$1" in
    --json-cmd) JSON_OPT_CMD="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --json-map) JSON_OPT_MAP="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

ingest_source_check() {
  if [ -z "$JSON_OPT_CMD" ]; then
    echo "json needs --json-cmd CMD, or --items-json FILE to read a saved payload" >&2
    return 1
  fi
  return 0
}

ingest_source_fetch() {
  bash -c "$JSON_OPT_CMD"
}

ingest_source_normalize() {
  jq -c "$JSON_OPT_MAP"
}
