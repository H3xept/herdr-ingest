# Hidden setup, sourced after the last Set. Puts this checkout's bin and root on
# PATH, points the cache and the farm at a throwaway directory, builds the demo
# checkout and sets a bare prompt.
#
# None of that is interesting to watch and all of it has to be identical across
# the tapes, so it lives in docs/demo/env.sh where shellcheck can read it.

Hide
Type "source docs/demo/env.sh"
Enter
Sleep 4s
Show
