# Sourced by every demo tape before recording starts. Keeps shell out of the
# tapes, so the tapes stay a description of the recording and this stays
# lintable.
#
# shellcheck shell=bash

DEMO=/tmp/herdr-ingest-demo
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

export PS1='$ '
export PROMPT_COMMAND=
export HISTFILE=/dev/null

# Three entries: docs/demo/bin for the stand-in agent, the repo root because
# lazy-brief lives there, and bin/ for the CLI. A real pane invokes both by the
# absolute path its layout baked in; PATH is only how a recording gets them to
# read as one word instead of a home directory nobody needs to see.
export PATH="$REPO/docs/demo/bin:$REPO:$REPO/bin:$PATH"

# Declining the gate execs "$SHELL" -l. Point it at a wrapper so the frame after
# a decline shows a bare prompt instead of this machine's hostname and user.
export SHELL="$REPO/docs/demo/bin/demo-shell"
export HERDR_INGEST_CACHE="$DEMO/cache"
export HERDR_INGEST_ROOT="$DEMO/farm"

# The agent the `y` gate offers. A recording machine has no agent installed, and
# the gate's contract is the decision rather than whatever runs after it, so the
# tapes point --agent at a command that shows it was reached and exits.
export HERDR_INGEST_AGENT=demo-agent

cd "$REPO" || return 1
rm -rf "$DEMO"
bash docs/demo/setup.sh >/dev/null
clear 2>/dev/null || true
