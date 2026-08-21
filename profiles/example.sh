# An example profile. Point --profile at a copy of this file.
#
# A profile is a bash file the engine sources before it parses the flags. It can
# do three things:
#
#   1 set any HERDR_INGEST_* default, so a long command line becomes a short one
#   2 define ingest_summarise, replacing stage 4
#   3 define ingest_prompt,    replacing stage 5
#
# A flag on the command line always wins over a value set here. That ordering is
# what makes a profile safe to keep in version control: it is the team default,
# not a lock.

# --- 1. defaults -------------------------------------------------------------
# Anything the usage text lists as an environment variable can be set here, plus
# the naming templates and the caps.

# shellcheck shell=bash
# The HERDR_INGEST_* defaults set below are the profile's published interface:
# the engine reads them after it sources this profile, so shellcheck cannot see
# the use from here. This directive precedes the first command, so it applies
# file-wide.
# shellcheck disable=SC2034
HERDR_INGEST_WORKTREE_TEMPLATE='{prefix}-{key}'
HERDR_INGEST_BRANCH_TEMPLATE='fix/{prefix}-{key}-{slug}'
HERDR_INGEST_MAX_SPACES=3
HERDR_INGEST_AGENT='omp'

# Source flags have no profile hook of their own, because a source parses its own
# flags. Set the source's documented environment variable instead:
#   SENTRY_ORG / SENTRY_PROJECT, LINEAR_PROJECT, GITHUB_REPO.
: "${SENTRY_ORG:=acme}"
: "${SENTRY_PROJECT:=acme-backend}"

# --- 2. stage 4: summarise ---------------------------------------------------
# Defining this function replaces whatever the source ships. Delete it to fall
# back to the source's own summariser; pass --no-summarise to turn stage 4 off
# for one run without editing this file.
#
#   $1  path to the item JSON
#   $2  path to the worktree, which a dry run has not cut yet
#   stdout markdown; it becomes the brief's Context section
#
# This one records what the farm already knows about the item, which is cheap,
# offline and often the thing you actually wanted to see.
ingest_summarise() {
  local item="$1" worktree="$2" branch

  printf 'Farm state:\n\n'
  if [ -d "$worktree" ]; then
    branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
    printf -- '- worktree exists, on `%s`\n' "$branch"
    printf -- '- last commit: %s\n' \
      "$(git -C "$worktree" log -1 --format='%h %s' 2>/dev/null || printf 'none')"
  else
    printf -- '- no worktree yet; it will be cut from `%s`\n' "$HERDR_INGEST_MAIN"
  fi
  printf -- '- item payload: `%s`\n' "$item"
}

# --- 3. stage 5: prompt ------------------------------------------------------
# Defining this function replaces the built-in brief. Delete it to keep the
# built-in one; pass --prompt-template FILE for a template instead of code, or
# --no-prompt to skip the brief entirely and let the pane offer a bare agent
# session in the worktree.
#
#   $1  item JSON      $2  summary markdown   $3  brief to write
#   $4  branch         $5  worktree
#
# Write $3 or write nothing. Writing nothing is treated as "no brief", exactly
# like --no-prompt, so a hook that decides an item is not worth an agent can just
# return.
ingest_prompt() {
  local item="$1" summary="$2" out="$3" branch="$4" worktree="$5"

  # An example decision: a low-severity item gets no brief, so its pane opens as
  # a plain shell and no agent is ever offered a task for it.
  case "$(jq -r '.badge' "$item")" in
    info | debug | low | none) return 0 ;;
  esac

  {
    printf '# %s\n\n' "$(jq -r 'if .ref == "" then .key else .ref end' "$item")"
    printf '%s\n\n' "$(jq -r '.title' "$item")"
    printf 'Worktree `%s`, branch `%s`.\n\n' "$worktree" "$branch"
    jq -r '(.fields // [])[] | "- \(.name): \(.value)"' "$item"
    printf '\n'
    if [ -s "$summary" ]; then printf '\n%s\n\n' "$(cat "$summary")"; fi
    printf 'Reproduce it first. Fix the root cause. Run the gates. Show the diff.\n'
    printf 'Do not push to main.\n'
  } >"$out"
}
