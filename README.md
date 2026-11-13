# TypeType tvOS – initial native client scaffold

**Status: source scaffold, not a verified Xcode build or a full Android TV port.**

This is a native SwiftUI/tvOS starting point for the TypeType-Server **API v1**. It is based on the public interface of the Android TV source at <https://github.com/TypeType-Video/TypeType-TV> (default `dev` branch, inspected 2026-11-13). The reference application is GPL-3.0. This scaffold is also GPL-3.0.

## Implemented in the starter

- tvOS SwiftUI application shell and focusable home cards via the system focus engine
- Manual TypeType HTTPS server address and `/api/instance` compatibility test (`apiVersion == 1`)
- `/api/recommendations/home` and `/api/search` JSON decoding
- Details screen with a player-entry action
- **HLS-only** playback via public AVKit/AVPlayerViewController when the server response has `hlsUrl`
- Unsigned tvOS simulator build workflow on GitHub's standard `macos-26` ARM runner, using Xcode 26.1.1
- No credentials, signing certificates or Apple IDs committed or passed to CI

**Not yet implemented:** authenticating accounts/guest sessions, device-code login, protected recommendations, source-specific stream variants, TypeType SABR session playback, segmented audio/video merging, SponsorBlock, captions, 4K/HDR, history/favorites, playlists, quality/audio track selection, image authorization, certificate pinning, and lifecycle/persistence refinements. In particular, **most YouTube VOD content will not play yet**, because the Android client uses SABR and this starter intentionally does not claim AVPlayer can read SABR directly.

## Getting started

1. Create a GitHub repository under your own account. Upload these files into its root, **including `.github/workflows/tvos.yml`**. Public repos can use standard GitHub-hosted runners at no charge. A private repo consumes included compute usage.
2. On GitHub, open Actions → `tvOS (unsigned simulator build)`; a push to `main` or `dev` also triggers the workflow. The first CI build still needs to run and pass.
3. To work on a Mac (including a macOS VM with Xcode): `brew install xcodegen && xcodegen generate && open TypeTypeTV.xcodeproj`.
4. Configure `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to a unique reverse-DNS identifier. In Xcode, select your Apple Personal Team and use automatic signing for a *physical* paired Apple TV. A free Personal Team normally needs re-provisioning after seven days. Your Mac/VM must be on the same LAN or support Apple TV discovery/pairing.
5. In the app, enter your own HTTPS TypeType instance URL, e.g., `https://your-typetype-server.example`. There is no hardcoded personal domain.

**Build on Mac CLI:**

```sh
xcodegen generate
xcodebuild -project TypeTypeTV.xcodeproj -scheme TypeTypeTV \
  -configuration Debug -sdk appletvsimulator \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

**CI artifact:** an unsigned tvOS **simulator** `.app` ZIP (not a signed tvOS device `.ipa`). GitHub-hosted runners cannot connect directly to your LAN Apple TV. Real-device deployment requires pairing and signing on a machine that can reach the TV. A paid Apple Developer Program membership isn't necessary to start development, but makes distribution much easier.

## Why an independent Swift client?

The Android TV client is built in Kotlin, Jetpack Compose and Media3. Its UI, player and hardware decoder logic cannot simply be recompiled for tvOS. Instead, keep the existing server protocol and re-implement screens with SwiftUI and playback with AVFoundation/AVKit. Avoid private Apple APIs entirely.

## Cautions

- GitHub-hosted macOS runners have Xcode/tvOS SDKs but no signing identities. Never commit Apple passwords, `.p12` files or provisioning profiles. If paid distribution is added later, configure narrowly scoped GitHub Actions secrets only after a threat review.
- The API is currently used *without* auth. Depending on your server configuration, home/search can return HTTP 401/403. This is expected until guest/device sign-in is implemented.
- Only HTTPS server URLs are accepted in this prototype. No App Transport Security exceptions or insecure certificate bypasses.
- Check licenses and policies of any upstream video services and the TypeType codebase before distribution. This project includes no copied images or bundled Android source.
