# Third-party acknowledgements

## Audicap — MIT

Copyright (c) 2026 ShinoKana.

Project: https://github.com/ShinoKana/audicap

The system audio PCM-copy pattern and speech confidence/overlap arbitration are informed by Audicap. Full license: `Resources/Audicap-LICENSE.txt`, also included in the application resources.

## ShazamIO — MIT

Project: https://github.com/shazamio/ShazamIO

The Shazam recognition endpoint, request headers and JSON protocol are adapted from ShazamIO. The 0.4 audio fallback uses NetEase for its recording candidate and this Shazam adapter to corroborate the work title and full artist identity. Shazam reference metadata does not replace the NetEase recording ID, version, duration or playback position. The adapter also remains in baseline tests. Full upstream copyright and license: `Resources/ShazamIO-LICENSE.txt`, also included in the application resources. No Python runtime or ShazamIO binary is bundled.

## Services and platform frameworks

Lyrics are looked up from four public services, without login, cookies or account data:
NetEase Cloud Music (`music.163.com/api/search/get`, `/api/song/lyric`), QQ Music
(`c.y.qq.com` search and `fcg_query_lyric_new`), Kugou (`lyrics.kugou.com` search and
download) and LRCLIB (https://lrclib.net/docs). Only the song title, artist, album and
duration (and, for NetEase, the player's song ID) are sent. Endpoint shapes were checked
against public community documentation, including the MIT-licensed API-Enhanced project
(https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced). Kugou's KRC word-timed
format is decoded locally with its publicly documented XOR key and zlib framing. The Swift
clients are independently implemented; no upstream code or lyric corpus is bundled.
Lyric content remains subject to its respective rights; a service's software license does
not grant rights to lyric content. Fetched lyrics are cached only on the user's Mac.

AppKit, SwiftUI, Core Text, ScreenCaptureKit, Speech, ShazamKit, JavaScriptCore, CommonCrypto
and CoreAudio are macOS system frameworks. Optional Chinese display fonts (楷体, 行楷, 魏碑,
隶书, 圆体, 宋体, 手写) are Apple system fonts that macOS downloads on demand through Core
Text; they are not bundled. No Apple language models are redistributed.

ScreenCaptureKit is used only to read system audio for live captions and song identification,
and only when those features are switched on. Version 1.0 no longer captures or reads any
player window image; the screen-text (OCR) reader of 0.4–0.5 and its bundled OCR engines and
models were removed.

The audio fallback sends locally generated fingerprints to NetEase and, for a new candidate's
work corroboration, Shazam. It does not upload PCM audio. Exact Shazam catalog IDs may also be
queried against Apple's Taiwan music catalog or Shazam's Chinese metadata endpoint. These
services and their catalog contents are not bundled or represented as open-source components.

Mimi and LyricsX were reviewed as product references; no code from them is included.

## CloudLyrics local playback format reference — MIT

The NetEase `lastPlaying` AES format and the per-process CoreAudio output query
were referenced from https://github.com/hellomyonly55/CloudLyrics-for-macOS
(`NetEaseLocalPlaybackBridge.swift`, blob 1c19d573369b90de9b8aac83ff542cafb40c7120).
Copyright (c) 2026 hellomyonly55. The full MIT license is included as
`Resources/CloudLyrics-LICENSE.txt` in both app and source packages.

The new local adapter reads only the selected player's playback state and the
current ID's metadata from its local queue. It never exports the queue, reads
cookies, modifies the player's database or enables a debugging port. Local
LevelDB log framing, CRC checking and monotonic sequence handling are implemented
in this project. CommonCrypto and CoreAudio are system frameworks.

## NetEase official fingerprint runtime — not redistributed

The local development build obtains unmodified sandbox.bundle.js and afp.wasm from the official NetEase Cloud Music Chrome Web Store extension (kemcalcncfhmdkgglekijclbomdoohkp, version 1.0.4). Its fixed SHA-256 hashes are recorded in `Sources/Recognition/NetEaseFingerprint.swift`. These third-party runtime files are not included in the app or source archive.

Public availability does not establish a redistribution or embedding license. No such license was found in the official package, and this project does not assert that these files are MIT licensed. The package's React MIT notice does not confer rights to NetEase's fingerprint algorithm. Any public/commercial distribution integrating this runtime requires a separate licensing review.

The local Swift JavaScriptCore adapter and HTTP parser were independently implemented. The public protocol was checked against the NetEase official extension and the MIT-licensed NeteaseCloudMusicApiEnhanced audio_match module; no third-party mirrored fingerprint binary is used.

Official home: https://fn.music.163.com/g/chrome-extension-home-page-beta/
Official store: https://chromewebstore.google.com/detail/kemcalcncfhmdkgglekijclbomdoohkp
Protocol reference: https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/main/module/audio_match.js
# Fusion Pixel Font

The bundled Chinese pixel typeface is Fusion Pixel 12px Proportional zh-Hans,
release 2026.10.25, from https://github.com/TakWolf/fusion-pixel-font.
Copyright (c) 2022 TakWolf. Licensed under SIL Open Font License 1.1.
The complete license is in Resources/Fonts/FusionPixel-OFL.txt; upstream
notices are retained in Resources/Fonts/LICENSES. The font is registered only
inside this process and is not installed into the user's system font library.

