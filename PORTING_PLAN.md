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
| Media3 progressive audio/video MergingMediaSource | HLS multivariant playlists or server-side mux/packaging | **High**; AVPlayer does not expose equivalent generic source-merging API |
| TypeTypeMediaSource + SABR sessions/segments | Design HLS bridge or server-side compatible HLS endpoint; test on device | **Critical**; Apple AVPlayer does not natively understand TypeType SABR |
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
2. Establish whether the server can expose the SABR session as **standards-compliant HLS** (fMP4 init segments, audio/video playlists, duration, seek, live variant handling) with minimal server changes. Prefer remux/packaging to transcoding. AVPlayer needs supported codec/sample descriptions, not only an `.m3u8` filename.
3. If HLS packaging isn't possible, investigate a tvOS-local segment proxy/transmuxer; it is considerably more complex and must handle seeking, auth, subtitles and buffering. Do not assume a generic `AVURLAsset` can consume SABR directly.
4. Check native playback compatibility by model: AVC/AAC first, then HEVC/HDR, VP9, AV1 on hardware that documents them. Verify *AVPlayer actually accepts the container+codec combination*.
5. Only after reliable playback: device login & Keychain, home/search/library, subtitles, sponsor skips, live chat and background behavior.

## Public API and entitlement audit

- **Available:** SwiftUI, UIKit focus, AVFoundation, AVKit, URLSession, Keychain, UserDefaults, GameController (for advanced remote handling), Network framework, HLS, tvOS Simulator.
- **Not provided by tvOS as an app platform:** general WebKit/WKWebView app UI; therefore no web-wrapper solution.
- **Not provided by stock AVPlayer:** direct TypeType SABR/Media3 adaptive source implementation. Must be implemented or packaged as HLS.
- **Not an Xcode SDK restriction:** free GitHub build versus paid Apple membership; core APIs are present in the SDK. Paid program affects distribution/provisioning/TestFlight and particular entitlements, not the general ability to compile SwiftUI/AVKit clients.
- **Hardware tests:** GitHub macOS runners have simulators, not a pairing route to your private Apple TV. Physical device signing/install from your Mac VM is separate.

## GitHub account situation (checked in conversation)

The connected login was `bernhy`. Its installation was visible, but no write-accessible repositories were listed; the upstream `TypeType-Video/TypeType-TV` is public/read-only. This starter is delivered as a ZIP instead of making unapproved commits to upstream. Create a repository under `bernhy` and ensure GitHub app access to it. Then this starter can be committed to `main`.
