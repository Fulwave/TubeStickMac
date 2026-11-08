#!/bin/sh
# Build universal (x86_64 + arm64) regdump and em28xxprobe into dist/ so they run on old Intel Macs and new ones.
set -e
cd "$(dirname "$0")/.."
mkdir -p build dist
for tool in regdump em28xxprobe; do
  for min in 10.9 10.13; do
    if clang -w -arch x86_64 -march=x86-64 -mtune=generic -mmacosx-version-min=$min -o build/$tool-x86_64 tools/$tool.c \
         -framework IOKit -framework CoreFoundation 2>/dev/null; then
      echo "$tool x86_64 slice built for macOS $min+"; break
    fi
  done
  clang -w -arch arm64 -o build/$tool-arm64 tools/$tool.c -framework IOKit -framework CoreFoundation
  lipo -create -output dist/$tool build/$tool-x86_64 build/$tool-arm64
  codesign -s - -f dist/$tool 2>/dev/null
  lipo -info dist/$tool
done
