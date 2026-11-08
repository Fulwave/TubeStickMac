#!/bin/sh
# Start/stop the keepalive helper. Usage: tools/keepalive.sh start|stop|status [interval-seconds]
cd "$(dirname "$0")/.."
PIDF=local/keepalive.pid
[ -x build/keepalive ] || clang -w -o build/keepalive tools/keepalive.c -framework IOKit -framework CoreFoundation
case "$1" in
  start) if [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then echo "already running (pid $(cat $PIDF))"; else nohup build/keepalive "${2:-5}" > local/keepalive.log 2>&1 & echo $! > $PIDF; echo "keepalive started (pid $!)"; fi ;;
  stop) if [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then kill "$(cat $PIDF)"; sleep 1; rm -f $PIDF; echo "keepalive stopped"; else echo "not running"; rm -f $PIDF; fi ;;
  status) if [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then echo "running (pid $(cat $PIDF))"; tail -2 local/keepalive.log; else echo "not running"; fi ;;
  *) echo "usage: $0 start|stop|status [interval-seconds]"; exit 1 ;;
esac
