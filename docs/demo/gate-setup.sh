# Put the shell in the state a real herdr pane starts in, so the gate tape can
# record lazy-brief doing exactly what it does inside a space.
#
# Sources env.sh itself rather than leaving that to the tape: vhs tolerates one
# Hide block per recording, so a tape gets exactly one hidden setup command.
#
# A dry run writes the briefs but deliberately creates no worktree, and creating
# the space needs herdr and zellij. So this cuts the one worktree by hand and
# cd's into it. Everything after that is the real pane: same brief on disk, same
# script, same prompt.
#
# shellcheck shell=bash

# shellcheck source=docs/demo/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

herdr-ingest --source json --items-json docs/demo/queue.json \
  --badge critical --auto --dry-run >/dev/null

BRIEF="$HERDR_INGEST_CACHE/json/briefs/eng-418.md"
WT="$HERDR_INGEST_ROOT/item-eng-418"

git -C "$HERDR_INGEST_ROOT/main" worktree add -q -b fix/eng-418 "$WT"

export BRIEF
cd "$WT" || return 1
clear 2>/dev/null || true
