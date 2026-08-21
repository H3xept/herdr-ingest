#!/usr/bin/env bash
# Re-record every demo GIF in docs/ from the tapes in this directory.
#
#   bash docs/demo/record.sh          # all of them
#   bash docs/demo/record.sh gate     # just docs/gate.gif
#
# Needs vhs (which brings ttyd and ffmpeg) and gifsicle, none of which the
# product itself depends on. The tapes build their own throwaway farm under
# /tmp/herdr-ingest-demo and never touch a real tracker, so a re-record needs no
# token and no network.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

for bin in vhs gifsicle; do
  command -v "$bin" >/dev/null || {
    echo "record.sh needs $bin: brew install vhs gifsicle" >&2
    exit 1
  }
done

tapes=("$@")
if [ "${#tapes[@]}" -eq 0 ]; then
  tapes=(sweep gate adapter)
fi

for name in "${tapes[@]}"; do
  tape="docs/demo/$name.tape"
  gif="docs/$name.gif"
  [ -f "$tape" ] || { echo "no such tape: $tape" >&2; exit 1; }

  echo "recording $tape"
  vhs "$tape"

  # vhs writes a 256-colour GIF a frame at a time. A terminal recording is
  # almost all repeated pixels, so -O3 with a light lossy budget typically
  # halves the file with no visible change at README scale.
  before=$(wc -c <"$gif")
  gifsicle -O3 --lossy=40 --batch "$gif"
  after=$(wc -c <"$gif")
  printf '%s  %sK -> %sK\n' "$gif" "$((before / 1024))" "$((after / 1024))"
done
