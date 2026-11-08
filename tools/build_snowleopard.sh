#!/bin/sh
# Build thin, unsigned x86_64 tools for macOS 10.6 (Snow Leopard) and later into dist/snowleopard/.
# -mmacosx-version-min=10.6 makes the linker emit LC_UNIXTHREAD (not LC_MAIN, which 10.6 cannot load).
set -e
cd "$(dirname "$0")/.."
mkdir -p dist/snowleopard
for tool in regdump em28xxprobe; do
  clang -w -arch x86_64 -march=x86-64 -mtune=generic -mmacosx-version-min=10.6 \
    -o dist/snowleopard/$tool tools/$tool.c -framework IOKit -framework CoreFoundation
  echo "$tool: $(otool -arch x86_64 -l dist/snowleopard/$tool | grep -E 'LC_MAIN|LC_UNIXTHREAD' | awk '{print $2}')"
done
