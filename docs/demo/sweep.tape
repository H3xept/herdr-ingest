# The core loop: a queue of items becomes a set of ready worktrees.
#
# Recorded as a dry run, which is the honest thing to show. A dry run does the
# whole pipeline and prints what it would create, so the recording needs neither
# herdr nor zellij nor a tracker account.

Source docs/demo/style.tape

Output docs/sweep.gif

Source docs/demo/boot.tape

Type "herdr-ingest --source json --items-json docs/demo/queue.json \"
Enter
Type "  --sort badge --badge-order critical,high,medium,low --auto --dry-run"
Enter
# Anchor on the LAST line the sweep prints, not the first. "would spawn" appears
# on item one, and waiting for that cuts the recording off mid-list.
Wait+Screen@60s /held back/
Sleep 4s
Type "clear"
Enter

# The same sweep, narrowed. A filter is how you decide what an agent is worth
# spending on, so it belongs in the same shot as the sweep itself.
Type "herdr-ingest --source json --items-json docs/demo/queue.json \"
Enter
Type "  --label security --auto --dry-run"
Enter
Wait+Screen@60s /webhook-signature/
Sleep 4.5s
