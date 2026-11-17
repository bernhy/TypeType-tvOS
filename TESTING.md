# TypeType tvOS — hardware test checklist

Simulator and wire-contract tests do **not** prove reliable playback on a physical Apple TV. November 17 hardware reports confirm stable A/V on the direct renderer path, immediate picture after seeks **without a black frame**, correct startup-thumbnail fade and release, and the repaired focus/navigation and channel-tile behaviors through `6c1256b`. Initial picture/sound arrival was estimated at approximately one second, not instrumentally measured. The newer "Ansehen fortsetzen" Home filtering (`6be64f7`, `c02d0fb`) still needs its own hardware verification; long-run multi-device, codec and HDR testing remain open.

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
- Seek can reuse the existing SABR session. A bounded 5-second decoder preroll supplies reference frames while hiding pre-target video and trimming pre-target AAC packets. The previously reported 10–20-second post-seek desynchronisation was no longer observed on November 17; repeat under other codecs/devices and measure objectively.
- Hardware capability filtering remains, but AVSampleBufferVideoRenderer does not report its actual hardware/software execution mode. VP9/AV1 profiles, frame rate and HDR support require real-device validation.
- This project does not require a server-side HLS bridge or any TypeType Server modifications.

- The custom Siri Remote UIKit capture layer requires a real remote for touch-contact and directional click validation, especially on 2017 clickpad hardware and 2026 models.
- The disk cache is bounded and session-local; it currently preloads only segments included in the SABR windows returned by the unmodified server. Filling several minutes across multiple future windows remains under development.

## Sporadic audio/video dropouts on real Apple TV

Long-session playback has been tested; occasional audio glitches can also
appear as video stutters. Do not assume AAC priming is the sole cause.
In a Debug build, inspect these **sanitized** log markers near the reported
playback second. High-frequency renderer/demux probes and routine selection,
seek and buffering records are disabled in Release; significant recovery,
repair and failure events remain logged:

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

## Startup and seek latency measurements (Debug)

- For each Apple TV and codec, start a VOD from zero and seek at least three times to 10/20/60 seconds, including across fragment boundaries. Compare network, cached and resumed cases.
- Filter Xcode's console on `TypeType SABR STARTUP`. The `clock-started` record reports elapsed milliseconds since start/seek for `bootstrapMs`, `sessionMs`, `audioQueuedMs`, `videoQueuedMs` and `clockMs`. The subsequent `display-ready` record adds `displayReadyMs`; `display-timeout` means the display layer was not ready within ten seconds. `-1` denotes a milestone not reached.
- Treat `audioQueuedMs` as first compressed audio submitted, **not** first audible sound. `displayReadyMs` is `AVSampleBufferDisplayLayer.isReadyForDisplay` observed by a 50 ms Debug-only poll, **not** an exact first-presented-frame timestamp. Use visual/audio observation for user-perceived latency.
- Record Apple TV generation, tvOS version, codec/itag, resolution, whether session reuse occurred, and perceived time to synchronized picture/sound. Do not include tokens, media URLs or session IDs in logs.
- Target improvements only after comparing bootstrap/session, queue and display-readiness stages. No faster clock start should sacrifice the now-correct A/V synchronisation.

## tvOS focus regression: block lists, channel tiles and Home

- **Hardware-confirmed:** Settings → Blocked: navigate Refresh → video Unblock → channel Unblock → first keyword Unblock with Down, including rows initially below the viewport. Press Up to reach the keyword entry field. The entire active row brightens while the button retains actual tvOS focus; globally blocked entries stay disabled.
- **Hardware-confirmed:** Channel Playlists and public-playlist videos: the entire tile zooms and its lower information panel brightens, without any white focus outline. Video thumbnails retain the Home card effect.
- **Hardware-confirmed:** Home: move Right repeatedly, wait, scroll, paginate, open a video and return. Delayed focus tasks must not restore recommendation 0 or select the collapsed global rail unexpectedly.
- **Hardware-confirmed:** Search, Library, subscription feed and channel videos preserve the chosen card/scroll when returning from details. Only explicit navigation entries should request initial page focus; refresh remains manual.

## Startup poster image lifetime (SABR)

- The verified stable SABR thumbnail overlay stays mounted throughout playback and seeks. The child is a permanent UIKit `UIImageView`; **only** its image reference is released after the 200 ms fade (plus a small margin) once the renderer displays actual video.
- Startup pictures are not inserted into the shared image cache. If the picture was previously cached by a listing, the corresponding entry is evicted when the poster releases it; other cached thumbnails remain intact.
- Re-test first-frame fade, repeated seek forward/backward, rapid Siri Remote seek bursts, retry after failure, no-image cases, and transitions. Normal seeks must never reload or redisplay the poster.
- Confirm in Instruments that image-view memory is reclaimed after fade; UIKit/CoreAnimation may retain transient allocations until the OS collects them.

## SABR startup poster regression — resolved on hardware

- Regression record: `5e660c890b2d` showed immediate picture during seeking. A later conditional SwiftUI poster produced black frames; removing it in `493334d` resolved the issue. Keeping the poster view permanently mounted while changing only its opacity (`86f0853`) restored the thumbnail **without** black seek frames, as verified on an Apple TV.
- Final `main` additionally releases the decoded `UIImage` reference after the fade while preserving the stable UIKit view (`3f3ad7d`); this was also confirmed working on hardware. Immediate reclamation of all platform-managed texture allocations is not guaranteed.
- Regression coverage remains: ±10/20-second rapid seeks, first-frame thumbnail fade, retry, videos without artwork. The Debug marker `TypeType SABR SURFACE makeUIView` should not recur merely due to ordinary seeking. These are checks against regression, **not** active implementation TODOs.

## Startup thumbnails (SABR / HLS)

- At video startup show the already-known `VideoItem.thumbnailUrl` as a non-focusable full-screen backdrop over the initially black renderer; no second stream-metadata request is made to obtain the picture.
- For SABR, fade away the image only after `AVSampleBufferDisplayLayer.isReadyForDisplay` and the playback clock is running. Loading/queued samples alone must not dismiss it.
- For non-YouTube HLS, keep the poster until AVPlayer has started and its time is actually progressing (AVPlayerViewController does not expose a precise first-presented-frame callback).
- Repeat with cached/uncached artwork, a failed/retried stream, a pause during buffering, and initial resume. Confirm that the poster does not intercept Siri Remote presses or reappear on normal seeks.

## End-screen cards (SABR VOD)

- Test a YouTube VOD with creator-supplied end screens. Verify the cards appear only within their server-provided start/end times and remain aligned to the actual video picture at 1080p and 4K, including letterboxing.
- Use the Siri Remote to focus and open video, channel and playlist cards. A video starts in a new player; Back returns to the original detail/playlist flow. Closing end screens without choosing a card restores normal left/right seeking.
- Settings → Content → Show end screens must hide/show the cards based on the account's `hideEndScreens` server setting. Videos without end-screen metadata should never display fabricated recommendations. Websites are intentionally unsupported on tvOS (no browser).
- Playback must not wait for end-screen metadata. Prefer SABR bootstrap, reuse already-cached details, and only attempt optional stream metadata lookup within 60 seconds of the end. Confirm frequent seek/recovery and A/V synchronization remain unchanged.

## Home — "Ansehen fortsetzen"

- The Home rail is **not** the full recently-watched history. Eligible cards must have a saved playback position greater than zero and a known positive duration, and must not have reached the shared **90% watched threshold**. Completed, never-started, live and duration-unknown entries do not qualify.
- Test a history with at least eight completed videos followed by a partially watched video: Home must find the resumable entry in the newest 100 raw events rather than blindly taking the first eight. Maximum eight eligible cards on Home; Library → History remains a separate, complete history.
- Seek, resume, reach 90%, then return to Home: the completed card should disappear from this rail without deleting its Library history. Switching "Ansehen fortsetzen anzeigen" OFF must hide this rail only, not erase saved history or playback positions.
- The rail heading, empty state and settings explanation must be correct in German, English, French and Spanish. **Hardware confirmation remains pending for the new filter.**

## Channel artwork and diagnostics

- Open a video detail and the SABR OSD: the provider's channel avatar should appear beside its name. Artwork is loaded asynchronously through the existing verified thumbnail session and must not delay playback.
- Open a channel: the server's banner image should fill the top header behind the Subscribe, Videos/Shorts and additional action buttons. Where no banner exists, use a softly blurred avatar. Check light artwork, focus and Siri Remote navigation.
- Switching channels must remove stale artwork; unsubscribed channels opened from videos should work.
- High-frequency renderer and display-probe logs are opt-in: set `typetype.sabrVerboseDiagnostics` to true in device UserDefaults if you need the `SABR STARTUP` milestones. Apple CoreMedia/AudioFormatDescription system diagnostics are separate and are not controlled by TypeType NSLog.

## Interface, language and network checklist

- The tvOS UI test suite covers server setup, Home and deep-card focus, sidebar, search, account/settings navigation, video details and SponsorBlock; the latest completed successful combined run for the confirmed navigation fixes was [#44111404428](https://github.com/bernhy/TypeType-tvOS/actions/runs/44111404428) (`6c1256b`). Screenshot fixtures are Debug-only and do not replace testing with a physical Siri Remote.
- Check remote left movement from a first-column thumbnail, menu expansion and collapse, native URL keyboard, HTTPS/HTTP selection and hostname shortcuts.
- Check approved self-signed same-origin thumbnail downloads, external CDN HTTPS, and that bearer tokens never go to a third party.
- German is the default locale; English, French and Spanish translations are maintained in the shared Xcode String Catalog and validated by CI.

## SABR background-lookahead verification

- During video playback inspect TypeType's server logs: `/position` should report the **current playback clock**, not the end of a prefetched window. `bufferedRanges` should indicate only downloaded audio/video intervals.
- Confirm playback continues while the next server window is being fetched and its compressed fragments cached; compare the on-screen cached-ahead seconds to actual downloaded bytes.
- Check 180-second lookahead for 1080p AVC/AAC, then progressively higher bitrates, pause and resume, seek and restart, session expiry, server stalls, cache eviction and disconnection. Limits are conservative for unknown bitrate. Verify the cache stays within its configured MiB ceiling.
- Verify the pipeline reports a network error after draining already downloaded windows rather than silently discarding them.
