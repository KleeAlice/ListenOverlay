#!/bin/bash
# Offline checks (no network, no permissions). ./test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/tests
FLAGS=(-swift-version 5 -warnings-as-errors -target arm64-apple-macos26.0)
run() { # name, sources... (last one is the test)
  local name=$1; shift
  xcrun swiftc "${FLAGS[@]}" "$@" -o ".build/tests/$name"
  ".build/tests/$name"
}

# Desktop lyrics: timing, styles, glyph layout, stage hit areas.
run stage Sources/Overlay/{LyricTimeline,LyricStyle}.swift Sources/Support/{ColorHex,ChineseDisplay}.swift Sources/Lyrics/LyricsModels.swift \
  Sources/App/{LyricsBridge,AppSettings}.swift Sources/Players/{PlayerTracker,NetEaseLocalPlayback}.swift Tests/StageTests.swift
run glyphs Sources/Overlay/{GlyphLayout,GlyphPainter,LyricStageView,LyricTimeline,LyricStyle}.swift Sources/Support/ColorHex.swift Tests/GlyphTests.swift

# Following the player: switching, jitter, seeks, pauses, per-song offsets (lyrics served offline).
MODEL_SOURCES=()
while IFS= read -r file; do MODEL_SOURCES+=("$file"); done < <(find Sources -name '*.swift' ! -path 'Sources/App/main.swift' | sort)
run model "${MODEL_SOURCES[@]}" Tests/ModelTests.swift

# Lyrics lookup (parsers, matcher, service with stubbed providers).
Tests/run_lyrics_tests.sh

# Player reading, sound recognition and supporting pieces kept from earlier versions.
run netease-local Sources/Players/NetEaseLocalPlayback.swift Tests/Kept/NetEaseLocalPlaybackTests.swift
run artwork Sources/Support/AlbumArtwork.swift Tests/Kept/AlbumArtworkTests.swift
run artwork-store Sources/Support/{AlbumArtwork,AlbumArtworkStore}.swift Tests/Kept/AlbumArtworkStoreTests.swift
run chinese Sources/Support/ChineseDisplay.swift Tests/Kept/ChineseDisplayTests.swift
run ring Sources/Audio/AudioRingBuffer.swift Tests/Kept/RingBufferTests.swift
run audio Sources/Audio/SystemAudioCapture.swift Tests/Kept/AudioCaptureTests.swift
run speech Sources/Audio/SpeechEngine.swift Tests/Kept/SpeechChoiceTests.swift
run song-metadata Sources/Recognition/SongMetadata.swift Tests/Kept/SongMetadataTests.swift
run music-confirmation Sources/Recognition/{MusicMatcher,SongMetadata,MusicConfirmation}.swift Tests/Kept/MusicConfirmationTests.swift
run music-corroboration Sources/Recognition/{MusicMatcher,SongMetadata,MusicCorroboration}.swift Tests/Kept/MusicCorroborationTests.swift
run netease-fingerprint Sources/Recognition/NetEaseFingerprint.swift Tests/Kept/NetEaseFingerprintTests.swift
run netease-matcher Sources/Recognition/{NetEaseFingerprint,NetEaseMusicMatcher,MusicMatcher,SongMetadata,MusicConfirmation}.swift Tests/Kept/NetEaseMusicMatcherTests.swift

# The whole app must still build and launch.
xcrun swiftc "${FLAGS[@]}" $(find Sources -name '*.swift') -o .build/tests/app-build
echo "PASS: full app compiles"
