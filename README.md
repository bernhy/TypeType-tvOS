# TypeType tvOS

Native, GPL-3.0 Apple TV client for [TypeType](https://github.com/TypeType-Video/TypeType), based on the Android TV reference (dev branch, 2026-11-13).

**Status (2026-11-13):** Xcode 26.2 **builds successfully** in free GitHub Actions, and tvOS Simulator **SABR contract tests pass**. Direct native YouTube SABR playback is an **experimental implementation**; live streams, long-run playback, A/V sync, 4K/HDR and AV1 are **not yet validated on actual Apple TV hardware**. This is not yet a production-ready app or full Android-TV feature-parity port.

## Device and architecture decisions

- Support **Apple TV 4K first generation (2017) or newer**; Apple TV HD is out of scope. Minimum deployment target: **tvOS 17.0**.
- **No modifications to TypeType Server**. YouTube uses the existing TypeType **SABR API v1** directly. No HLS-bridge changes or server-side transcoding.
- Default **hardware-only decoding**: codec discovery uses VideoToolbox and the video pipeline creates a decoder with `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`. Unsupported combinations fail rather than silently falling back to software. Explicit software-decoding opt-in is **OFF** by default.
- Use public Apple APIs (SwiftUI, CoreMedia, AVFoundation, VideoToolbox, URLSession, Keychain).

## Implemented so far

- SwiftUI TV navigation and Android-inspired visual language: dark ink background, TypeType red accent, large featured-video backdrop, horizontal recommendation shelves, and native tvOS focus behavior. Search, details and library remain independently navigable.
- HTTPS instance compatibility check, guest login when supported, device-code account login and per-origin Keychain token storage.
- Hardware codec indicators for H.264, HEVC, VP9 and AV1; maximum resolution setting; software-decoding override.
- **Experimental YouTube player**: SABR bootstrap/session/position/prefetch/windows/segments, fMP4 sample extraction using `AVAssetReader`, explicit VideoToolbox hardware decoding, synchronized audio/video renderers, pause and ±seek buttons.
- Native HLS AVPlayer path for compatible non-YouTube sources.
- Free GitHub macOS 26 / Xcode 26.2 CI: unsigned tvOS simulator app artifact and XCTest SABR protocol tests.

## Technical playback path

TypeType Server SABR session and segments → Swift SABR transport → fMP4 init/fragment → AVAssetReader compressed samples → VideoToolbox (required hardware decoder) → AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer → AVSampleBufferRenderSynchronizer.

**Caution:** Each segment is temporarily assembled into `init + fragment` for AVAssetReader. This approach has not been validated against real TypeType SABR fragment variants and may require replacing the client-side segment reader. There is **no claim that video playback works on real devices yet**.

## Still required for a production release

- Real Apple TV 4K (2017+) testing of VOD, Siri Remote touch and directional press handling, seek, audio/video synchronization, *actual filled* buffer depth, offline resilience and error recovery.
- VP9/AV1, HEVC/HDR, 4K/60 and decoder profile/frame-rate validation on the appropriate real hardware.
- Subtitle display, SponsorBlock, chapters, live chat, audio-language/quality changes, writing to playlists, polished focus/accessibility and broader Android feature parity.
- Robust session refresh/resume, **multi-window forward prefetch and cache-aware seeking** to achieve the larger configured target when the existing SABR API allows it, long-run resource measurements, release assets, signing and distribution.

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
