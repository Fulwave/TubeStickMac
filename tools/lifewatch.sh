#!/bin/sh
# Poll the stick every INTERVAL s until it stops answering (or MAX minutes pass); prints the time of death.
# Usage: tools/lifewatch.sh [interval-seconds] [max-minutes]
cd "$(dirname "$0")/.."
I="${1:-30}"; MAX="${2:-30}"; T0=$(date +%s)
while [ $(( $(date +%s) - T0 )) -lt $((MAX*60)) ]; do
  if NOSCAN=1 ./build/em28xxprobe-host 2>&1 | grep -q "chip id (reg 0x0a) = 0x24"; then echo "$(date +%H:%M:%S) alive ($(( ($(date +%s)-T0)/60 )) min into this watch)"; else echo "$(date +%H:%M:%S) DEAD after $(( ($(date +%s)-T0)/60 )) min of this watch"; exit 0; fi
  sleep "$I"
done
echo "still alive after $MAX minutes"
