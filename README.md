# TypeType tvOS

Native, GPL-3.0 Apple TV client for [TypeType](https://github.com/TypeType-Video/TypeType), based on the Android TV reference (dev branch, 2026-11-13).

**Status (2026-11-14):** Xcode 26.2 **builds successfully** in free GitHub Actions, and tvOS Simulator **SABR contract tests pass**. Direct native YouTube SABR playback is an **experimental implementation**; live streams, long-run playback, A/V sync, 4K/HDR and AV1 are **not yet validated on actual Apple TV hardware**. This is not yet a production-ready app or full Android-TV feature-parity port.

## Device and architecture decisions

- Support **Apple TV 4K first generation (2017) or newer**; Apple TV HD is out of scope. Minimum deployment target: **tvOS 26.0**.
- **No modifications to TypeType Server**. YouTube uses the existing TypeType **SABR API v1** directly. No HLS-bridge changes or server-side transcoding.
- Default **hardware-only decoding**: codec discovery uses VideoToolbox and the video pipeline creates a decoder with `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`. Unsupported combinations fail rather than silently falling back to software. Explicit software-decoding opt-in is **OFF** by default.
- Use public Apple APIs (SwiftUI, CoreMedia, AVFoundation, VideoToolbox, URLSession, Keychain).

## Implemented so far

- SwiftUI TV navigation and Android-inspired visual language: dark ink background, TypeType red accent, thumbnail-first recommendation grid, collapsible icon sidebar and tvOS focus navigation. Search, details and library remain independently navigable.
- HTTPS by default; HTTP is offered explicitly for local/private hosts only. The connection screen uses the native URL keyboard and separates hostname from protocol.
- Self-signed HTTPS certificates are rejected until the user reviews their subject, chain and SHA-256 fingerprint and explicitly pins that certificate to the exact origin in Keychain. Changing it prompts again.
- Same-origin thumbnails use the same pinned server connection; a bounded in-memory thumbnail cache reduces redundant requests. External CDN images keep Apple's standard TLS checks.
- Guest login when supported, device-code account pairing, and per-origin Keychain token storage.
- Hardware codec indicators for H.264, HEVC, VP9 and AV1; maximum resolution setting; software-decoding override.
- **Experimental YouTube player**: SABR bootstrap/session/position/prefetch/windows/segments, fMP4 sample extraction using `AVAssetReader`, explicit VideoToolbox hardware decoding, synchronized audio/video renderers, pause and ±seek buttons.
- Native HLS AVPlayer path for compatible non-YouTube sources.
- Multilingual interface using Apple's single Xcode String Catalog (TypeTypeTV/Localizable.xcstrings), with semantic keys, dynamic language discovery and an in-app language picker. German is the default; English, French and Spanish are included. See LOCALIZATION.md.
- CI validates translation resources, builds an unsigned simulator app and runs SABR/network tests plus locale-specific tvOS UI screenshot tests.

## Technical playback path

TypeType Server SABR session and segments → Swift SABR transport → fMP4 init/fragment → AVAssetReader compressed samples → VideoToolbox (required hardware decoder) → AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer → AVSampleBufferRenderSynchronizer.

**Caution:** Each segment is temporarily assembled into `init + fragment` for AVAssetReader. This approach has not been validated against real TypeType SABR fragment variants and may require replacing the client-side segment reader. There is **no claim that video playback works on real devices yet**.

## Still required for a production release

- Real Apple TV 4K (2017+) testing of VOD, Siri Remote touch and directional press handling, seek, audio/video synchronization, *actual filled* buffer depth, offline resilience and error recovery.
- VP9/AV1, HEVC/HDR, 4K/60 and decoder profile/frame-rate validation on the appropriate real hardware.
- SponsorBlock, interactive chapters/endscreens, live chat, expanded queue/shuffle/repeat controls, polished focus/accessibility and broader Android feature parity. Subtitles and audio/quality controls are implemented experimentally and require live device validation; writing to playlists and Watch Later is already implemented.
- Validate the implemented session refresh/resume, multi-window forward prefetch and cache-aware seeking against real SABR windows to achieve the larger configured buffer target when the server allows it; collect long-run resource measurements, then add signing/distribution.

See [TESTING.md](TESTING.md) for the device and live-stream test checklist.

## Build on GitHub

On push to `main`/`dev`, [GitHub Actions](https://github.com/bernhy/TypeType-tvOS/actions) uses a public-repository free `macos-26` runner, Xcode 26.2, XcodeGen and a matching tvOS Simulator. Its ZIP artifact is an **unsigned simulator app**, not a device-installable IPA. It also runs the `SabrWireContractTests` XCTest suite.

## Build locally on a Mac / macOS VM

    brew install xcodegen
    xcodegen generate
    open TypeTypeTV.xcodeproj

For a physical Apple TV, set a unique `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, select your Apple Development Team and sign/pair in Xcode. Never commit signing identities, passwords, session tokens or cookies.

## License and upstream reference

GNU GPL v3; see LICENSE. Upstream client: https://github.com/TypeType-Video/TypeType-TV. The tvOS code is a native implementation of the public API, not a cross-compilation of Android Kotlin/Media3.

### SABR buffer boundaries and accurate reporting

Upstream TypeType Server currently caps each SABR window at **12 segments per track** and its own memory read-ahead at approximately **24 MiB** (see `SabrPlaybackWindowTrackBuilder` and `SabrPumpPolicy`). The client has a separately bounded disk cache. The requested 180-second forward goal does **not** automatically imply a filled 180-second buffer. Cached-through reporting uses the shorter of audio/video track coverage, and playback window reports clamp old ranges to the configured back-buffer horizon.

These changes require no TypeType Server modifications. Multi-window ahead-of-playback scheduling remains to be validated separately on real SABR sessions.

## Local server transport

Local HTTP is an explicit opt-in and unencrypted, including account traffic. The build declares NSAllowsLocalNetworking rather than globally disabling ATS. HTTPS normally uses system chain verification; a user may review and approve a non-trusted leaf certificate SHA-256 fingerprint for exactly one origin. ATS may still reject unsupported TLS configurations, so real-device self-signed certificate testing is required. Changing the leaf certificate requires explicit reconfirmation. No automatic trust-all setting exists.

### Two-stage SABR lookahead (experimental)

The pipeline now separates a network/disk-cache producer from the audio/video decoder consumer. The producer uses the actual playback clock when sending server `/position` and `/prefetch` requests; per-track cached `bufferedRanges` let the server return later media windows **without falsely seeking the player's position**. Each new server window is fully downloaded before advancing to another, with at most two concurrent segment requests per prefetch batch. A bounded, ordered mailbox prevents window drops and unlimited metadata growth. The user-selected forward goal is additionally limited by an approximate video-bitrate/cache-capacity estimate (unknown bitrate: 60 s) so unusually high-bitrate 4K clips cannot prematurely evict too much active media. The first window remains available to the decoder immediately while its cache fills. This still requires real-server and real-device validation; an 180-second setting is a maximum target, not a measured guarantee.

## App branding

App version **0.1** and minimum **tvOS 26.0** are defined in `project.yml`. The Apple TV icon and top shelf art use the [official TypeType TV-mark SVG](https://github.com/TypeType-Video/TypeType-Frontend/blob/main/apps/web/public/logo.svg), preserved at `assets/TypeType-logo.svg`. `xcodegen generate` invokes `scripts/generate-app-icons.swift` via the project pre-generation command to rasterize the red mark as layered tvOS app icon assets. The generated PNGs are ignored by git. Do not manually edit generated PNGs.
