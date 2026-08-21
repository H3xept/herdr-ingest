#!/usr/bin/env bash
# herdr-ingest — one herdr space per work item, from any ingestion source.
#
# The name is provisional; the product is not Sentry-specific. Every function
# here is prefixed herdr_ingest_, and the vocabulary is `item`, `source`,
# `summary`, `brief`, `space` — never `issue` and never `sentry`.
#
# The pipeline is six stages, and the middle two are yours to replace:
#
#   1 fetch      the source pulls a raw payload            (source)
#   2 normalise  the payload becomes canonical items       (source)
#   3 select     filter, sort, cap, then auto or fzf pick  (engine)
#   4 summarise  one item gains extra context              (source | hook | off)
#   5 prompt     one item becomes the brief an agent reads (built-in | hook | off)
#   6 spawn      worktree + herdr space + a lazy pane      (engine)
#
# Stage 6 never starts an agent. The right-hand pane prints the brief and waits
# for an explicit `y`; anything else drops to a login shell. That gate is the
# cost-control contract of the product and no flag removes it.
#
# The root is a worktree farm: a directory holding a main checkout plus one
# sibling worktree per branch. Each selected item gets its own sibling worktree,
# cut from the main checkout, and its own herdr space:
#   left  stack: terminal (focused, on top) + `nvim .`
#   right stack: one pane holding the brief, waiting for `y`
#
# Re-running is safe: an item whose worktree, branch or space already exists is
# reused or skipped, never duplicated.
#
# This file is safe to source: sourcing defines the herdr_ingest_* functions and
# runs nothing. Executing it runs herdr_ingest_main.

HERDR_INGEST_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HERDR_INGEST_HOME="$(cd -- "$HERDR_INGEST_LIB_DIR/.." && pwd)"
HERDR_INGEST_SELF="$HERDR_INGEST_HOME/bin/herdr-ingest"
HERDR_INGEST_SOURCE_DIR="$HERDR_INGEST_LIB_DIR/sources"

# Defaults. Every one is overridable by a flag; see herdr_ingest_usage.
HERDR_INGEST_DEFAULT_SOURCE="sentry"
HERDR_INGEST_DEFAULT_ROOT="$HOME/farm"
HERDR_INGEST_DEFAULT_LIMIT=100
HERDR_INGEST_DEFAULT_MAX_SPACES=5
HERDR_INGEST_DEFAULT_INTERVAL=180
HERDR_INGEST_DEFAULT_AGENT="omp"

herdr_ingest_version() {
  printf '1.0.0\n'
}

# Fill a global only when nothing has set it yet. Four layers decide a knob —
# these defaults, the profile, the source, then the flags — and each one only
# fills what the layer before it left empty, so no layer can clobber a decision
# an earlier one already made. `${VAR:=default}` cannot do this: a default
# carrying a brace, such as a worktree template, breaks its parse.
herdr_ingest_seed() {
  local name="$1"
  [ -n "${!name:-}" ] && return 0
  eval "$name=\$2"
}

# A herdr popup pane closes the instant its command exits, which swallows both a
# picker's result lines and a configuration error. --pane holds the popup open
# until a key is pressed. With no terminal on stdout it is a no-op, so a script
# and the test suite never block on it.
herdr_ingest_pane_hold() {
  local rc=$?
  [ -t 1 ] || return "$rc"
  printf '\n[any key closes this pane]'
  read -r -n 1 -s _ </dev/tty 2>/dev/null || true
  printf '\n'
  return "$rc"
}

# --- the canonical item ------------------------------------------------------
# Stage 2 hands stage 3 an array of these, and nothing downstream knows which
# source produced them. `key` and `title` are required; the rest default.
#
#   key       stable unique id; becomes the worktree and branch name
#   ref       short human handle; becomes the space label (default: key)
#   title     one line
#   subtitle  one line of location or context
#   url       where a human reads the item
#   branch    the branch the source wants; empty means the engine derives one
#   badge     one word of severity or priority, ranked by the source
#   state     one word of workflow position
#   created   ISO 8601
#   updated   ISO 8601
#   labels    array of strings
#   fields    array of {name, value}; the brief table and the preview
#   body      markdown; description, discussion, whatever the source has
#   raw       the untouched source payload, for a hook that wants more

# Force any payload into an array of items, then fill in every optional field so
# no consumer downstream needs a `// ""`.
herdr_ingest_canonicalize() {
  jq -c '
    def arr:
      if type == "array" then .
      elif type == "object" and (has("items")) then (.items | if type == "array" then . else [.] end)
      elif type == "object" then [.]
      else [] end;
    def str: if . == null then "" else tostring end;
    def item:
      {
        key:      (.key      | str),
        ref:      (if (.ref // "") == "" then (.key | str) else (.ref | str) end),
        title:    (if (.title // "") == "" then "untitled" else (.title | str) end),
        subtitle: (.subtitle | str),
        url:      (.url      | str),
        branch:   (.branch   | str),
        badge:    (.badge    | str),
        state:    (.state    | str),
        created:  (.created  | str),
        updated:  (.updated  | str),
        labels:   (if (.labels | type) == "array" then [.labels[] | str] else [] end),
        fields:   (if (.fields | type) == "array"
                   then [.fields[] | {name: (.name | str), value: (.value | str)}]
                   else [] end),
        body:     (.body     | str),
        raw:      (if .raw == null then {} else .raw end)
      };
    [arr[] | item] | map(select(.key != ""))
  '
}

# The jq prelude every date-aware filter shares. Linear sends offsets, Sentry
# sends fractional seconds, and a bare date has no time at all; all three must
# reduce to one epoch or to null.
HERDR_INGEST_JQ_EPOCH='
def epoch:
  if . == null or . == "" then null
  else (tostring
        | sub("\\.[0-9]+"; "")
        | sub("[+-][0-9]{2}:[0-9]{2}$"; "Z")
        | (if test("T") then . else . + "T00:00:00" end)
        | (if test("Z$") then . else . + "Z" end)
        | fromdateiso8601?)
  end;
'

# --- names, windows and escaping ---------------------------------------------

herdr_ingest_cache_dir() {
  printf '%s' "${HERDR_INGEST_CACHE:-$HOME/.cache/herdr-ingest-$1}"
}

herdr_ingest_root_name() {
  local name
  name="$(basename -- "$1" | tr -c 'A-Za-z0-9_-' '-')"
  printf '%s' "${name%-}"
}

# 5m 2h 2d 1w -> seconds. Anything else fails, so a typo never widens a sweep.
herdr_ingest_window_seconds() {
  local w="${1:-}" n u
  if [[ ! "$w" =~ ^([0-9]+)([smhdw])$ ]]; then
    printf 'invalid window: %s (expected a count and one of s, m, h, d, w, e.g. 5m or 2d)\n' "$w" >&2
    return 1
  fi
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  if [ "$n" -le 0 ]; then
    printf 'invalid window: %s (expected a positive count)\n' "$w" >&2
    return 1
  fi
  case "$u" in
    s) printf '%s' "$n" ;;
    m) printf '%s' "$((n * 60))" ;;
    h) printf '%s' "$((n * 3600))" ;;
    d) printf '%s' "$((n * 86400))" ;;
    w) printf '%s' "$((n * 604800))" ;;
  esac
}

herdr_ingest_positive_int() {
  local name="$1" value="${2:-}"
  if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then return 0; fi
  printf 'invalid value for %s: %s (expected a positive integer)\n' "$name" "$value" >&2
  return 1
}

herdr_ingest_sanitize()   { printf '%s' "$1" | tr -c 'A-Za-z0-9._ /-' '_' | cut -c1-40; }
herdr_ingest_kdl_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

herdr_ingest_urlencode() {
  local s="$1" i c out=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Branch- and path-safe slug from a title. An exception-class prefix carries no
# information the branch name needs, and truncation stops at a word boundary, so
# the branch reads like the ones a human cuts by hand.
herdr_ingest_slug() {
  local s="$1"
  if [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_.]*:[[:space:]] ]]; then s="${s#*: }"; fi
  s="$(printf '%s' "$s" \
    | tr 'A-Z' 'a-z' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed -e 's/^-//' -e 's/-$//')"
  # 40 characters is the width hand-cut branches already use.
  if [ "${#s}" -gt 40 ]; then
    s="${s:0:41}"
    s="${s%-*}"
  fi
  printf '%s' "$s"
}

# A key, made safe for a path and a branch, without losing its identity: a
# Sentry id stays the id, a Linear identifier only loses its case.
herdr_ingest_key_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | tr -s '-' | sed -e 's/^-//' -e 's/-$//'
}

# {prefix} {key} {ref} {slug} in a template -> the rendered name.
herdr_ingest_render_name() {
  local tpl="$1" prefix="$2" key="$3" ref="$4" slug="$5" out
  out="$tpl"
  out="${out//\{prefix\}/$prefix}"
  out="${out//\{key\}/$key}"
  out="${out//\{ref\}/$ref}"
  out="${out//\{slug\}/$slug}"
  # A template that ends in a dangling separator, because its slug was empty.
  out="${out%-}"
  out="${out%/}"
  printf '%s' "$out"
}

# --- shared HTTP -------------------------------------------------------------
# The sources are thin because these two live here. Both fail on a non-2xx
# status, so no caller ever parses an HTML error page as JSON.

herdr_ingest_http_get() {
  local url="$1" label="$2" raw code body
  shift 2
  raw="$(curl -sS --max-time 30 -H 'Accept: application/json' "$@" \
    -w $'\n%{http_code}' "$url" 2>&1)" || {
    printf '%s request failed: %s\n' "$label" "$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-200)" >&2
    return 1
  }
  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  case "$code" in
    2*) printf '%s' "$body"; return 0 ;;
    401 | 403) printf '%s %s: token rejected or missing a required scope\n' "$label" "$code" >&2 ;;
    404) printf '%s 404: no such resource (%s)\n' "$label" "$url" >&2 ;;
    *) printf '%s %s: %s\n' "$label" "$code" "$(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)" >&2 ;;
  esac
  return 1
}

# POST a JSON body. A GraphQL endpoint answers a query error with HTTP 200 and
# an `errors` array, so the body is checked too.
herdr_ingest_http_post_json() {
  local url="$1" label="$2" payload="$3"
  shift 3
  local raw code body errs
  raw="$(curl -sS --max-time 45 -X POST \
    -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" \
    --data-binary "$payload" -w $'\n%{http_code}' "$url" 2>&1)" || {
    printf '%s request failed: %s\n' "$label" "$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-200)" >&2
    return 1
  }
  code="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  case "$code" in
    2*) ;;
    401 | 403) printf '%s %s: token rejected or missing a required scope\n' "$label" "$code" >&2; return 1 ;;
    *) printf '%s %s: %s\n' "$label" "$code" "$(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)" >&2; return 1 ;;
  esac
  errs="$(printf '%s' "$body" | jq -r '[(.errors // [])[] | .message] | join("; ")' 2>/dev/null)"
  if [ -n "$errs" ]; then
    printf '%s error: %s\n' "$label" "$(printf '%s' "$errs" | cut -c1-200)" >&2
    return 1
  fi
  printf '%s' "$body"
}

# --- stage 3: select ---------------------------------------------------------

# A comma list -> a JSON array of lowercased entries. An empty spec means "all".
herdr_ingest_csv_json() {
  jq -nc --arg s "${1:-}" \
    '$s | ascii_downcase | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# Keep what the filters admit, order it, and cut it to the limit. Every filter
# runs here, over the canonical array, so --items-json and a live fetch agree.
herdr_ingest_filter() {
  local badges="$1" states="$2" labels="$3" match="$4"
  local updated_last="$5" created_last="$6" sort="$7" limit="$8" badge_order="$9"

  jq -c \
    --argjson badges "$badges" --argjson states "$states" --argjson labels "$labels" \
    --arg match "$match" \
    --argjson updatedLast "$updated_last" --argjson createdLast "$created_last" \
    --arg sort "$sort" --argjson limit "$limit" --argjson order "$badge_order" "
    $HERDR_INGEST_JQ_EPOCH
    def rank: . as \$b
      | (\$order | index(\$b | ascii_downcase))
      | if . == null then (\$order | length) else . end;

    map(. as \$i
      | select((\$badges | length) == 0 or (\$badges | index(\$i.badge | ascii_downcase)) != null)
      | select((\$states | length) == 0 or (\$states | index(\$i.state | ascii_downcase)) != null)
      | select((\$labels | length) == 0
               or ((\$i.labels | map(ascii_downcase)) as \$ls
                   | any(\$labels[]; . as \$w | any(\$ls[]; contains(\$w)))))
      | select(\$match == \"\"
               or ((\$i.title + \" \" + \$i.subtitle) | test(\$match; \"i\")))
      | select(\$updatedLast < 0
               or ((\$i.updated | epoch) as \$u | \$u != null and (now - \$u) <= \$updatedLast))
      | select(\$createdLast < 0
               or ((\$i.created | epoch) as \$c | \$c != null and (now - \$c) <= \$createdLast))
    )
    | (if \$sort == \"updated\" then sort_by(0 - ((.updated | epoch) // 0))
       elif \$sort == \"created\" then sort_by(0 - ((.created | epoch) // 0))
       elif \$sort == \"age\" then sort_by((.created | epoch) // 0)
       elif \$sort == \"badge\" then sort_by([(.badge | rank), 0 - ((.updated | epoch) // 0)])
       elif \$sort == \"title\" then sort_by(.title | ascii_downcase)
       elif \$sort == \"key\" then sort_by(.key)
       else . end)
    | .[0:\$limit]
  "
}

# key, ref, badge, state, age in days, updated, labels, title, branch — one row
# per item, and every consumer reads these nine fields whatever the source was.
#
# The separator is the unit separator, not a tab: tab is IFS whitespace, so a
# `read` over tab-separated fields silently collapses an empty one and shifts
# every field after it. An item with no labels is ordinary, so that collapse
# would be an ordinary bug.
HERDR_INGEST_US=$'\x1f'

herdr_ingest_rows() {
  jq -r "
    $HERDR_INGEST_JQ_EPOCH
    .[] | [
      .key,
      (if .ref == \"\" then .key else .ref end),
      (if .badge == \"\" then \"-\" else .badge end),
      (if .state == \"\" then \"-\" else .state end),
      ((.created | epoch) as \$c | if \$c == null then \"?\" else (((now - \$c) / 86400) | floor | tostring) end),
      (.updated | .[0:16]),
      (.labels | join(\",\")),
      (.title | gsub(\"[\t\n\u001f]\"; \" \")),
      .branch
    ] | join(\"\u001f\")"
}

# Split the array into <cache>/items/<key>.json, one file per item, so the
# preview, the hooks and the brief can look an item up by key alone.
herdr_ingest_split_items() {
  local dir="$1" key json
  mkdir -p "$dir"
  while IFS=$'\t' read -r key json; do
    [ -n "$key" ] || continue
    printf '%s\n' "$json" >"$dir/$(herdr_ingest_key_slug "$key").json"
  done < <(jq -r '.[] | "\(.key)\t\(tojson)"')
}

# The fzf preview and a `--render` call both show an item this way.
herdr_ingest_render_item() {
  local item="$1"
  [ -f "$item" ] || { printf 'no such item: %s\n' "$item"; return 0; }
  jq -r '
    def pad: (. + "                ") | .[0:15];
    "\(if .ref == "" then .key else .ref end)  ·  \(if .badge == "" then "-" else .badge end)  ·  \(if .state == "" then "-" else .state end)",
    "",
    .title,
    (if .subtitle == "" then empty else "", .subtitle end),
    "",
    ((.fields // [])[] | "\(.name | pad) \(.value)"),
    (if (.labels | length) > 0 then "\("labels" | pad) \(.labels | join(", "))" else empty end),
    "\("created" | pad) \(if .created == "" then "-" else .created end)",
    "\("updated" | pad) \(if .updated == "" then "-" else .updated end)",
    "\("key" | pad) \(.key)",
    (if .branch == "" then empty else "\("branch" | pad) \(.branch)" end),
    "",
    (if .url == "" then "-" else .url end),
    (if .body == "" then empty else "", "---", "", (.body | .[0:1600]) end)
  ' "$item" 2>/dev/null
}

# --- stage 4: summarise ------------------------------------------------------
# Off, a command, a profile hook, or whatever the source ships. The engine never
# assumes a summary exists: an empty summary file means the brief has no summary
# section, and that is a supported configuration, not a degraded one.

herdr_ingest_resolve_summarise() {
  case "$HERDR_INGEST_SUMMARISE_MODE" in
    off | cmd) return 0 ;;
  esac
  if declare -F ingest_summarise >/dev/null 2>&1; then
    HERDR_INGEST_SUMMARISE_MODE="hook"
  elif declare -F ingest_source_summarise >/dev/null 2>&1; then
    HERDR_INGEST_SUMMARISE_MODE="source"
  else
    HERDR_INGEST_SUMMARISE_MODE="off"
  fi
}

# Write the summary for one item to OUT. A failing summariser costs the item its
# summary, never its space: a brief without extra context still beats no brief.
herdr_ingest_summarise() {
  local item="$1" worktree="$2" out="$3"
  : >"$out"
  case "$HERDR_INGEST_SUMMARISE_MODE" in
    off) return 0 ;;
    cmd)
      HERDR_INGEST_ITEM="$item" HERDR_INGEST_WORKTREE="$worktree" \
      HERDR_INGEST_MAIN_CHECKOUT="$HERDR_INGEST_MAIN" \
      HERDR_INGEST_SOURCE_ID="$HERDR_INGEST_SOURCE_ID" \
        bash -c "$HERDR_INGEST_SUMMARISE_CMD" summarise "$item" "$worktree" \
        <"$item" >"$out" 2>/dev/null || {
        printf 'summariser failed for %s\n' "$(basename -- "$item")" >&2
        : >"$out"
      }
      ;;
    hook)
      ingest_summarise "$item" "$worktree" >"$out" 2>/dev/null || {
        printf 'summarise hook failed for %s\n' "$(basename -- "$item")" >&2
        : >"$out"
      }
      ;;
    source)
      ingest_source_summarise "$item" "$worktree" >"$out" 2>/dev/null || {
        printf 'source summariser failed for %s\n' "$(basename -- "$item")" >&2
        : >"$out"
      }
      ;;
  esac
}

# --- stage 5: prompt ---------------------------------------------------------
# Off, a command, a template, a profile hook, or the built-in brief.

herdr_ingest_resolve_prompt() {
  case "$HERDR_INGEST_PROMPT_MODE" in
    off | cmd | template) return 0 ;;
  esac
  if declare -F ingest_prompt >/dev/null 2>&1; then
    HERDR_INGEST_PROMPT_MODE="hook"
  else
    HERDR_INGEST_PROMPT_MODE="builtin"
  fi
}

# The built-in brief. Everything the agent needs is in this one file: the item,
# its fields, its body, whatever stage 4 produced, and the task.
herdr_ingest_builtin_prompt() {
  local item="$1" summary="$2" out="$3" branch="$4" worktree="$5"
  local ref title subtitle url body

  ref="$(jq -r 'if .ref == "" then .key else .ref end' "$item")"
  title="$(jq -r '.title' "$item")"
  subtitle="$(jq -r '.subtitle' "$item")"
  url="$(jq -r 'if .url == "" then "-" else .url end' "$item")"
  body="$(jq -r '.body' "$item")"

  {
    printf '# %s — %s\n\n' "$ref" "$title"
    [ -n "$subtitle" ] && printf '%s\n\n' "$subtitle"

    printf '| field | value |\n| --- | --- |\n'
    printf '| key | `%s` |\n' "$(jq -r '.key' "$item")"
    jq -r '(.fields // [])[] | "| \(.name) | \(.value) |"' "$item"
    jq -r 'if (.labels | length) > 0 then "| labels | \(.labels | join(", ")) |" else empty end' "$item"
    printf '| source | %s |\n' "$HERDR_INGEST_SOURCE_ID"
    printf '| link | %s |\n' "$url"
    printf '| worktree | `%s` |\n' "$worktree"
    printf '| branch | `%s` |\n\n' "$branch"

    if [ -n "$body" ]; then
      printf '## Detail\n\n%s\n\n' "$body"
    fi

    if [ -s "$summary" ]; then
      printf '## Context\n\n'
      cat "$summary"
      printf '\n\n'
    fi

    printf '## Task\n\n'
    printf 'Work this item in this worktree. You are already on `%s`.\n\n' "$branch"
    if [ -n "$HERDR_INGEST_REPO_SKILL" ] && [ -f "$HERDR_INGEST_REPO_SKILL" ]; then
      printf 'Follow the repository workflow in\n`%s`,\n' "$HERDR_INGEST_REPO_SKILL"
      printf 'starting at its implement step: the fetch and filter steps are already done and\n'
      printf 'this brief is their result. Honour its drop rules — if this item is not\n'
      printf 'actionable here, say so and stop instead of inventing a fix.\n\n'
    else
      printf 'Find the root cause, fix it minimally, and run the repository gates before you\n'
      printf 'show a diff. If the item points at no file you can change, stop and report that\n'
      printf 'instead of guessing.\n\n'
    fi
    printf 'Do not push to main. Do not open a PR without asking.\n'
  } >"$out"
}

# A markdown template with {{placeholder}} slots. The cheapest way to replace
# stage 5 without writing a program.
herdr_ingest_template_prompt() {
  local item="$1" summary="$2" out="$3" branch="$4" worktree="$5"
  local tpl="$HERDR_INGEST_PROMPT_TEMPLATE" body fields summary_text

  body="$(jq -r '.body' "$item")"
  fields="$(jq -r '(.fields // [])[] | "- \(.name): \(.value)"' "$item")"
  summary_text="$([ -s "$summary" ] && cat "$summary" || printf '')"

  # awk substitutes the slots, so a body carrying a `&` or a `\1` survives; sed
  # would eat both. The scan is a single left-to-right pass, so a value that
  # itself contains `{{ref}}` is emitted, never re-read as a slot.
  HERDR_INGEST_T_KEY="$(jq -r '.key' "$item")" \
  HERDR_INGEST_T_REF="$(jq -r 'if .ref == "" then .key else .ref end' "$item")" \
  HERDR_INGEST_T_TITLE="$(jq -r '.title' "$item")" \
  HERDR_INGEST_T_SUBTITLE="$(jq -r '.subtitle' "$item")" \
  HERDR_INGEST_T_URL="$(jq -r '.url' "$item")" \
  HERDR_INGEST_T_BADGE="$(jq -r '.badge' "$item")" \
  HERDR_INGEST_T_STATE="$(jq -r '.state' "$item")" \
  HERDR_INGEST_T_LABELS="$(jq -r '.labels | join(", ")' "$item")" \
  HERDR_INGEST_T_BODY="$body" \
  HERDR_INGEST_T_FIELDS="$fields" \
  HERDR_INGEST_T_SUMMARY="$summary_text" \
  HERDR_INGEST_T_BRANCH="$branch" \
  HERDR_INGEST_T_WORKTREE="$worktree" \
  HERDR_INGEST_T_MAIN="$HERDR_INGEST_MAIN" \
  HERDR_INGEST_T_SOURCE="$HERDR_INGEST_SOURCE_ID" \
  HERDR_INGEST_T_REPO_SKILL="$HERDR_INGEST_REPO_SKILL" \
  HERDR_INGEST_T_ITEM_JSON="$item" \
    awk '
      BEGIN {
        n = split("key ref title subtitle url badge state labels body fields summary branch worktree main source repo_skill item_json", names, " ")
        for (i = 1; i <= n; i++) {
          up = toupper(names[i])
          val[names[i]] = ENVIRON["HERDR_INGEST_T_" up]
        }
      }
      {
        line = $0
        out = ""
        while ((p = index(line, "{{")) > 0) {
          rest = substr(line, p + 2)
          e = index(rest, "}}")
          if (e == 0) break
          name = substr(rest, 1, e - 1)
          if (name in val) {
            out = out substr(line, 1, p - 1) val[name]
            line = substr(rest, e + 2)
          } else {
            # An unknown slot is content, not an error: keep it verbatim.
            out = out substr(line, 1, p + 1)
            line = substr(line, p + 2)
          }
        }
        print out line
      }
    ' "$tpl" >"$out"
}

# Write the brief for one item, or report that this run has no prompt stage.
# Prints the brief path on stdout, or `-` when stage 5 is off or produced
# nothing. `-` is a first-class answer: the pane then offers a bare agent
# session in the worktree instead of a brief.
herdr_ingest_prompt() {
  local item="$1" summary="$2" out="$3" branch="$4" worktree="$5"

  case "$HERDR_INGEST_PROMPT_MODE" in
    off) printf '%s' '-'; return 0 ;;
    builtin) herdr_ingest_builtin_prompt "$item" "$summary" "$out" "$branch" "$worktree" ;;
    template) herdr_ingest_template_prompt "$item" "$summary" "$out" "$branch" "$worktree" ;;
    cmd)
      : >"$out"
      HERDR_INGEST_ITEM="$item" HERDR_INGEST_SUMMARY="$summary" \
      HERDR_INGEST_BRIEF="$out" HERDR_INGEST_BRANCH="$branch" \
      HERDR_INGEST_WORKTREE="$worktree" HERDR_INGEST_MAIN_CHECKOUT="$HERDR_INGEST_MAIN" \
      HERDR_INGEST_SOURCE_ID="$HERDR_INGEST_SOURCE_ID" \
      HERDR_INGEST_REPO_SKILL_PATH="$HERDR_INGEST_REPO_SKILL" \
        bash -c "$HERDR_INGEST_PROMPT_CMD" prompt "$item" "$summary" "$out" "$branch" "$worktree" \
        >/dev/null 2>&1 || printf 'prompt command failed for %s\n' "$(basename -- "$item")" >&2
      ;;
    hook)
      : >"$out"
      ingest_prompt "$item" "$summary" "$out" "$branch" "$worktree" >/dev/null 2>&1 \
        || printf 'prompt hook failed for %s\n' "$(basename -- "$item")" >&2
      ;;
  esac

  if [ -s "$out" ]; then printf '%s' "$out"; else printf '%s' '-'; fi
}

# --- stage 6: emission -------------------------------------------------------

# Write the zellij layout for one item's worktree.
herdr_ingest_emit_layout() {
  local label="$1" cwd="$2" brief="$3" ref="$4" title="$5" out="$6" lazy
  lazy="${HERDR_INGEST_LAZY:-$HERDR_INGEST_HOME/lazy-brief}"

  {
    printf 'layout {\n'
    printf '    cwd "%s"\n' "$(herdr_ingest_kdl_escape "$cwd")"
    printf '    default_tab_template {\n'
    printf '        pane size=1 borderless=true { plugin location="tab-bar"; }\n'
    printf '        children\n'
    printf '        pane size=1 borderless=true { plugin location="status-bar"; }\n'
    printf '    }\n'
    printf '    tab name="%s" {\n' "$(herdr_ingest_kdl_escape "$(herdr_ingest_sanitize "$label")")"
    printf '        pane split_direction="vertical" {\n'

    # left column: terminal on top and focused, nvim collapsed under it
    printf '            pane stacked=true {\n'
    printf '                pane name="shell" focus=true\n'
    printf '                pane name="nvim" command="nvim" { args "."; }\n'
    printf '            }\n'

    # right column: the brief, waiting for `y`. One pane, because one space
    # works one item.
    printf '            pane stacked=true {\n'
    printf '                pane name="%s" command="%s" { args "%s" "%s" "%s"; }\n' \
      "$(herdr_ingest_kdl_escape "$(herdr_ingest_sanitize "$ref")")" \
      "$(herdr_ingest_kdl_escape "$lazy")" \
      "$(herdr_ingest_kdl_escape "$brief")" \
      "$(herdr_ingest_kdl_escape "$ref")" \
      "$(herdr_ingest_kdl_escape "$title")"
    printf '            }\n'

    printf '        }\n'
    printf '    }\n'
    printf '}\n'
  } >"$out"
}

# Write an executable attach-or-create script for SESSION to OUT.
herdr_ingest_emit_boot() {
  local session="$1" layout="$2" out="$3"
  cat >"$out" <<EOF
#!/usr/bin/env bash
# Attach to the existing (or resurrectable) session, else create it from layout.
exec 2>&1
if zellij attach "$session"; then :; else
  zellij --session "$session" --new-session-with-layout "$layout" || true
fi
exec "\${SHELL:-/bin/zsh}" -l
EOF
  chmod +x "$out"
}

# --- the farm ----------------------------------------------------------------

# The space sitting in CWD, if any. Spaces are matched by cwd, not label, so a
# space you renamed yourself is still reused.
herdr_ingest_ws_for_cwd() {
  local cwd="$1" phys
  phys="$(cd -- "$cwd" 2>/dev/null && pwd -P)" || phys="$cwd"
  herdr pane list 2>/dev/null \
    | jq -r --arg a "$cwd" --arg b "$phys" \
      'first(.result.panes[]? | select(.cwd == $a or .cwd == $b) | .workspace_id) // ""'
}

# Is somebody already on this item? Three conventions count as yes: the branch
# the source itself named, this tool's own `<prefix>-<key>` form, and — only for
# a key that reads like a tracker identifier — that identifier anywhere in a
# branch name, which is what a branch cut from the tracker's own UI looks like.
herdr_ingest_branch_exists() {
  local main="$1" keyslug="$2" own="$3" refs ref ident=0
  [[ "$keyslug" =~ ^[a-z][a-z0-9]*-[0-9]+$ ]] && ident=1
  # Read the refs first: `git … | grep -q` dies of SIGPIPE under pipefail, and a
  # false "no branch" answer would spawn a space over somebody's open work.
  refs="$(git -C "$main" for-each-ref --format='%(refname:short)' \
    'refs/heads/**' 'refs/remotes/**' 2>/dev/null)" || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ -n "$own" ] && { [ "$ref" = "$own" ] || [ "$ref" = "origin/$own" ]; }; then return 0; fi
    case "$ref" in
      *"$HERDR_INGEST_PREFIX-$keyslug" | *"$HERDR_INGEST_PREFIX-$keyslug-"*) return 0 ;;
    esac
    if [ "$ident" = 1 ]; then
      case "$ref" in
        *"$keyslug" | *"$keyslug-"*) return 0 ;;
      esac
    fi
  done <<<"$refs"
  return 1
}

# The one item -> one worktree -> one space step. Prints a status line.
#
# It takes the key alone and reads the rest out of the item file, so the display
# rows stay a display concern and exactly one representation of an item reaches
# stages 4, 5 and 6.
herdr_ingest_spawn() {
  local key="$1"
  local keyslug item summary brief layout boot zsession path slug ws pane out rel
  local ref title url branch

  keyslug="$(herdr_ingest_key_slug "$key")"
  item="$HERDR_INGEST_ITEM_DIR/$keyslug.json"
  [ -f "$item" ] || { printf '  %-20s no item file for key %s\n' "$key" "$key"; return 1; }

  IFS=$HERDR_INGEST_US read -r ref title url branch < <(jq -r '
    def line: gsub("[\n\r\u001f]"; " ");
    [(if .ref == "" then .key else .ref end | line), (.title | line), .url, .branch]
    | join("\u001f")' "$item")

  slug="$(herdr_ingest_slug "${title:-$ref}")"
  path="$HERDR_INGEST_ROOT/$(herdr_ingest_render_name \
    "$HERDR_INGEST_WORKTREE_TEMPLATE" "$HERDR_INGEST_PREFIX" "$keyslug" "$ref" "$slug")"
  if [ -z "$branch" ]; then
    branch="$(herdr_ingest_render_name \
      "$HERDR_INGEST_BRANCH_TEMPLATE" "$HERDR_INGEST_PREFIX" "$keyslug" "$ref" "$slug")"
  fi
  zsession="$HERDR_INGEST_ROOT_NAME-$HERDR_INGEST_PREFIX-$keyslug"
  layout="$HERDR_INGEST_CACHE_DIR/$HERDR_INGEST_PREFIX-$keyslug.kdl"
  boot="$HERDR_INGEST_CACHE_DIR/$HERDR_INGEST_PREFIX-$keyslug.boot.sh"
  summary="$HERDR_INGEST_SUMMARY_DIR/$keyslug.md"
  brief="$HERDR_INGEST_BRIEF_DIR/$keyslug.md"
  rel="${path#"$HERDR_INGEST_ROOT"/}"

  # An existing worktree keeps its own branch: never re-cut a checkout somebody
  # may have work in.
  if [ -e "$path" ]; then
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s' "$branch")"
  fi

  herdr_ingest_summarise "$item" "$path" "$summary"
  brief="$(herdr_ingest_prompt "$item" "$summary" "$brief" "$branch" "$path")"

  herdr_ingest_emit_layout "$ref" "$path" "$brief" "$ref" "$title" "$layout"
  herdr_ingest_emit_boot "$zsession" "$layout" "$boot"

  if [ "$HERDR_INGEST_DRY" = 1 ]; then
    printf '  %-20s %-34s would spawn -> %s\n' "$ref" "$rel" "$branch"
    return 0
  fi

  ws="$(herdr_ingest_ws_for_cwd "$path")"
  if [ -n "$ws" ]; then
    printf '  %-20s %-34s %-4s space exists, reused\n' "$ref" "$rel" "$ws"
    : >"$HERDR_INGEST_STATE_DIR/$keyslug"
    if [ -z "$HERDR_INGEST_FIRST_WS" ]; then HERDR_INGEST_FIRST_WS="$ws"; fi
    return 0
  fi

  # herdr cuts the worktree and opens its space in one call. An existing
  # checkout is opened instead, so a farm somebody else populated still works.
  if [ -e "$path" ]; then
    out="$(herdr worktree open --cwd "$HERDR_INGEST_MAIN" --path "$path" \
      --label "$ref" --no-focus 2>&1)" || {
      printf '  %-20s %-34s open failed: %s\n' "$ref" "$rel" \
        "$(printf '%s' "$out" | jq -r '.error.message // .' 2>/dev/null | tr '\n' ' ' | cut -c1-90)"
      return 1
    }
  else
    out="$(herdr worktree create --cwd "$HERDR_INGEST_MAIN" --branch "$branch" \
      --base "$HERDR_INGEST_BASE" --path "$path" --label "$ref" --no-focus 2>&1)" || {
      printf '  %-20s %-34s create failed: %s\n' "$ref" "$rel" \
        "$(printf '%s' "$out" | jq -r '.error.message // .' 2>/dev/null | tr '\n' ' ' | cut -c1-90)"
      return 1
    }
  fi

  ws="$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // ""')"
  pane="$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // ""')"
  if [ -z "$pane" ]; then
    printf '  %-20s %-34s no pane in herdr reply\n' "$ref" "$rel"
    return 1
  fi

  herdr pane rename "$pane" "zellij" >/dev/null 2>&1 || true
  herdr pane run "$pane" "exec $boot" >/dev/null
  : >"$HERDR_INGEST_STATE_DIR/$keyslug"
  if [ -z "$HERDR_INGEST_FIRST_WS" ]; then HERDR_INGEST_FIRST_WS="$ws"; fi
  printf '  %-20s %-34s %-4s space created on %s\n' "$ref" "$rel" "$ws" "$branch"
  [ -n "$url" ] && printf '  %-20s %-34s      %s\n' "" "" "$url"
  return 0
}

# fzf over the rows, in the order stage 3 left them, with the full item in the
# preview. Prints the selected keys, one per line.
herdr_ingest_pick() {
  local rows="$1" key ref badge state age updated labels title branch
  local mark keyslug display
  local -a menu=()

  while IFS=$HERDR_INGEST_US read -r key ref badge state age updated labels title branch; do
    [ -n "$key" ] || continue
    keyslug="$(herdr_ingest_key_slug "$key")"
    mark="  "
    if [ -e "$HERDR_INGEST_STATE_DIR/$keyslug" ]; then mark="✓ "; fi
    if herdr_ingest_branch_exists "$HERDR_INGEST_MAIN" "$keyslug" "$branch"; then mark="⎇ "; fi
    display="$(printf '%s%-18s %-9s %-12s %5sd  %-16s %s' \
      "$mark" "${ref:0:18}" "${badge:0:9}" "${state:0:12}" "$age" "$updated" "$title")"
    menu+=("$key"$'\t'"$display")
  done <"$rows"

  if [ "${#menu[@]}" -eq 0 ]; then return 0; fi

  printf '%s\n' "${menu[@]}" | fzf \
    --multi \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --layout=reverse \
    --border \
    --info=inline \
    --prompt="$HERDR_INGEST_SOURCE_ID > " \
    --header=$'tab marks an item · enter spawns a space per marked item · ✓ already spawned · ⎇ branch exists\n' \
    --preview="$HERDR_INGEST_SELF --render $HERDR_INGEST_ITEM_DIR {1}" \
    --preview-window='right,55%,wrap' \
    | cut -f1
}

# One pass: fetch, normalise, filter, select, spawn.
herdr_ingest_sweep() {
  local raw items rows selected=() n=0 total=0 held=0 keyslug
  local key ref badge state age updated labels title branch

  raw="$HERDR_INGEST_CACHE_DIR/raw.json"
  items="$HERDR_INGEST_CACHE_DIR/items.json"
  rows="$HERDR_INGEST_CACHE_DIR/items.rows"

  if [ -n "$HERDR_INGEST_ITEMS_FILE" ]; then
    ingest_source_normalize <"$HERDR_INGEST_ITEMS_FILE" \
      | herdr_ingest_canonicalize >"$raw" || {
      printf 'cannot read items from %s\n' "$HERDR_INGEST_ITEMS_FILE" >&2
      return 1
    }
  else
    ingest_source_fetch | ingest_source_normalize | herdr_ingest_canonicalize >"$raw" || return 1
  fi

  if [ ! -s "$raw" ]; then
    printf 'no items payload returned\n' >&2
    return 1
  fi
  total="$(jq 'length' <"$raw")"

  herdr_ingest_filter "$HERDR_INGEST_BADGES" "$HERDR_INGEST_STATES" \
    "$HERDR_INGEST_LABELS" "$HERDR_INGEST_MATCH" "$HERDR_INGEST_UPDATED_LAST" \
    "$HERDR_INGEST_CREATED_LAST" "$HERDR_INGEST_SORT" "$HERDR_INGEST_LIMIT" \
    "$HERDR_INGEST_BADGE_ORDER" <"$raw" >"$items"

  herdr_ingest_split_items "$HERDR_INGEST_ITEM_DIR" <"$items"
  herdr_ingest_rows <"$items" >"$rows"
  n="$(wc -l <"$rows" | tr -d ' ')"

  printf '%s · %s of %s item(s) kept · summarise %s · prompt %s\n' \
    "$HERDR_INGEST_SOURCE_LABEL" "$n" "$total" \
    "$HERDR_INGEST_SUMMARISE_MODE" "$HERDR_INGEST_PROMPT_MODE"

  if [ "$n" -eq 0 ]; then return 0; fi

  if [ "$HERDR_INGEST_AUTO" = 1 ]; then
    # Auto mode never spawns over somebody else's work: an item already spawned
    # here, or already carrying a branch, is skipped.
    while IFS=$HERDR_INGEST_US read -r key ref badge state age updated labels title branch; do
      [ -n "$key" ] || continue
      keyslug="$(herdr_ingest_key_slug "$key")"
      if [ "$HERDR_INGEST_RESPAWN" = 0 ] && [ -e "$HERDR_INGEST_STATE_DIR/$keyslug" ]; then
        printf '  %-20s skipped, already spawned here\n' "$ref"
        continue
      fi
      if [ "$HERDR_INGEST_RESPAWN" = 0 ] \
        && herdr_ingest_branch_exists "$HERDR_INGEST_MAIN" "$keyslug" "$branch"; then
        printf '  %-20s skipped, branch exists\n' "$ref"
        continue
      fi
      if [ "${#selected[@]}" -ge "$HERDR_INGEST_MAX_SPACES" ]; then
        held=$((held + 1))
        continue
      fi
      selected+=("$key")
    done <"$rows"
  else
    command -v fzf >/dev/null || { echo "fzf not found: interactive mode needs it (or pass --auto)" >&2; return 1; }
    while IFS= read -r key; do
      if [ -n "$key" ]; then selected+=("$key"); fi
    done < <(herdr_ingest_pick "$rows")
    if [ "${#selected[@]}" -eq 0 ]; then
      printf 'nothing selected\n'
      return 0
    fi
  fi

  if [ "${#selected[@]}" -eq 0 ]; then
    printf '  nothing new to spawn\n'
    return 0
  fi

  for key in "${selected[@]}"; do
    herdr_ingest_spawn "$key" || true
  done

  # The rest stay in the source, so the next sweep picks them up; --max-spaces
  # is a rate limit, not a filter.
  if [ "$held" -gt 0 ]; then
    printf '  %s more item(s) held back by --max-spaces %s\n' "$held" "$HERDR_INGEST_MAX_SPACES"
  fi
}

# --- sources -----------------------------------------------------------------

herdr_ingest_source_ids() {
  local f
  for f in "$HERDR_INGEST_SOURCE_DIR"/*.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$(basename -- "$f" .sh)"
  done
}

herdr_ingest_source_path() {
  local spec="$1"
  case "$spec" in
    */* | *.sh)
      if [ -f "$spec" ]; then printf '%s' "$spec"; return 0; fi
      printf 'no such source file: %s\n' "$spec" >&2
      return 1 ;;
  esac
  if [ -f "$HERDR_INGEST_SOURCE_DIR/$spec.sh" ]; then
    printf '%s' "$HERDR_INGEST_SOURCE_DIR/$spec.sh"
    return 0
  fi
  printf 'unknown source: %s (built-in: %s)\n' "$spec" \
    "$(herdr_ingest_source_ids | paste -sd, - 2>/dev/null || herdr_ingest_source_ids | tr '\n' ',')" >&2
  return 1
}

# A source is one sourced file defining ingest_source_*. Loading one replaces
# any previously loaded one, so exactly one source is live per run.
herdr_ingest_load_source() {
  local file missing=()
  file="$(herdr_ingest_source_path "$1")" || return 1
  unset -f ingest_source_describe ingest_source_usage ingest_source_option \
    ingest_source_check ingest_source_fetch ingest_source_normalize \
    ingest_source_summarise 2>/dev/null || true
  # shellcheck disable=SC1090
  . "$file" || { printf 'cannot load source: %s\n' "$file" >&2; return 1; }
  local fn
  for fn in ingest_source_describe ingest_source_fetch ingest_source_normalize; do
    declare -F "$fn" >/dev/null 2>&1 || missing+=("$fn")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'source %s defines no %s\n' "$file" "${missing[*]}" >&2
    return 1
  fi
  HERDR_INGEST_SOURCE_FILE="$file"
  return 0
}

herdr_ingest_sources_table() {
  local id file
  printf '%-10s %-28s %s\n' "id" "prefix" "what it ingests"
  while IFS= read -r id; do
    file="$HERDR_INGEST_SOURCE_DIR/$id.sh"
    (
      # A subshell per source, so one source's variables never leak into the
      # next one's description.
      # shellcheck disable=SC1090
      . "$file" >/dev/null 2>&1 || exit 0
      printf '%-10s %-28s %s\n' "$id" \
        "${HERDR_INGEST_SOURCE_PREFIX:-$id}" \
        "$(ingest_source_describe 2>/dev/null | sed -n 's/^summary\t//p')"
    )
  done < <(herdr_ingest_source_ids)
}

# --- usage -------------------------------------------------------------------

herdr_ingest_usage() {
  cat <<EOF
herdr-ingest — one herdr space per work item, from any ingestion source

usage:
  herdr-ingest [--source ID|FILE] [--profile FILE]
               [--root PATH] [--main PATH] [--base REF]
               [--worktree-template TPL] [--branch-template TPL] [--prefix STR]
               [--items-json FILE]
               [--badge CSV] [--state CSV] [--label CSV] [--match REGEX]
               [--updated-last WINDOW] [--created-last WINDOW]
               [--badge-order CSV] [--sort KEY] [--limit N]
               [--summarise CMD | --no-summarise]
               [--prompt CMD | --prompt-template FILE | --no-prompt]
               [--agent CMD]
               [--auto [--max-spaces N] [--watch] [--interval SECONDS]]
               [--respawn] [--no-focus] [--dry-run] [--pane]
               [source flags]
  herdr-ingest sources
  herdr-ingest --help | -h
  herdr-ingest --version | -V

pipeline:
  1 fetch      the source pulls a raw payload
  2 normalise  the payload becomes canonical items
  3 select     filter, sort, cap, then auto or fzf pick
  4 summarise  --summarise CMD, a profile hook, the source's own, or --no-summarise
  5 prompt     --prompt CMD, --prompt-template FILE, a profile hook, the
               built-in brief, or --no-prompt
  6 spawn      worktree + herdr space + a pane that waits for \`y\`

source:
  --source ID|FILE     ingestion source (default: $HERDR_INGEST_DEFAULT_SOURCE); \`sources\` lists them
  --profile FILE       bash file sourced before the flags: set any HERDR_INGEST_*
                       default, and define ingest_summarise / ingest_prompt to
                       replace stage 4 or stage 5

farm:
  --root PATH          worktree farm to spawn into (default: \$HOME/farm)
  --main PATH          checkout new worktrees are cut from (default: <root>/main)
  --base REF           base for a new branch (default: origin/main, else HEAD)
  --prefix STR         worktree and branch namespace (default: the source's own)
  --worktree-template TPL  worktree name under the root (default: {prefix}-{key})
  --branch-template TPL    branch for a new worktree (default: fix/{prefix}-{key}-{slug})
                       both take {prefix} {key} {ref} {slug}

select:
  --items-json FILE    read the source's payload from FILE instead of fetching
  --badge CSV          keep only these badges, e.g. error,fatal or urgent,high
  --state CSV          keep only these states
  --label CSV          keep items carrying any of these labels
  --match REGEX        keep items whose title or subtitle matches, case-insensitive
  --updated-last WINDOW  keep items updated within 5m, 2h, 2d, 1w
  --created-last WINDOW  keep items created within that window
  --badge-order CSV    rank badges for --sort badge, most severe first; the
                       source supplies its own, a generic payload needs this
  --sort KEY           updated, created, age, badge, title, key or none
  --limit N            items to keep (default: $HERDR_INGEST_DEFAULT_LIMIT)

stages 4 and 5:
  --summarise CMD      run CMD per item: \$1 item json, \$2 worktree, stdin the
                       item; stdout becomes the brief's Context section
  --no-summarise       skip stage 4
  --prompt CMD         run CMD per item: \$1 item json, \$2 summary, \$3 brief to
                       write, \$4 branch, \$5 worktree
  --prompt-template FILE  render FILE, substituting {{key}} {{ref}} {{title}}
                       {{subtitle}} {{url}} {{badge}} {{state}} {{labels}}
                       {{body}} {{fields}} {{summary}} {{branch}} {{worktree}}
                       {{main}} {{source}} {{repo_skill}} {{item_json}}
  --no-prompt          skip stage 5: the pane shows the item and offers a bare
                       agent session in the worktree instead of a brief

spawn:
  --agent CMD          agent the pane offers to run (default: $HERDR_INGEST_DEFAULT_AGENT)
  --auto               spawn without asking; default is an fzf picker
  --max-spaces N       spaces one auto sweep may spawn (default: $HERDR_INGEST_DEFAULT_MAX_SPACES)
  --watch              keep sweeping instead of exiting after one sweep
  --interval SECONDS   delay between watch sweeps (default: $HERDR_INGEST_DEFAULT_INTERVAL)
  --respawn            spawn again for items already spawned or already branched
  --no-focus           create the spaces but leave focus where it is
  --dry-run            write items, summaries, briefs and layouts only; create no spaces
  --pane               hold the terminal open at the end, so a herdr popup pane
                       stays readable instead of closing on exit
  -h, --help           print this help and exit
  -V, --version        print the version and exit

environment, and what a profile may set:
  HERDR_INGEST_CACHE       override the cache directory
  HERDR_INGEST_LAZY        override the lazy-brief pane binary
  HERDR_INGEST_PROFILE     default for --profile
  HERDR_INGEST_SOURCE      default for --source
  HERDR_INGEST_ROOT        default for --root
  HERDR_INGEST_MAIN        default for --main
  HERDR_INGEST_BASE        default for --base
  HERDR_INGEST_PREFIX      default for --prefix
  HERDR_INGEST_AGENT       default for --agent
  HERDR_INGEST_MAX_SPACES  default for --max-spaces

A profile may also set any other HERDR_INGEST_* variable this help names, and
define ingest_summarise or ingest_prompt. A flag always beats a profile.

The pane never starts an agent by itself: it prints the brief and waits for an
explicit \`y\`. Interactive mode needs fzf. --updated-last, --created-last,
--interval, --limit and --max-spaces must be positive. A dry run needs neither
herdr nor zellij.
EOF
  if declare -F ingest_source_usage >/dev/null 2>&1; then
    printf '\n'
    ingest_source_usage
  else
    printf '\nPass --source ID --help to see a source'"'"'s own flags.\n'
  fi
}

# --- main --------------------------------------------------------------------

herdr_ingest_main() {
  set -euo pipefail

  # --- worker mode: render one item for the fzf preview ---------------------
  if [ "${1:-}" = "--render" ]; then
    herdr_ingest_render_item "${2:-}/$(herdr_ingest_key_slug "${3:-}").json"
    return 0
  fi

  local root="" main="" base="" prefix=""
  local watch=0 interval="$HERDR_INGEST_DEFAULT_INTERVAL"
  local source_flag="" profile_flag=""
  local source_spec profile
  local badges="" states="" labels="" badge_order=""
  local resolved sweep_rc help=0 version=0

  # --source and --profile come out of the argv first, because both decide what
  # the rest of the parse even means: the profile supplies defaults, and the
  # source appends flags of its own.
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --source) source_flag="${2:-}"; shift 2 ;;
      --profile) profile_flag="${2:-}"; shift 2 ;;
      --pane) trap herdr_ingest_pane_hold EXIT; shift ;;
      sources) HERDR_INGEST_LIST_SOURCES=1; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"}

  if [ "${HERDR_INGEST_LIST_SOURCES:-0}" = 1 ]; then
    herdr_ingest_sources_table
    return 0
  fi

  # Layer 1: the engine's own defaults. Every knob below is seeded, never
  # assigned, so the profile, the source and the flags can each still decide it.
  herdr_ingest_seed HERDR_INGEST_WORKTREE_TEMPLATE '{prefix}-{key}'
  herdr_ingest_seed HERDR_INGEST_BRANCH_TEMPLATE 'fix/{prefix}-{key}-{slug}'
  herdr_ingest_seed HERDR_INGEST_LIMIT "$HERDR_INGEST_DEFAULT_LIMIT"
  herdr_ingest_seed HERDR_INGEST_MAX_SPACES "$HERDR_INGEST_DEFAULT_MAX_SPACES"
  herdr_ingest_seed HERDR_INGEST_AGENT "$HERDR_INGEST_DEFAULT_AGENT"
  herdr_ingest_seed HERDR_INGEST_UPDATED_LAST -1
  herdr_ingest_seed HERDR_INGEST_CREATED_LAST -1
  herdr_ingest_seed HERDR_INGEST_AUTO 0
  herdr_ingest_seed HERDR_INGEST_DRY 0
  herdr_ingest_seed HERDR_INGEST_RESPAWN 0
  herdr_ingest_seed HERDR_INGEST_FOCUS 1
  : "${HERDR_INGEST_MATCH:=}"
  : "${HERDR_INGEST_ITEMS_FILE:=}"
  : "${HERDR_INGEST_SUMMARISE_MODE:=}"
  : "${HERDR_INGEST_SUMMARISE_CMD:=}"
  : "${HERDR_INGEST_PROMPT_MODE:=}"
  : "${HERDR_INGEST_PROMPT_CMD:=}"
  : "${HERDR_INGEST_PROMPT_TEMPLATE:=}"
  HERDR_INGEST_FIRST_WS=""

  # Layer 2: the profile. It runs before the source is loaded, so it may choose
  # the source itself as well as any HERDR_INGEST_* knob and either hook.
  profile="${profile_flag:-${HERDR_INGEST_PROFILE:-}}"
  if [ -n "$profile" ]; then
    [ -f "$profile" ] || { printf 'no such profile: %s\n' "$profile" >&2; exit 2; }
    # shellcheck disable=SC1090
    . "$profile" || { printf 'cannot load profile: %s\n' "$profile" >&2; exit 2; }
  fi

  # Layer 3: the source. Its own file owns its id, its prefix and its badge
  # ranking; its option defaults read HERDR_INGEST_<SOURCE>_* so a profile can
  # set those too.
  source_spec="${source_flag:-${HERDR_INGEST_SOURCE:-$HERDR_INGEST_DEFAULT_SOURCE}}"
  herdr_ingest_load_source "$source_spec" || exit 2
  HERDR_INGEST_SOURCE_ID="${HERDR_INGEST_SOURCE_ID:-$(basename -- "$HERDR_INGEST_SOURCE_FILE" .sh)}"
  HERDR_INGEST_SOURCE_LABEL="$HERDR_INGEST_SOURCE_ID"
  HERDR_INGEST_BADGE_ORDER="${HERDR_INGEST_SOURCE_BADGE_ORDER:-[]}"
  herdr_ingest_seed HERDR_INGEST_PREFIX "${HERDR_INGEST_SOURCE_PREFIX:-$HERDR_INGEST_SOURCE_ID}"
  herdr_ingest_seed HERDR_INGEST_SORT "${HERDR_INGEST_SOURCE_SORT:-updated}"

  # Layer 4: the flags. The farm's four inputs read the same variables the
  # resolution below writes back, so a profile can set them and a flag can win.
  root="${HERDR_INGEST_ROOT:-$HERDR_INGEST_DEFAULT_ROOT}"
  main="${HERDR_INGEST_MAIN:-}"
  base="${HERDR_INGEST_BASE:-}"
  prefix="$HERDR_INGEST_PREFIX"

  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root="${2:-}"; shift 2 ;;
      --main) main="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --prefix) prefix="${2:-}"; shift 2 ;;
      --worktree-template) HERDR_INGEST_WORKTREE_TEMPLATE="${2:-}"; shift 2 ;;
      --branch-template) HERDR_INGEST_BRANCH_TEMPLATE="${2:-}"; shift 2 ;;
      --items-json) HERDR_INGEST_ITEMS_FILE="${2:-}"; shift 2 ;;
      --badge) badges="${2:-}"; shift 2 ;;
      --badge-order) badge_order="${2:-}"; shift 2 ;;
      --state) states="${2:-}"; shift 2 ;;
      --label) labels="${2:-}"; shift 2 ;;
      --match) HERDR_INGEST_MATCH="${2:-}"; shift 2 ;;
      --updated-last)
        HERDR_INGEST_UPDATED_LAST="$(herdr_ingest_window_seconds "${2:-}")" || exit 2
        shift 2 ;;
      --created-last)
        HERDR_INGEST_CREATED_LAST="$(herdr_ingest_window_seconds "${2:-}")" || exit 2
        shift 2 ;;
      --sort)
        case "${2:-}" in
          updated | created | age | badge | title | key | none) HERDR_INGEST_SORT="$2" ;;
          *) printf 'invalid value for --sort: %s (expected updated, created, age, badge, title, key or none)\n' "${2:-}" >&2; exit 2 ;;
        esac
        shift 2 ;;
      --limit)
        herdr_ingest_positive_int --limit "${2:-}" || exit 2
        HERDR_INGEST_LIMIT="$2"; shift 2 ;;
      --summarise | --summarize)
        HERDR_INGEST_SUMMARISE_MODE="cmd"; HERDR_INGEST_SUMMARISE_CMD="${2:-}"; shift 2 ;;
      --no-summarise | --no-summarize)
        HERDR_INGEST_SUMMARISE_MODE="off"; shift ;;
      --prompt)
        HERDR_INGEST_PROMPT_MODE="cmd"; HERDR_INGEST_PROMPT_CMD="${2:-}"; shift 2 ;;
      --prompt-template)
        [ -f "${2:-}" ] || { printf 'no such prompt template: %s\n' "${2:-}" >&2; exit 2; }
        HERDR_INGEST_PROMPT_MODE="template"; HERDR_INGEST_PROMPT_TEMPLATE="$2"; shift 2 ;;
      --no-prompt) HERDR_INGEST_PROMPT_MODE="off"; shift ;;
      --agent) HERDR_INGEST_AGENT="${2:-}"; shift 2 ;;
      --auto) HERDR_INGEST_AUTO=1; shift ;;
      --max-spaces)
        herdr_ingest_positive_int --max-spaces "${2:-}" || exit 2
        HERDR_INGEST_MAX_SPACES="$2"; shift 2 ;;
      --watch) watch=1; shift ;;
      --interval)
        herdr_ingest_positive_int --interval "${2:-}" || exit 2
        interval="$2"; shift 2 ;;
      --respawn) HERDR_INGEST_RESPAWN=1; shift ;;
      --no-focus) HERDR_INGEST_FOCUS=0; shift ;;
      --dry-run) HERDR_INGEST_DRY=1; shift ;;
      -h | --help) help=1; shift ;;
      -V | --version) version=1; shift ;;
      *)
        # Anything the engine does not know is offered to the source. The source
        # runs in this shell — not a command substitution — so the option it
        # parses actually sticks; it reports its argument count in
        # HERDR_INGEST_OPT_SHIFT and returns non-zero for a flag it does not own.
        HERDR_INGEST_OPT_SHIFT=0
        if declare -F ingest_source_option >/dev/null 2>&1; then
          ingest_source_option "$@" || HERDR_INGEST_OPT_SHIFT=0
        fi
        if [ "$HERDR_INGEST_OPT_SHIFT" -gt 0 ] 2>/dev/null; then
          shift "$HERDR_INGEST_OPT_SHIFT"
        else
          printf 'unknown flag: %s\n' "$1" >&2
          exit 2
        fi
        ;;
    esac
  done

  if [ "$version" = 1 ]; then herdr_ingest_version; return 0; fi
  if [ "$help" = 1 ]; then herdr_ingest_usage; return 0; fi

  [ -n "$prefix" ] && HERDR_INGEST_PREFIX="$prefix"
  HERDR_INGEST_BADGES="$(herdr_ingest_csv_json "$badges")"
  # A flag beats the source's own ranking. The source ships the ranking it knows
  # (sentry: fatal > error > warning), but a generic payload carries whatever
  # words its tracker uses, so --sort badge is inert until someone names them.
  [ -n "$badge_order" ] && HERDR_INGEST_BADGE_ORDER="$(herdr_ingest_csv_json "$badge_order")"
  HERDR_INGEST_STATES="$(herdr_ingest_csv_json "$states")"
  HERDR_INGEST_LABELS="$(herdr_ingest_csv_json "$labels")"

  herdr_ingest_resolve_summarise
  herdr_ingest_resolve_prompt

  if [ "$watch" = 1 ] && [ "$HERDR_INGEST_AUTO" = 0 ]; then
    echo "--watch needs --auto: an unattended sweep cannot answer a picker" >&2
    exit 2
  fi

  # --- the farm --------------------------------------------------------------
  resolved="$(cd -- "$root" 2>/dev/null && pwd)" || { echo "no such root: $root" >&2; exit 1; }
  HERDR_INGEST_ROOT="$resolved"
  if [ -z "$main" ]; then main="$HERDR_INGEST_ROOT/main"; fi
  resolved="$(cd -- "$main" 2>/dev/null && pwd)" || { echo "no such main checkout: $main" >&2; exit 1; }
  HERDR_INGEST_MAIN="$resolved"
  [ -e "$HERDR_INGEST_MAIN/.git" ] || { echo "not a checkout: $HERDR_INGEST_MAIN" >&2; exit 1; }

  HERDR_INGEST_ROOT_NAME="$(herdr_ingest_root_name "$HERDR_INGEST_ROOT")"
  HERDR_INGEST_CACHE_DIR="$(herdr_ingest_cache_dir "$HERDR_INGEST_ROOT_NAME")/$HERDR_INGEST_SOURCE_ID"
  HERDR_INGEST_ITEM_DIR="$HERDR_INGEST_CACHE_DIR/items"
  HERDR_INGEST_SUMMARY_DIR="$HERDR_INGEST_CACHE_DIR/summaries"
  HERDR_INGEST_BRIEF_DIR="$HERDR_INGEST_CACHE_DIR/briefs"
  HERDR_INGEST_STATE_DIR="$HERDR_INGEST_CACHE_DIR/spawned"
  mkdir -p "$HERDR_INGEST_ITEM_DIR" "$HERDR_INGEST_SUMMARY_DIR" \
    "$HERDR_INGEST_BRIEF_DIR" "$HERDR_INGEST_STATE_DIR"

  # New branches are cut from the shared base, not from whatever main has
  # checked out locally.
  if [ -z "$base" ]; then
    if git -C "$HERDR_INGEST_MAIN" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      base="origin/main"
    else
      base="HEAD"
    fi
  fi
  HERDR_INGEST_BASE="$base"

  # The repo's own workflow, when the checkout ships one. The built-in brief
  # points the agent at it instead of inventing a process.
  HERDR_INGEST_REPO_SKILL="${HERDR_INGEST_REPO_SKILL:-}"
  if [ -z "$HERDR_INGEST_REPO_SKILL" ]; then
    local candidate
    for candidate in \
      ".claude/skills/$HERDR_INGEST_SOURCE_ID-triage-fix/SKILL.md" \
      "AGENTS.md"; do
      if [ -f "$HERDR_INGEST_MAIN/$candidate" ]; then
        HERDR_INGEST_REPO_SKILL="$HERDR_INGEST_MAIN/$candidate"
        break
      fi
    done
  fi

  command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
  if [ -z "$HERDR_INGEST_ITEMS_FILE" ]; then
    if declare -F ingest_source_check >/dev/null 2>&1; then
      ingest_source_check || exit 1
    fi
  fi

  # A dry run only writes cache files, so it needs neither herdr nor zellij.
  if [ "$HERDR_INGEST_DRY" = 0 ]; then
    command -v zellij >/dev/null || { echo "zellij not found" >&2; exit 1; }
    command -v herdr >/dev/null || { echo "herdr not found" >&2; exit 1; }
    [ -x "${HERDR_INGEST_LAZY:-$HERDR_INGEST_HOME/lazy-brief}" ] \
      || { echo "not executable: ${HERDR_INGEST_LAZY:-$HERDR_INGEST_HOME/lazy-brief}" >&2; exit 1; }
  fi

  export HERDR_INGEST_AGENT

  while :; do
    sweep_rc=0
    herdr_ingest_sweep || sweep_rc=$?

    # Spaces are created unfocused so a sweep never yanks you mid-task. Focus
    # the first new one at the end, and never during a watch.
    if [ "$HERDR_INGEST_DRY" = 0 ] && [ -n "$HERDR_INGEST_FIRST_WS" ] \
      && [ "$HERDR_INGEST_FOCUS" = 1 ] && [ "$watch" = 0 ]; then
      herdr workspace focus "$HERDR_INGEST_FIRST_WS" >/dev/null 2>&1 || true
      printf '\nfocused %s — switch spaces with the picker (prefix+w)\n' "$HERDR_INGEST_FIRST_WS"
    fi

    if [ "$watch" = 0 ]; then return "$sweep_rc"; fi
    HERDR_INGEST_FIRST_WS=""
    printf -- '--- sleeping %ss, ctrl-c to stop (%s)\n\n' "$interval" "$(date '+%H:%M:%S')"
    sleep "$interval"
  done
}

# Detect source vs execute: sourcing this file must run nothing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  herdr_ingest_main "$@"
fi
