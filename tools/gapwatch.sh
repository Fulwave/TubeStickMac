#!/bin/sh
# Silence test: read the stick, then stay completely silent for a growing gap, read again, and so on.
# Reports the longest gap the stick survived. Needs a freshly replugged stick. Usage: tools/gapwatch.sh [gap seconds...]
cd "$(dirname "$0")/.."
GAPS="${*:-10 20 30 45 60 90 120 180}"
ok() { NOSCAN=1 ./build/em28xxprobe-host 2>&1 | grep -q "chip id (reg 0x0a) = 0x24"; }
ok && echo "$(date +%H:%M:%S) start: answers" || { echo "stick is not answering at the start; replug it first"; exit 1; }
for g in $GAPS; do
  sleep "$g"
  if ok; then echo "$(date +%H:%M:%S) after ${g}s of silence: answers"; else echo "$(date +%H:%M:%S) after ${g}s of silence: NOT RESPONDING  <-- the stick dies in a silence somewhere before ${g}s"; exit 0; fi
done
echo "survived all gaps"
