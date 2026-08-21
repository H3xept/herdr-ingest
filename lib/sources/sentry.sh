# Source: Sentry issues.
#
# Fetches the issues of one project active inside a window, and ships a stage-4
# summariser that pulls each issue's newest event and renders its stack trace.
# That summariser is the source's default, not a requirement: --no-summarise
# turns it off and --summarise CMD replaces it.
#
# The engine provides jq, curl, herdr_ingest_http_get, herdr_ingest_urlencode
# and herdr_ingest_window_seconds. This file adds nothing else to PATH.

# shellcheck shell=bash
# The HERDR_INGEST_* variables this file sets (the source id/prefix/sort/badge
# order here, and HERDR_INGEST_OPT_SHIFT below) are the adapter's published
# interface: the engine reads them after it sources this file, so shellcheck
# cannot see the use from here. This directive precedes the first command, so
# it applies file-wide.
# shellcheck disable=SC2034
HERDR_INGEST_SOURCE_ID="sentry"
HERDR_INGEST_SOURCE_PREFIX="sentry"
HERDR_INGEST_SOURCE_SORT="updated"
HERDR_INGEST_SOURCE_BADGE_ORDER='["fatal","error","warning","info","debug","sample"]'

SENTRY_OPT_ORG="${HERDR_INGEST_SENTRY_ORG:-${SENTRY_ORG:-}}"
SENTRY_OPT_PROJECT="${HERDR_INGEST_SENTRY_PROJECT:-${SENTRY_PROJECT:-}}"
SENTRY_OPT_API="${HERDR_INGEST_SENTRY_API_BASE:-${SENTRY_API_BASE:-https://us.sentry.io}}"
SENTRY_OPT_QUERY="${HERDR_INGEST_SENTRY_QUERY:-is:unresolved}"
SENTRY_OPT_WINDOW="${HERDR_INGEST_SENTRY_ACTIVE_LAST:-24h}"
SENTRY_OPT_FETCH_SORT="${HERDR_INGEST_SENTRY_FETCH_SORT:-date}"
SENTRY_OPT_FETCH_LIMIT="${HERDR_INGEST_SENTRY_FETCH_LIMIT:-100}"
SENTRY_OPT_TOKEN=""

ingest_source_describe() {
  printf 'id\tsentry\n'
  printf 'name\tSentry\n'
  printf 'summary\tissues of one project active inside a window\n'
  printf 'needs\tcurl jq\n'
}

ingest_source_usage() {
  cat <<EOF
sentry source flags:
  --org SLUG           Sentry organization slug (required; default: ${SENTRY_OPT_ORG:-none})
  --project SLUG       Sentry project slug (required; default: ${SENTRY_OPT_PROJECT:-none})
  --api-base URL       Sentry API host (default: $SENTRY_OPT_API)
  --query STR          Sentry search prefix (default: $SENTRY_OPT_QUERY)
  --active-last WINDOW issues seen within this window: 5m, 2h, 2d, 1w (default: $SENTRY_OPT_WINDOW)
  --fetch-sort KEY     server-side order: date, freq, new or user (default: $SENTRY_OPT_FETCH_SORT)
  --fetch-limit N      issues to fetch, at most 100 (default: $SENTRY_OPT_FETCH_LIMIT)

sentry environment:
  SENTRY_AUTH_TOKEN    bearer token, needs the event:read and project:read scopes
  SENTRY_ORG           default for --org
  SENTRY_PROJECT       default for --project
  SENTRY_API_BASE      default for --api-base
  HERDR_INGEST_SENTRY_*  every flag above, upper-cased, e.g.
                       HERDR_INGEST_SENTRY_ACTIVE_LAST; set them in a profile

Stage 4 defaults to this source's own summariser: it fetches each issue's newest
event and renders the top frames of its stack trace into the brief's Context
section. --no-summarise skips the extra request entirely.

The badge is the issue level, ranked fatal > error > warning > info > debug, so
--sort badge orders by severity and --badge error,fatal keeps only those.
EOF
}

ingest_source_option() {
  case "$1" in
    --org) SENTRY_OPT_ORG="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --project) SENTRY_OPT_PROJECT="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --api-base) SENTRY_OPT_API="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --query) SENTRY_OPT_QUERY="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --active-last | --activeLast)
      herdr_ingest_window_seconds "${2:-}" >/dev/null || return 1
      SENTRY_OPT_WINDOW="$2"; HERDR_INGEST_OPT_SHIFT=2 ;;
    --fetch-sort)
      case "${2:-}" in
        date | freq | new | user) SENTRY_OPT_FETCH_SORT="$2" ;;
        *) printf 'invalid value for --fetch-sort: %s (expected date, freq, new or user)\n' "${2:-}" >&2; return 1 ;;
      esac
      HERDR_INGEST_OPT_SHIFT=2 ;;
    --fetch-limit)
      herdr_ingest_positive_int --fetch-limit "${2:-}" || return 1
      if [ "$2" -gt 100 ]; then
        printf 'invalid value for --fetch-limit: %s (the Sentry maximum is 100)\n' "$2" >&2
        return 1
      fi
      SENTRY_OPT_FETCH_LIMIT="$2"; HERDR_INGEST_OPT_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

# A bearer token, from the environment or from sentry-cli's own config.
ingest_source_check() {
  command -v curl >/dev/null || { echo "curl not found" >&2; return 1; }
  SENTRY_OPT_TOKEN="${SENTRY_AUTH_TOKEN:-${HERDR_INGEST_SENTRY_TOKEN:-}}"
  if [ -z "$SENTRY_OPT_TOKEN" ] && [ -f "$HOME/.sentryclirc" ]; then
    SENTRY_OPT_TOKEN="$(sed -n 's/^[[:space:]]*token[[:space:]]*=[[:space:]]*//p' "$HOME/.sentryclirc" | head -1)"
  fi
  if [ -z "$SENTRY_OPT_TOKEN" ]; then
    cat >&2 <<'EOF'
no Sentry token found. Create one with the scopes event:read and project:read at
https://sentry.io/settings/account/api/auth-tokens/ then either

  export SENTRY_AUTH_TOKEN=<token>

or put it in ~/.sentryclirc as `token = <token>`. To run without any token, pass
--items-json FILE with a Sentry issues payload.
EOF
    return 1
  fi
  if [ -z "$SENTRY_OPT_ORG" ] || [ -z "$SENTRY_OPT_PROJECT" ]; then
    cat >&2 <<'EOF'
the sentry source needs an organization and a project. Pass them as flags

  --org <slug> --project <slug>

or set SENTRY_ORG and SENTRY_PROJECT, or put them in a profile as
HERDR_INGEST_SENTRY_ORG and HERDR_INGEST_SENTRY_PROJECT.
EOF
    return 1
  fi
  return 0
}

# The window bounds the search precisely; statsPeriod bounds the query Sentry
# runs behind it, so it must round up, never down. Sentry caps it at 90d.
sentry_stats_period() {
  local secs="$1" days
  if [ "$secs" -le 3600 ]; then printf '1h'; return 0; fi
  if [ "$secs" -le 86400 ]; then printf '24h'; return 0; fi
  days=$(((secs + 86399) / 86400))
  if [ "$days" -gt 90 ]; then days=90; fi
  printf '%sd' "$days"
}

ingest_source_fetch() {
  local secs period path
  secs="$(herdr_ingest_window_seconds "$SENTRY_OPT_WINDOW")" || return 1
  period="$(sentry_stats_period "$secs")"
  path="/api/0/organizations/$(herdr_ingest_urlencode "$SENTRY_OPT_ORG")/issues/"
  path+="?project=$(herdr_ingest_urlencode "$SENTRY_OPT_PROJECT")"
  path+="&query=$(herdr_ingest_urlencode "$SENTRY_OPT_QUERY lastSeen:-$SENTRY_OPT_WINDOW")"
  path+="&statsPeriod=$period"
  path+="&sort=$(herdr_ingest_urlencode "$SENTRY_OPT_FETCH_SORT")"
  path+="&limit=$SENTRY_OPT_FETCH_LIMIT"
  herdr_ingest_http_get "$SENTRY_OPT_API$path" 'sentry api' \
    -H "Authorization: Bearer $SENTRY_OPT_TOKEN"
}

# One shape for every payload: the API array, an object wrapping it, and a single
# issue all reduce to the same canonical items.
ingest_source_normalize() {
  jq -c '
    def nodes:
      if type == "array" then .
      elif has("issues") then (.issues | if type == "array" then . else [.] end)
      elif has("data") then (.data | if type == "array" then . else [.] end)
      else [.] end;
    def s: if . == null then "" else tostring end;

    [ nodes[] | select((.id // "") != "") | . as $i | {
        key:      ($i.id | tostring),
        ref:      ($i.shortId // ("sentry-" + ($i.id | tostring))),
        title:    ($i.title // $i.metadata.type // "untitled"),
        subtitle: ($i.culprit | s),
        url:      ($i.permalink | s),
        branch:   "",
        badge:    ($i.level // "error"),
        state:    (($i.status | s) + (if ($i.substatus // "") != "" then "/" + $i.substatus else "" end)),
        created:  ($i.firstSeen | s),
        updated:  ($i.lastSeen | s),
        labels:   ([$i.metadata.type // empty] | map(select(. != ""))),
        fields: [
          {name: "level",          value: ($i.level // "?")},
          {name: "events",         value: (($i.count // 0) | tostring)},
          {name: "users affected", value: (($i.userCount // 0) | tostring)},
          {name: "first seen",     value: ($i.firstSeen // "-")},
          {name: "last seen",      value: ($i.lastSeen // "-")},
          {name: "culprit",        value: ("`" + ($i.culprit // "-") + "`")},
          {name: "exception",      value: ("`" + ($i.metadata.type // "-") + ": " + (($i.metadata.value // "-") | tostring) + "`")},
          {name: "permalink",      value: ($i.permalink // "-")}
        ],
        body:     "",
        raw:      $i
      } ]
  '
}

# Stage 4 for this source: the newest event, as a stack trace. Best effort — a
# brief without a trace still beats no brief, so a failure prints nothing and
# the engine carries on.
ingest_source_summarise() {
  local item="$1" id path event
  id="$(jq -r '.key' "$item" 2>/dev/null)" || return 0
  [ -n "$id" ] || return 0
  [ -n "$SENTRY_OPT_TOKEN" ] || return 0

  path="/api/0/organizations/$(herdr_ingest_urlencode "$SENTRY_OPT_ORG")/issues/"
  path+="$(herdr_ingest_urlencode "$id")/events/?full=1&per_page=1"
  event="$(herdr_ingest_http_get "$SENTRY_OPT_API$path" 'sentry api' \
    -H "Authorization: Bearer $SENTRY_OPT_TOKEN" 2>/dev/null \
    | jq -c 'if type=="array" then .[0] else . end // empty' 2>/dev/null)" || return 0
  [ -n "$event" ] || return 0

  printf 'Newest event:\n\n```\n'
  printf '%s' "$event" | jq -r '
    (.eventID // "" | select(length > 0) | "event " + .),
    (.dateCreated // "" | select(length > 0) | "at " + .),
    ((.tags // []) | map(select(.key == "environment" or .key == "release" or .key == "server_name"))
      | .[] | "\(.key)=\(.value)"),
    ((.entries // []) | map(select(.type == "exception")) | .[0].data.values // [] | .[] |
      "\(.type // "Exception"): \(.value // "")",
      ((.stacktrace.frames // []) | reverse | .[0:12] | .[] |
        "  at \(.function // "?") (\(.filename // .absPath // "?"):\(.lineNo // 0))"))
  ' 2>/dev/null || printf '(unreadable event payload)\n'
  printf '```\n'
}
