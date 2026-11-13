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

1. Configure the app with a working HTTPS TypeType-Server API v1 instance. Guest-enabled servers should create a guest session; otherwise use device-code pairing.
2. Keep **Softwaredecoding erlauben** OFF; verify hardware codec indicators on the physical device (simulator values are not authoritative).
3. Use a short YouTube VOD with SABR H.264/AAC. First check 720p/1080p picture and sound, then verify 4K where supported.
4. Test multiple minutes uninterrupted, pause/resume, -10s/+30s seeking, stalled network and resuming after idle.
5. Test preferred audio language, HDR formats, video quality and eventually livestreams and alternative providers.
6. Confirm VideoToolbox hardware decode, A/V lip sync, frame drops, CPU, memory, thermal behavior and correct HDR signalling.

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
