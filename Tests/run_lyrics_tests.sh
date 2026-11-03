#!/bin/bash
# Lyrics module tests. Offline by default: every provider is stubbed with URLProtocol.
#   Tests/run_lyrics_tests.sh          build + run Tests/Lyrics/*.swift (except LiveProbe)
#   Tests/run_lyrics_tests.sh --live   also run the network probe (real providers, modest volume)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/lyrics
FLAGS=(-swift-version 5 -warnings-as-errors -target arm64-apple-macos26.0)
SOURCES=(Sources/Lyrics/*.swift)
SUPPORT=(Tests/Lyrics/Support/*.swift)

mkdir -p "$OUT"
rm -rf "$OUT/test-caches"

for test in Tests/Lyrics/*.swift; do
  name=$(basename "$test" .swift)
  [[ "$name" == LiveProbe ]] && continue
  xcrun swiftc "${FLAGS[@]}" "${SOURCES[@]}" "${SUPPORT[@]}" "$test" -o "$OUT/$name"
  "$OUT/$name"
done

if [[ "${1:-}" == "--live" ]]; then
  xcrun swiftc "${FLAGS[@]}" "${SOURCES[@]}" Tests/Lyrics/LiveProbe.swift -o "$OUT/LiveProbe"
  "$OUT/LiveProbe" "$OUT/live-cache"
fi

rm -rf "$OUT/test-caches"
