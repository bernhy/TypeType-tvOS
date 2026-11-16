# TypeType tvOS — hardware test checklist

Simulator and wire-contract tests do **not** prove reliable playback on a physical Apple TV. Initial hardware playback has succeeded, but extended sessions, audio stability and codec coverage must pass the checklist before a production-ready claim.

## Devices

| Device | Minimum target | Important cases |
| --- | --- | --- |
| Apple TV 4K 1st gen (A10X, 2017) | tvOS 26 | H.264 hardware decode; audio/video sync and seek |
| Apple TV 4K 2nd gen (A12, 2021) | tvOS 26 | H.264, HEVC, HDR and 4K |
| Apple TV 4K 3rd gen (A15, 2022) | tvOS 26 | Hardware selections, 4K60, HDR |
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
- Failing stage: bootstrap, session, prefetch, window, segment, direct MP4 sample extraction, or sample-buffer rendering.
- Sanitized HTTP status / OSStatus / error and relevant timing; do **not** share access tokens, refresh cookies, signed segment URLs or session identifiers.
- Sanitized fMP4 structure (ftyp/moov/moof/mdat) and segment timestamps/sizes when extraction fails.

## Known player limitations

- Each SABR fragment is parsed directly from memory via ISO BMFF boxes and submitted as compressed samples; the former temporary-file AVAssetReader / explicit VT decoder pipeline has been removed. Additional server variants and codecs still require testing.
- Seek can reuse the existing SABR session. A bounded 20-second decoder preroll now supplies earlier reference frames while hiding pre-target video and trimming pre-target AAC packets; seek-to-first-visible-frame latency needs physical device confirmation.
- Hardware capability filtering remains, but AVSampleBufferVideoRenderer does not report its actual hardware/software execution mode. VP9/AV1 profiles, frame rate and HDR support require real-device validation.
- This project does not require a server-side HLS bridge or any TypeType Server modifications.

- The custom Siri Remote UIKit capture layer requires a real remote for touch-contact and directional click validation, especially on 2017 clickpad hardware and 2026 models.
- The disk cache is bounded and session-local; it currently preloads only segments included in the SABR windows returned by the unmodified server. Filling several minutes across multiple future windows remains under development.

## Sporadic audio/video dropouts on real Apple TV

Long-session playback has been tested; occasional audio glitches can also
appear as video stutters. Do not assume AAC priming is the sole cause.
In a Debug build, inspect these **sanitized** log markers near the reported
playback second:

- `TypeType SABR MEDIA-INTEGRITY` (stage=demux): invalid compressed bytes
  or timestamps, or a gap *inside* a fragment. A `correlated` marker means
  audio/video holes occurred at nearly the same media position.
- `TypeType SABR TIMELINE` and `SABR GAP`: disagreement between server
  segment metadata, native fMP4 time and previously observed sample end.
- `TypeType SABR RENDER-UNDERFLOW`: renderer headroom below 120ms,
  sampled every 100ms and logged at most once every 1.5s. Compare
  `videoAheadMs`, `audioAheadMs` and `cacheAheadMs`: high downloaded
  cache headroom but little renderer headroom suggests decode/scheduling
  backpressure rather than a missing network fragment.
- `TypeType SABR CACHE integrity-failure`: a cached file has changed or
  been truncated; it is discarded and the media bytes downloaded again.
- `TypeType SABR PRODUCER` and `SABR SEGMENT`: slow or failed downloads,
  server window timeouts, and partial progressive delivery.

User testing of the direct fMP4 path with independent audio/video renderer
tasks and native timestamp preservation reported elimination of the
previously reproducible audio/video glitches (merged PR #15). New diagnostics:
`TypeType SABR DIRECT-TIME`, `SABR AUDIO-BOUNDARY`,
`SABR SEEK-PREROLL`, `SABR DIRECT-FEED`. Re-test the exact previous
dropout time, then seek ±10/20/60 seconds and across video segment
boundaries. Record elapsed time until the **first correctly moving frame**
(not just a still-picture refresh).

## Interface, language and network checklist

- 34 tvOS UI tests cover server setup, Home and deep-card focus, sidebar, search, account/settings navigation, video details and SponsorBlock. Screenshot fixtures are Debug-only and do not replace testing with a physical Siri Remote.
- Check remote left movement from a first-column thumbnail, menu expansion and collapse, native URL keyboard, HTTPS/HTTP selection and hostname shortcuts.
- Check approved self-signed same-origin thumbnail downloads, external CDN HTTPS, and that bearer tokens never go to a third party.
- German is the default locale; English, French and Spanish translations are maintained in the shared Xcode String Catalog and validated by CI.

## SABR background-lookahead verification

- During video playback inspect TypeType's server logs: `/position` should report the **current playback clock**, not the end of a prefetched window. `bufferedRanges` should indicate only downloaded audio/video intervals.
- Confirm playback continues while the next server window is being fetched and its compressed fragments cached; compare the on-screen cached-ahead seconds to actual downloaded bytes.
- Check 180-second lookahead for 1080p AVC/AAC, then progressively higher bitrates, pause and resume, seek and restart, session expiry, server stalls, cache eviction and disconnection. Limits are conservative for unknown bitrate. Verify the cache stays within its configured MiB ceiling.
- Verify the pipeline reports a network error after draining already downloaded windows rather than silently discarding them.
