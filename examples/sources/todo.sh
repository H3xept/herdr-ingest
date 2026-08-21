# shellcheck shell=bash
# shellcheck disable=SC2034  # the HERDR_INGEST_* names are read by the engine
# that sources this file, not within it, so shellcheck cannot see their use.
# Source: TODO and FIXME comments in a checkout.
#
# This is a complete, runnable example of a custom source. It needs no token and
# no network: it scans a working copy for `TODO:` and `FIXME:` comments and turns
# each one into a canonical item. Point --source at this file to try it:
#
#   bin/herdr-ingest --source examples/sources/todo.sh \
#     --todo-path . --root /tmp/farm --auto --dry-run
#
# A source is one bash file that sets two variables and defines three functions.
# The engine loads the file, then calls the functions in order:
#
#   describe   who am I; prints `id`, `name`, `summary`, `needs` as TSV rows
#   fetch      print the raw payload as JSON on stdout (no arguments)
#   normalize  read that payload on stdin, print canonical items as JSON
#
# `option`, `usage`, `check` and `summarise` are optional. This file defines
# `option` and `usage` too, to show the optional flag contract: `option` sets
# HERDR_INGEST_OPT_SHIFT to the number of argv entries it consumed, so the engine
# knows how far to advance its own parse.

HERDR_INGEST_SOURCE_ID="todo"
HERDR_INGEST_SOURCE_PREFIX="todo"
HERDR_INGEST_SOURCE_SORT="badge"
# FIXME outranks TODO: earlier in this array sorts first under `--sort badge`.
HERDR_INGEST_SOURCE_BADGE_ORDER='["fixme","todo"]'

# The checkout to scan, empty until --todo-path or HERDR_INGEST_TODO_PATH sets it.
#
# Leave it EMPTY here and resolve the default inside fetch instead. A source is
# loaded at layer 3, before the flags are parsed and before the engine has
# resolved the farm, so HERDR_INGEST_MAIN is still unset at this point: reading
# it here would silently pin the default to the current directory. Any option
# whose default depends on engine-resolved state has to be resolved at the point
# of use, not at load time.
TODO_OPT_PATH="${HERDR_INGEST_TODO_PATH:-}"

ingest_source_describe() {
  printf 'id\ttodo\n'
  printf 'name\tTODO comments\n'
  printf 'summary\tTODO and FIXME comments found in a checkout\n'
  printf 'needs\tgit jq grep\n'
}

ingest_source_usage() {
  cat <<'EOF'
todo source flags:
  --todo-path PATH     directory to scan (default: the main checkout, else `.`)

todo environment:
  HERDR_INGEST_TODO_PATH  default for --todo-path, so a profile can set it

The scan uses `git grep` when PATH is a checkout, so it honours .gitignore and
skips the .git directory; otherwise it falls back to a plain recursive grep.
Each TODO: or FIXME: comment becomes one item, badged `todo` or `fixme`, and
`--sort badge` therefore puts every FIXME first.
EOF
}

ingest_source_option() {
  case "$1" in
    --todo-path) TODO_OPT_PATH="${2:-}"; HERDR_INGEST_OPT_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

# Print the raw matches as a JSON array of {file, line, text}. `git grep` keeps
# the scan inside tracked files and out of .git; the plain grep is the fallback
# for a directory that is not a checkout. Either way the match lines are handed
# to jq with -R (raw input), so a comment containing a quote or a backslash is
# encoded correctly instead of breaking the payload — that is the whole point of
# not concatenating strings by hand.
ingest_source_fetch() {
  # Resolve the default now, when the engine has settled the farm: an explicit
  # --todo-path wins, else the farm's main checkout, else the current directory.
  local path="${TODO_OPT_PATH:-${HERDR_INGEST_MAIN:-.}}"
  {
    if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$path" grep -nI -E 'TODO:|FIXME:' -- . 2>/dev/null || true
    else
      grep -rnI -E 'TODO:|FIXME:' "$path" 2>/dev/null || true
    fi
  } | jq -R -n -c '
    [ inputs
      # grep prints file:line:text; the file may itself contain a colon, so match
      # the line number non-greedily rather than splitting on the first colon.
      | capture("^(?<file>.*?):(?<line>[0-9]+):(?<text>.*)$")
      | {file: .file, line: (.line | tonumber), text: .text}
    ]'
}

ingest_source_normalize() {
  jq -c '
    # A rolling string hash over the file path and the matched comment text. The
    # key must be STABLE: the same TODO has to produce the same key on every
    # sweep, because the key names the worktree and the cache files. It is
    # derived from the file and the text and NOT from the line number on purpose
    # — an unrelated edit above the comment shifts its line but must not change
    # the key, or the engine would orphan the worktree the old key named.
    def h: explode | reduce .[] as $c (0; (. * 31 + $c) % 2147483647);
    [ .[]
      | . as $m
      | (if ($m.text | test("FIXME:")) then "fixme" else "todo" end) as $tag
      | ($m.text
         | sub("^.*?(TODO|FIXME):\\s*"; "")
         | if . == "" then "(no description)" else . end) as $comment
      | {
          key:      ($tag + "-" + (($m.file + "\u0000" + $m.text) | h | tostring)),
          ref:      ($m.file + ":" + ($m.line | tostring)),
          title:    $comment,
          subtitle: $m.file,
          badge:    $tag,
          fields: [
            {name: "file", value: $m.file},
            {name: "line", value: ($m.line | tostring)}
          ],
          body:     ("```\n" + $m.text + "\n```"),
          raw:      $m
        }
    ]'
}
