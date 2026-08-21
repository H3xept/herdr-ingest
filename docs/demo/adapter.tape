# Adding a source: three bash functions and no engine change.
#
# Recorded against examples/sources/todo.sh, which is a real adapter that scans
# a checkout for TODO and FIXME comments. It needs no token and no network, so
# this is the one demo a reader can reproduce with nothing but a clone.

Source docs/demo/style.tape

Output docs/adapter.gif

Set Height 400
# The todo adapter prints file:line as the ref, so its widest line runs to 144
# columns. One notch smaller keeps the pixel width the same as the other GIFs.
Set FontSize 13

Source docs/demo/boot.tape

# Five functions, three of them required.
Type "grep -n 'ingest_source_[a-z]*()' examples/sources/todo.sh"
Enter
Wait+Screen@30s /normalize/
Sleep 4s

Type "clear"
Enter
Sleep 400ms

# Point --source at the file. The engine learns nothing about TODO comments; it
# only ever sees canonical items.
Type "herdr-ingest --source examples/sources/todo.sh --sort badge --auto --dry-run"
Enter
# The last line of the sweep, not the first: "would spawn" appears on item one,
# and waiting for that cuts the recording off mid-list.
Wait+Screen@60s /samesite-lax/
Sleep 4.5s
