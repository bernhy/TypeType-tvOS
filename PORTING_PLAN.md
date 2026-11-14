# Architectural decisions (2026-11-13) — overrides older experiments

- Support **Apple TV 4K (2017) and newer**; not Apple TV HD. Keep minimum deployment tvOS 17.0 for the 2017 model, which is not supported by tvOS 27.
- **No server changes:** use TypeType Server API v1 exactly as the Android client does; no tvOS-specific HLS bridge or server-side transcoding.
- **Direct SABR playback on tvOS for YouTube:** implement native Swift session manager, segment transport, demux/timestamps, buffering, seeking, and audio/video synchronization. Feed compressed samples to public CoreMedia/AVFoundation/VideoToolbox hardware decoders/renderers. Other video services can still use native HLS as appropriate.
- **Hardware-first:** only hardware-supported codecs/profiles/resolution/frame rates/HDR enabled by default; software decoding strictly optional and OFF by default. Probe real-device capabilities, not merely SDK or simulator support. New A19 Apple TV 4K (2026) has AV1 hardware decode; do not assume AV1 hardware support on prior generations.
- Do not require private Apple APIs, client-specific proxy servers, paid runtime entitlements, or modifications to existing TypeType upstream code.
- **Settings split:** common content preferences are read/written through the unchanged TypeType Server `GET/PUT /api/settings` endpoints, with error rollback; hardware-first codec selection, resolution policy, Siri Remote seek intervals, SABR buffer/cache, animations, thumbnail memory and language choice remain local to each Apple TV. The settings UI mirrors Android TV's category rail and options panel.

## First milestones

1. Fix and verify free GitHub Actions Xcode 26 unsigned simulator build.
2. Implement real-device codec/decoder diagnostic for H.264, HEVC, VP9 and AV1, including profile/4K/HDR constraints.
3. Port TypeType SABR API contracts from Android (`SabrDto`, `SabrApi`, `SabrWindowLoader`) to Swift Codable and write tests for session/segment parsing.
4. Validate sample-buffer rendering and synchronization using public tvOS 17-compatible APIs on Apple TV 4K hardware.
5. Add seeking, playback recovery, hardware-only codec fallback, and quality/audio track selection, then UI/account features.

**Important:** the older HLS-bridge discussion below is historical research, not the agreed implementation strategy. HLS is retained only for existing non-YouTube services.

---
# TypeType Android TV → tvOS: technical porting plan

Source baseline: `TypeType-Video/TypeType-TV` branch `dev`, inspected 2026-11-13.

## APIs and feature mapping

| Android implementation | Public Apple approach | Risk / notes |
| --- | --- | --- |
| Jetpack Compose TV, focus/key navigation | SwiftUI tvOS Focus Engine + UIKit focus APIs | Low; adapt UX rather than pixel-copy |
| OkHttp + Kotlin Serialization | URLSession + Codable | Low; API paths and DTO field names reused |
| Android DataStore / Tink | UserDefaults for preferences; Keychain for credentials | Low-medium; don't put secrets in UserDefaults |
| Compose navigation/screens | NavigationStack, TabView, focus states | Low-medium |
| Media3 HLS | AVPlayer / AVPlayerViewController | Low for standard HLS variants |
| Media3 progressive audio/video MergingMediaSource | Native AVPlayer only for standard HLS alternatives; direct sample-buffer decoding for SABR | **High**; AVPlayer does not expose equivalent generic source-merging API |
| TypeTypeMediaSource + SABR sessions/segments | Existing native SABR session/segment transport, bounded cache/window producer, fMP4 reader and VideoToolbox sample renderer | **Critical**; Apple AVPlayer does not natively understand TypeType SABR |
| MediaCodec hardware capability checks | AVFoundation format support / VideoToolbox where supported | Medium-high; don't assume all Android codecs/playback modes |
| SponsorBlock / chapters / subtitles | Swift playback time observers, AVMediaSelection / supported subtitle formats | Medium after playback |
| Android TV Remote key handling | tvOS focus engine and AVPlayerViewController playback gestures | Low-medium, custom gestures after native prototype |
| Live chat overlays and Bilibili/NicoNico comments | SwiftUI overlay + streaming API | Medium |
| Native app updater / APK | Development installation, TestFlight/App Store when entitled | Platform-specific; no APK-like updater |
| TLS fingerprint pinning for private servers | URLSession server trust evaluation / pinned certificates | Medium; do not bypass validation |

## Verified Android server API interfaces

- `GET /api/instance` (`apiVersion == 1`)
- `GET /api/recommendations/home?service=0&limit=30`
- `GET /api/search?q=...&service=0`
- `POST /api/auth/guest`
- `POST /api/auth/device/start` → device-code login; `POST /api/auth/device/token` poll
- `GET /api/streams/youtube/sabr/bootstrap?url=...`
- `GET /api/streams/youtube/sabr?url=...`
- `POST /api/sabr/playback/{videoId}` → session
- `POST /api/sabr/playback/{sessionId}/segments` → windows with audio/video fragments
- `POST /api/sabr/playback/{sessionId}/position`, `prefetch`, `seek`
- `GET /api/streams/bilibili?url=...` and `/api/streams/niconico?url=...`

## Highest-priority experiment before feature parity

1. Confirm response for a normal YouTube VOD, a YouTube livestream and each alternative source from the *running TypeType server*; inspect actual codec/container/segment data without publishing bearer tokens or cookies.
2. Validate the existing **native tvOS SABR pipeline** against actual TypeType-Server audio/video windows and their fMP4 init/segment contents. No server-side HLS packaging, proxy service or upstream TypeType modifications are planned.
3. Verify the fMP4 fragment reader and VideoToolbox format descriptions on Apple TV 4K (2017+). If AVAssetReader cannot interpret TypeType's original fragments, replace the **client-side reader** with a suitable direct fMP4 sample parser while preserving the SABR transport.
4. Check native playback compatibility by model: AVC/AAC first, then HEVC/HDR, VP9, AV1 on hardware that documents them. Verify *AVPlayer actually accepts the container+codec combination*.
5. After stable playback: add fully working subtitles, SponsorBlock, live features, quality/audio track changes and robust background behaviour. Device login, Keychain, home, search and library UI have already been implemented.

## Public API and entitlement audit

- **Available:** SwiftUI, UIKit focus, AVFoundation, AVKit, URLSession, Keychain, UserDefaults, GameController (for advanced remote handling), Network framework, HLS, tvOS Simulator.
- **Not provided by tvOS as an app platform:** general WebKit/WKWebView app UI; therefore no web-wrapper solution.
- **Not provided by stock AVPlayer:** direct TypeType SABR/Media3 adaptive playback. The experimental client-side SABR→compressed samples→VideoToolbox pipeline supplies it without changing TypeType Server.
- **Not an Xcode SDK restriction:** free GitHub build versus paid Apple membership; core APIs are present in the SDK. Paid program affects distribution/provisioning/TestFlight and particular entitlements, not the general ability to compile SwiftUI/AVKit clients.
- **Hardware tests:** GitHub macOS runners have simulators, not a pairing route to your private Apple TV. Physical device signing/install from your Mac VM is separate.

## Active development milestone (2026-11-13)

- TypeType Server stays unchanged. YouTube SABR VOD windows now have a separate producer downloading compressed media to a bounded local cache, and a consumer that renders queued audio/video samples. The server receives the actual playback clock and separate cached ranges; video downloads do not impersonate a seek.
- A bounded mailbox prevents unbounded network-to-decoder queuing and never drops windows. Cache size and a conservative bitrate-aware target limit ahead-fetching. Download failures must not be reported as cached media.
- Automated contract tests exercise the buffer policy, queued-window ordering/backpressure, and HTTP/segment-cache flows using a mock TypeType service. They do **not** prove playback of real 4K/HDR/AV1 TypeType content.
- **Next validation gate:** H.264/AAC VOD playback with a running TypeType Server and physical Apple TV, followed by seek, AV sync, advanced codec/HDR and multi-minute cache fill measurements.


## Release parity review: TypeType 1.15.0–1.17.1 / Android TV 0.4–0.6 beta (2026-11-13)

Checked the official TypeType release notes and TypeType-TV releases, plus the
Server's `v1.17.1` routes and error schemas. The Android-TV repository still
publishes `0.x` releases; TypeType 1.17.1's mention of `1.13.0-beta.4` is
not an Android-TV release tag currently visible there.

| Feature or behavioral change | tvOS state | Further work |
| --- | --- | --- |
| Server SABR DELETE /api/sabr/playback/{sessionId} (1.17.1) | Implemented; transport contract test | Observe real server release/eviction on device |
| /api/sessions/playback/{start,progress,stop} | Implemented in SABR and HLS | Verify active-session UI on server |
| YouTube live HLS fallback (1.17.1) | Routed to streams/youtube/live | Confirm live manifest on Apple TV |
| Typed video-unavailable (1.17.1) | Map no_playable_streams/sabr_content_unavailable to permanent error | Verify additional upstream failure codes |
| Upstream Retry-After (1.17.0 and earlier) | Implemented in SABR and HLS lookups/renewal | Check real outage durations on hardware |
| Bilibili/NicoNico renewed HLS URLs (1.16.0) | AVPlayer stall refresh, bounded retries and position resume | Test discontinuities, expired URLs and pause/seek |
| End screens (Android 0.6.0-beta.1, server 1.17.0) | Not implemented | Read endScreenElements API, add focusable overlay |
| Custom seekbar icon (Android 0.5.0) | Not implemented | Account settings and tvOS overlay |
| Subscriptions/feed channel avatar filters (Android 0.4.x) | Not implemented | New browse screen and paging |
| Search filters videos/playlists/channels/music (Android 0.4.1) | Not implemented | Adapt search UI/API |
| Skip unavailable videos in playlist (1.17.1) | Sequential Watch Later/playlist player implemented; skips permanent errors with countdown | Verify navigation and playback completion on device |
| Playback queue, repeat/shuffle, playlist next (web 1.15–1.17) | Not implemented | Separate queue state machine |
| SponsorBlock, chapters, richer subtitle formats | Partial or absent | After first real decoder test |
| Stream health and recovery | SABR bounded retries, HLS reconnect, explicit decoder diagnostics | Hardware test with H.264/AAC 1080p, then 4K/HDR |

**Release gate:** A successful simulator build and tests are necessary, but
actual AV sync, codec profiles, bitstreams, long seeks, and Safari/YouTube
upstream behavior still need physical Apple TV and the user's TypeType server.

## Pre-hardware reliability audit (2026-11-14)

- Existing account credentials must **never** be replaced by an automatic SABR guest-login fallback (including a response arriving after device-code pairing).
- SABR startup now accumulates a bounded amount of first audio/video compressed samples across independent track-segment indices and windows; no identical index pairing is required. A stream that never offers both tracks is a proper failure, not a false completion.
- An end-of-stream renderer clock that stops progressing while *playing* is classified as stalled after a bounded deadline. Explicit pause resets the clock watchdog.
- The last prior green CI baseline was `7e2357dc`; rerun the full tvOS simulator **and** unsigned Apple TV arm64 device build after all subsequent changes.
- **Still not hardware-proven:** real SABR sample extraction, first-frame VideoToolbox output, audio sync, 4K/HDR, AirPlay/TV focus behavior, multi-minute buffering, subtitles and full remote interaction.
