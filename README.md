# TypeType tvOS

Native, GPL-3.0 Apple TV client for [TypeType](https://github.com/TypeType-Video/TypeType), based on the Android TV reference (dev branch, 2026-11-13).

**Status (2026-11-24):** Native SABR H.264/AAC playback, keyframe-fast seek, the stable startup poster, server-backed account/content/SponsorBlock settings, paged Home **"Ansehen fortsetzen"**, library writes, searches, channels and focus-driven lists are on `main`. A physical Apple TV has confirmed core playback, seek, navigation, watched-threshold persistence and playback against TypeType Server v1.19.1 following a corrected server-component update. Device coverage is not comprehensive. Most recent `main` [CI #45062229700](https://github.com/bernhy/TypeType-tvOS/actions/runs/45062229700): simulator and Debug/Release Apple TV builds and 350 unit tests passed, but **one of 57 UI tests failed** on Settings focus re-entry. Player OSD Concept B and Top Shelf remain separate, unmerged draft PRs. This is not yet a production-certified release.


## Attribution and third-party licenses

This application's original code is GPL-3.0 (see [LICENSE](LICENSE)).
The direct fMP4 parser and CoreMedia sample construction in
[`TypeTypeTV/SabrDirect/`](TypeTypeTV/SabrDirect/) were adapted from
[`TypeType-Video/TypeType-tvOS`](https://github.com/TypeType-Video/TypeType-tvOS)
(`TypeTypePlayerKit`) under the **Mozilla Public License 2.0**.
The upstream-derived source files retain MPL-2.0 SPDX headers and source
attribution; their source-level changes remain subject to MPL-2.0.
The original MPL text is included at [`LICENSES/MPL-2.0.txt`](LICENSES/MPL-2.0.txt).
The rest of the player (SABR session, track coordination, seeking, UI)
is developed in this project. Thanks to the upstream TypeType developers.

## Device and architecture decisions

- Support **Apple TV 4K first generation (2017) or newer**; Apple TV HD is out of scope. Minimum deployment target: **tvOS 26.0**.
- **No modifications to TypeType Server**. YouTube uses the existing TypeType **SABR API v1** directly. No HLS-bridge changes or server-side transcoding.
- **Hardware-aware codec selection:** `VTIsHardwareDecodeSupported` filters automatic representations, and software-allowed selection is OFF by default. Actual decoding is managed by `AVSampleBufferVideoRenderer`; its public API does **not** certify whether a particular frame was decoded in hardware. This is not the former explicit VT session hardware requirement.
- Use public Apple APIs (SwiftUI, CoreMedia, AVFoundation, VideoToolbox, URLSession, Keychain).

## Current feature / API support

For a detailed server-v1.19.1-to-tvOS implementation matrix, explicit native-vs-server settings, limits, performance notes and latest CI status, see **[docs/CAPABILITIES.md](docs/CAPABILITIES.md)**. The chronological [implementation status](docs/IMPLEMENTATION_STATUS.md) and [hardware test checklist](TESTING.md) are maintained separately.

## Implemented so far

- SwiftUI TV navigation and Android-inspired visual language: dark ink background, TypeType red accent, thumbnail-first recommendation grid, collapsible icon sidebar and stable tvOS focus navigation. Home "Ansehen fortsetzen" is a **single horizontal shelf**: four visible card slots, with additional server history pages loaded as the Siri Remote moves right. The full History stays in Library. Blocked-content Unblock rows highlight as a whole and keyword buttons are reachable via Siri Remote. Channel/public playlist tiles zoom and brighten their lower info pane without white borders. Channel avatars appear in video details and the SABR OSD; channel banners (or a blurred avatar) sit behind the channel controls.
- HTTPS by default; HTTP is offered explicitly for local/private hosts only. The connection screen uses the native URL keyboard and separates hostname from protocol.
- Self-signed HTTPS certificates are rejected until the user reviews their subject, chain and SHA-256 fingerprint and explicitly pins that certificate to the exact origin in Keychain. Changing it prompts again.
- Same-origin thumbnails use the same pinned server connection; a bounded in-memory thumbnail cache reduces redundant requests. External CDN images keep Apple's standard TLS checks.
- Guest login when supported, device-code account pairing, and per-origin Keychain token storage.
- Hardware codec indicators for H.264, HEVC, VP9 and AV1; maximum resolution setting; software-decoding override.
- **Native YouTube SABR player:** bootstrap/session/position/prefetch/windows/segments, direct in-memory ISO BMFF demux (`avc1`/`hvc1`/`vp09`/`av01`), compressed samples sent directly to Apple video/audio renderers with independently scheduled A/V feeding and a shared clock. Play/pause, quality/audio selection and seek with keyframe preroll are supported.
- Native HLS AVPlayer path for compatible non-YouTube sources.
- Multilingual interface using Apple's single Xcode String Catalog (TypeTypeTV/Localizable.xcstrings), with semantic keys, dynamic language discovery and an in-app language picker. German is the default; English, French and Spanish are included. See LOCALIZATION.md.
- CI validates translation resources, builds unsigned simulator and Apple TV Debug/Release targets and runs native SABR/network tests plus the evolving tvOS UI test suite. The last fully passing historical combined checkpoint was [#44111404428](https://github.com/bernhy/TypeType-tvOS/actions/runs/44111404428). More recent [#45062229700](https://github.com/bernhy/TypeType-tvOS/actions/runs/45062229700) passed builds and all 350 unit tests but failed one of 57 UI tests; see [current verification status](docs/CAPABILITIES.md#verification-checkpoint-2026-11-24).

## Technical playback path

TypeType Server SABR session and segments → Swift SABR transport + cache → in-memory fMP4 box and sample parser (`moof`/`traf`/`trun`/`tfdt`) → compressed `CMSampleBuffer` → `AVSampleBufferVideoRenderer` + `AVSampleBufferAudioRenderer` → shared `AVSampleBufferRenderSynchronizer`.

**Seeking:** For nonzero positions the server is asked for up to 5 seconds of bounded compressed preroll while playback and audio begin at the exact requested target. Video samples before that target are marked `DoNotDisplay` so reference frames can be decoded without flashing old pictures. This targets the reported 10–20-second post-seek video freeze. A November 17 hardware test reported immediate A/V sync after seeking; seek latency under different codecs, network conditions and hardware generations is not yet established.

**Separate review:** Liquid Glass OSD Concept B remains [draft PR #18](https://github.com/bernhy/TypeType-tvOS/pull/18); Top Shelf Continue Watching remains [draft PR #33](https://github.com/bernhy/TypeType-tvOS/pull/33). Neither is part of `main`.

## Still required for a production release

- Broader Apple TV 4K (2017+) testing of long VOD sessions, Siri Remote touch/directional presses, seek across fragment boundaries, *actual filled* buffer depth, offline resilience and error recovery. Basic A/V stability and prompt post-seek sync have been observed on hardware.
- VP9/AV1, HEVC/HDR, 4K/60 and decoder profile/frame-rate validation on the appropriate real hardware.
- Interactive endscreens, live chat, expanded queue/shuffle/repeat controls, additional focus/accessibility refinement and broader Android feature parity. SponsorBlock categories, skip overlays and account settings are implemented; their behavior, as well as subtitle and audio/quality controls, still requires broader live-device validation. Writing to playlists and Watch Later is implemented.
- Validate the implemented session refresh/resume, multi-window forward prefetch and cache-aware seeking against real SABR windows to achieve the larger configured buffer target when the server allows it; collect long-run resource measurements, then add signing/distribution.

In Debug builds, `TypeType SABR STARTUP` logs elapsed milliseconds from a start/seek action: `bootstrapMs`, `sessionMs`, `audioQueuedMs`, `videoQueuedMs`, `clockMs` and `displayReadyMs`. A value of `-1` means that milestone was not reached. `clock-started` and `display-ready` appear separately (after ten seconds, `display-timeout` is reported). Queued audio is **not** first audible sound, and display-layer readiness is **not** a guaranteed first visible-frame timestamp. Routine selection, seeking and buffering logs remain Debug-only; actionable repair/failure/recovery records remain in Release. The high-frequency renderer probe and display-readiness polling are now opt-in even in Debug (`typetype.sabrVerboseDiagnostics` UserDefaults boolean, default off). Apple's `AudioFormatDescription` console warnings are system output and cannot be removed by deleting TypeType NSLog calls. See [TESTING.md](TESTING.md) for the checklist.

## Build on GitHub

On push to `main`/`dev`, [GitHub Actions](https://github.com/bernhy/TypeType-tvOS/actions) uses a public-repository free `macos-26` runner, Xcode 26.2, XcodeGen and a matching tvOS Simulator. Its ZIP artifact is an **unsigned simulator app**, not a device-installable IPA. It also runs the full native contract/unit and tvOS UI test suites.

## Build locally on a Mac / macOS VM

    brew install xcodegen
    xcodegen generate
    open TypeTypeTV.xcodeproj

For a physical Apple TV, set a unique `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, select your Apple Development Team and sign/pair in Xcode. Never commit signing identities, passwords, session tokens or cookies.

## License and upstream reference

The application's own code is GNU GPL v3 (LICENSE). Direct fMP4 parser files adapted from the official TypeType-tvOS client are MPL-2.0; see the attribution section above and LICENSES/MPL-2.0.txt. The tvOS code is a native API implementation, not a cross-compilation of Android Kotlin/Media3.

### SABR buffer boundaries and accurate reporting

Upstream TypeType Server currently caps each SABR window at **12 segments per track** and its own memory read-ahead at approximately **24 MiB** (see `SabrPlaybackWindowTrackBuilder` and `SabrPumpPolicy`). The client has a separately bounded disk cache. The requested 180-second forward goal does **not** automatically imply a filled 180-second buffer. Cached-through reporting uses the shorter of audio/video track coverage, and playback window reports clamp old ranges to the configured back-buffer horizon.

These changes require no TypeType Server modifications. Multi-window ahead-of-playback scheduling remains to be validated separately on real SABR sessions.

## Local server transport

Local HTTP is an explicit opt-in and unencrypted, including account traffic. The build declares NSAllowsLocalNetworking rather than globally disabling ATS. HTTPS normally uses system chain verification; a user may review and approve a non-trusted leaf certificate SHA-256 fingerprint for exactly one origin. ATS may still reject unsupported TLS configurations, so real-device self-signed certificate testing is required. Changing the leaf certificate requires explicit reconfirmation. No automatic trust-all setting exists.

### Two-stage SABR lookahead (experimental)

The pipeline now separates a network/disk-cache producer from the audio/video decoder consumer. The producer uses the actual playback clock when sending server `/position` and `/prefetch` requests; per-track cached `bufferedRanges` let the server return later media windows **without falsely seeking the player's position**. Each new server window is fully downloaded before advancing to another, with at most two concurrent segment requests per prefetch batch. A bounded, ordered mailbox prevents window drops and unlimited metadata growth. The user-selected forward goal is additionally limited by an approximate video-bitrate/cache-capacity estimate (unknown bitrate: 60 s) so unusually high-bitrate 4K clips cannot prematurely evict too much active media. The first window remains available to the decoder immediately while its cache fills. This still requires real-server and real-device validation; an 180-second setting is a maximum target, not a measured guarantee.

## App branding

App version **0.1** and minimum **tvOS 26.0** are defined in `project.yml`. The Apple TV icon and top shelf art use the [official TypeType TV-mark SVG](https://github.com/TypeType-Video/TypeType-Frontend/blob/main/apps/web/public/logo.svg), preserved at `assets/TypeType-logo.svg`. `xcodegen generate` invokes `scripts/generate-app-icons.swift` via the project pre-generation command to rasterize the red mark as layered tvOS app icon assets. The generated PNGs are ignored by git. Do not manually edit generated PNGs.
