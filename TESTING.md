# TypeType tvOS — hardware test checklist

The GitHub simulator build and wire-contract tests do **not** validate playback on a physical Apple TV. Do not advertise the app as working/ready until the tests below pass.

## Devices

| Device | Minimum target | Important cases |
| --- | --- | --- |
| Apple TV 4K 1st gen (A10X, 2017) | tvOS 17 | H.264 hardware decode; audio/video sync and seek |
| Apple TV 4K 2nd gen (A12, 2021) | tvOS 17 | H.264, HEVC, HDR and 4K |
| Apple TV 4K 3rd gen (A15, 2022) | tvOS 17 | Hardware selections, 4K60, HDR |
| Apple TV 4K 4th gen (A19, 2026) | tvOS 26 | AV1 hardware decode, high quality and HDR |

## Live instance smoke test

1. Connect over HTTPS by default; test the explicit HTTP option for private local hosts. With a self-signed HTTPS server, verify subject, certificate chain and SHA-256 fingerprint against a trusted source before confirming it. Changing the leaf certificate must prompt again. Apple ATS restrictions require device testing.
2. Keep **Softwaredecoding erlauben** OFF; verify hardware codec indicators on the physical device (simulator values are not authoritative).
3. Use a short YouTube VOD with SABR H.264/AAC. First check 720p/1080p picture and sound, then verify 4K where supported.
4. Test multiple minutes uninterrupted, Play/Pause press, Siri Remote touchpad contact, left/right clicks at **5/10/15/20-second** intervals, focus navigation while controls are visible, and status bar hiding after five seconds.
5. Confirm network caching: configure **180-second forward / 120-second back** target with 512 MiB cap, measure *actual* buffered media time and disk size, check requests under playback and pause, repeat with 600-second target. The server may deliver smaller windows; do not claim otherwise.
6. Test stalled network, seek across window boundaries and resuming after idle.
7. Test preferred audio language, HDR formats, video quality and eventually livestreams and alternative providers.
8. Confirm VideoToolbox hardware decode, A/V lip sync, frame drops, CPU, memory, thermal behavior and correct HDR signalling.

## Collect safe diagnostics

- Apple TV model/tvOS, codec and itag, profile, resolution, frame rate, SDR/HDR.
- Failing stage: bootstrap, session, prefetch, window, segment, AVAssetReader, VideoToolbox or sample-buffer rendering.
- Sanitized HTTP status / OSStatus / error and relevant timing; do **not** share access tokens, refresh cookies, signed segment URLs or session identifiers.
- Sanitized fMP4 structure (ftyp/moov/moof/mdat) and segment timestamps/sizes when extraction fails.

## Known player limitations

- Each SABR fragment is currently read as a temporary `init+fragment` MP4 using AVAssetReader. Not yet guaranteed to work with all TypeType SABR stream layouts.
- The initial seek implementation restarts the SABR session. Quality switching and seamless playback recovery still need improvements.
- Hardware-decoding requirement is explicit, but profile/framerate/HDR acceptance and display support still need device-level validation.
- This project does not require a server-side HLS bridge or any TypeType Server modifications.

- The custom Siri Remote UIKit capture layer requires a real remote for touch-contact and directional click validation, especially on 2017 clickpad hardware and 2026 models.
- The disk cache is bounded and session-local; it currently preloads only segments included in the SABR windows returned by the unmodified server. Filling several minutes across multiple future windows remains under development.

## Interface, language and network checklist

- Five tvOS screenshot tests: server setup, thumbnail home, expanded sidebar, search and details. The expanded-menu screenshot uses a Debug-only fixture, not real Siri Remote input.
- Check remote left movement from a first-column thumbnail, menu expansion and collapse, native URL keyboard, HTTPS/HTTP selection and hostname shortcuts.
- Check approved self-signed same-origin thumbnail downloads, external CDN HTTPS, and that bearer tokens never go to a third party.
- German is the default locale; the English resource catalog is prepared, while full translations remain in progress.

## SABR background-lookahead verification

- During video playback inspect TypeType's server logs: `/position` should report the **current playback clock**, not the end of a prefetched window. `bufferedRanges` should indicate only downloaded audio/video intervals.
- Confirm playback continues while the next server window is being fetched and its compressed fragments cached; compare the on-screen cached-ahead seconds to actual downloaded bytes.
- Check 180-second lookahead for 1080p AVC/AAC, then progressively higher bitrates, pause and resume, seek and restart, session expiry, server stalls, cache eviction and disconnection. Limits are conservative for unknown bitrate. Verify the cache stays within its configured MiB ceiling.
- Verify the pipeline reports a network error after draining already downloaded windows rather than silently discarding them.
