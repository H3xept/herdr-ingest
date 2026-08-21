# Look only: Require and Set, never a Type. Sourced first by every tape.
#
# vhs applies Set to the terminal it is about to start, so every Set has to come
# before the first keystroke. A tape that overrides the size therefore sources
# this, then its own Set lines, and only then sources boot.tape.

Require bash
Require git
Require jq

Set Shell bash
Set FontSize 15
# 1360 fits the widest real line the sweep prints (128 columns) without
# wrapping. Sizing the terminal to the output beats trimming the output to fit.
Set Width 1360
Set Height 300
Set Padding 22
Set Theme "TokyoNight"
Set TypingSpeed 40ms
Set Framerate 24
