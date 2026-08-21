# The `y` gate: the pane hands the agent a brief, and nothing starts until you
# say so. This is the cost-control contract of the product, so it gets its own
# recording.
#
# `y` comes first and declining comes last on purpose. Declining execs a login
# shell, which replaces the prompt, so it has to be the final beat.
#
# Sleep, not Wait, all the way down. The gate blocks on `read` with the cursor
# still on the prompt line, and vhs only matches whole lines, so Wait never sees
# it. The durations below are the reading pace, not a guess at the runtime.

Source docs/demo/style.tape

Output docs/gate.gif

# The brief runs to 35 lines and scrolls in a pane this size, which is what a
# real pane does. The gate prompt is the part that has to be on screen. Every
# Set must precede the first keystroke.
Set Height 560
Set FontSize 14

# One hidden block per recording: gate-setup.sh sources env.sh itself.
Hide
Type "source docs/demo/gate-setup.sh"
Enter
Sleep 7s
Show

Type "lazy-brief $BRIEF ENG-418 Checkout-charges-the-last-line-at-full-price"
Enter
Sleep 5s

# Spend: the only thing that starts an agent.
Type "y"
Sleep 600ms
Enter
Sleep 4s

Type "clear"
Enter
Sleep 400ms

# Decline: the brief stays on disk, the pane stays a shell, nothing is spent.
Type "lazy-brief $BRIEF ENG-418 Checkout-charges-the-last-line-at-full-price"
Enter
Sleep 3.5s
Enter
Sleep 4s
