# TypeType tvOS — implementation and server compatibility

> Audited 2026-11-24. Client baseline: `bernhy/TypeType-tvOS` `main` at `e4d44d462620`. Server contract baseline: official `TypeType-Video/TypeType-Server` **v1.19.1** (`8fc0b3aab7c0`). This is a **code/API inventory**, not a claim that every feature has been exercised on every Apple TV. Consult [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for historical commits and [../TESTING.md](../TESTING.md) for QA.

## Status vocabulary

- **Implemented** — feature is present in `main`; it may still require device/live-server coverage.
- **Device-confirmed** — the developer has reported the behavior working on physical Apple TV; this is not multi-device certification.
- **Partial / conditional** — depends on metadata, account access, a particular provider/codec or needs additional work.
- **Not shipped** — missing from `main` or exists only on an experimental branch.
- Server capability and tvOS support are **different**: a field/endpoint existing in TypeType Server does not mean the Apple TV UI exposes or honors it.

## Server / client architecture

| Layer | Official TypeType Server v1.19.1 | tvOS `main` | Status / boundary |
| --- | --- | --- | --- |
| Discovery | `/api/instance`, `/api/recommendations/home`, `/api/search`, `/api/search/filters` | `TypeTypeAPI`, Home, Search | Implemented; search continuation tokens kept opaque |
| YouTube VOD metadata | `/api/streams/youtube/sabr/bootstrap` and stream/metadata routes | `SabrService` in `SabrAPI.swift` | Implemented; actual SABR playback is separate from the web player |
| SABR playback | `POST /api/sabr/playback/{videoId}`; seek, position, prefetch, windows/segments, state and DELETE | Native URLSession transport, bounded cache, in-memory fMP4 demux and CoreMedia renderers | Device-confirmed H.264/AAC playback/fast seek; other codecs/conditions need wider QA |
| Other media | Stream routes, HLS sources and provider-specific proxy/manifest routes | `TVHLSPlayback` using `AVPlayerViewController` | Implemented when a compatible HLS URL is available; no tvOS-specific server transcoder or HLS bridge |
| Accounts | `/api/auth/*`, `/api/auth/me`, `/api/settings` | Password login, guest where allowed, device pairing where supported, refresh and per-origin Keychain | Implemented; device-code flow depends on the deployment |
| History / progress | `/api/history`, saved positions, watched-state routes, playback-presence routes | Library history, Continue Watching, session start/progress/stop, immediate local badge refresh | Implemented; server account history remains authoritative |
| Library writes | Favorites, Watch Later, playlists, subscribed channels, block lists | Add/remove/toggle, create/rename/delete playlists, video/channel blocks and keyword blocking | Implemented; account/permission dependent |
| Additional server systems | Profiles, recommendation feedback, notifications, recommender, portability/import, live chat, DeArrow, user-data routes | Not full parity with web/Android | **Server exists ≠ native client implemented**; see gaps below |

The tvOS client uses public tvOS 26 SwiftUI, AVFoundation/CoreMedia/VideoToolbox and URLSession APIs; minimum target is Apple TV 4K (2017). `AVSampleBufferVideoRenderer` does **not** reveal the actual hardware/software decoder chosen for each frame. The `allowSoftwareDecode` preference permits an otherwise-filtered representation; it does not bundle a custom decoder.

## Implemented tvOS features

| Area | User-visible behavior / source | State and important caveat |
| --- | --- | --- |
| Home | Recommendations; **Ansehen fortsetzen** as a single horizontal shelf; paged history/recommendations; resume focus/scroll restoration | Implemented. Only started, incomplete VOD with known duration; full History remains separate. Server setting may hide either shelf |
| Navigation | Collapsible global sidebar, synchronised resize animation; native focus sections/entry and return-to-card focus | Implemented, device feedback positive. No timer-driven corrective move in the main sidebar; some specialised SponsorBlock controls still have a bounded focus correction |
| Cards and menus | Seen/unseen and watch-progress, Shorts, live and members-only indicators; playlist/Watch Later/favorite badges; per-video context actions | Implemented. Focus-only motion avoids broad data re-fetches; mutation journal updates only affected rows |
| Search | Server filters and sort/group controls, suggestions/corrections, channels/public playlists, pagination, server-backed recent terms and clear-history | Implemented; provider results may not contain every content type |
| Channels / subscriptions | Subscribe/unsubscribe, Videos/Shorts tabs, VOD sort, channel banners/avatars; playlist, Community, podcast and course subpages | Implemented with provider-conditional data; Community is read-only |
| Library | Watch Later, favorites, watched/history, own playlists; history pagination; playlist play-all and skip of permanently unavailable items | Implemented. No full general-purpose persistent queue/repeat/shuffle controller |
| Video details | Playback, creator/channel links, related videos, description with full-text popup, comments/replies/images/voice playback | Implemented; comments are read-only, requested only when comments pane is opened |
| Player | SABR VOD H.264/AAC on Apple renderers; Play/Pause and Siri Remote seek; independently chosen codec/resolution, audio tracks, experimental subtitles; manual failure fallback | Core H.264/AAC and fast seek device-confirmed. VP9/AV1/HEVC, 4K60, HDR, subtitles and multi-device stability not certified |
| Seek and recovery | Up-to-5-second compressed keyframe preroll, fast correct-frame seek; session re-creation, bounded transport retries, optional early prewarm and cache handoff | Implemented, but seamless outage handoff is **not guaranteed**. No server-specific HLS patch |
| Buffering | Configurable forward/back buffer and disk limit; bounded two-stage producer/decoder pipeline and cache-aware reporting | Implemented. A requested 180-second window is a target, not proof that 180 seconds are actually downloaded |
| Overlays | Startup poster fades only after display-ready and running clock; image reference released after fade; SponsorBlock notices/manual and automatic actions; creator end-screen cards | Implemented. End screens support supported YouTube video/channel/playlist links, not arbitrary websites |
| Language / security | German default; English/French/Spanish localization; HTTPS and explicit private-host HTTP; per-origin certificate fingerprint trust; Keychain credentials | Implemented; security and UI checks remain required across devices |
| Diagnostics | Hardware codec probe, native transport/renderer diagnostics, safe HTTP error classification, bitrates in audio-track picker | Implemented; SABR audio bitrate may arrive in bits/s or kbit/s and is normalised **for display only** |

### Watched threshold: v1.19.1 server compatibility

The official v1.19.1 `SettingsItem` exposes `watchedThresholdPercent` through `GET/PUT /api/settings`. The tvOS Content picker supports `0` and `50…100`. `0` means **last minute for VOD longer than 60 seconds**, or **90% for videos up to 60 seconds**. An explicit percentage follows that percentage. On older servers that omit the property, the client falls back to **90%**; missing data must not be mistaken for the official default. The shared client policy drives card badges, Continue Watching eligibility, resume from zero on completed VOD, and watched actions; Shorts restart from zero and live streams are excluded from VOD watched/progress badges. Writes serialize, then perform a **single user-triggered GET** to verify persistence; this is not a per-card or per-focus request. Confirmed against a running v1.19.1 deployment after its independently versioned server component was installed.

The **main TypeType monorepo tag alone is not sufficient to identify submodule source revisions**. In the audited v1.19.1 tag, submodule gitlinks may point to older source while each component (Server/Frontend/Token/Downloader) has its own `v1.19.1` release tag. Operators building a unified self-hosted stack should verify the **component checkout/installed binary**, not just the parent tag or a stamped version label. This is deployment guidance; the tvOS client does not manage the server's build/update script.

### Server-backed account settings actually applied by tvOS

- The nine Content visibility/history switches: `hideHomeRecommendations`, `hideContinueWatching`, `hideRelatedVideos`, `hideEndScreens`, `hideSubscriptionLiveStreams`, `hideMembersOnlyContent`, `hideShorts`, `hideComments`, `disableWatchHistory`.
- `watchedThresholdPercent` as above. `subtitlesEnabled`, subtitle/audio language and `preferOriginalLanguage` are read where the player applies them; do not assume every server playback setting is exposed in tvOS.
- SponsorBlock global mode, per-category actions, minimum duration, current-segment and chapter visibility, full-video behavior, music filtering, mute/skip flags. The app reads/writes these through server settings; actual skip policy is local to the player.
- **Apple-TV-local settings:** software-allowed flag, max resolution, directional skip (5/10/15/20 s), notice timeout, forward/back buffer, disk cache size, navigation animations, thumbnail memory, UI language and hardware diagnostics.
- Server settings such as web `playerEngine`, `miniPlayerEnabled`, ambient-light/DeArrow preferences, default landing page and web-grid geometry are **not evidence of matching native tvOS controls**. The tvOS client has its own native player and layout.

## Performance and stability decisions

- Native SwiftUI focus/defaultFocus with screen-local focus restoration, avoiding network requests triggered by every focus move; `TVVideoCardStatusCenter` and `TVVideoMutationCenter` make targeted status updates instead of invalidating whole grids.
- `TVStreamMetadataCache` coalesces/bounds metadata fetches; Home resume metadata is deferred/batched and merges without overwriting account progress. Paginated feeds/history load on approach rather than eagerly fetching everything.
- SABR network producer and renderer consumer are separated by a bounded ordered mailbox. Disk cache has a configured cap; reported coverage uses contiguous **both-track** availability. Parallel segment work is bounded. Early recovery cannot promise a gapless handoff.
- No extra network or media work is introduced by the v1.19.1 audio-bitrate display fix (`main` `e4d44d46`).

## Explicitly not shipped / open work

- **Liquid Glass player OSD Concept B** remains [draft PR #18](https://github.com/bernhy/TypeType-tvOS/pull/18), not merged into `main`. Existing Glass popups/settings are **not** that player OSD overhaul.
- **Apple TV Top Shelf Continue Watching** remains [draft PR #33](https://github.com/bernhy/TypeType-tvOS/pull/33), not merged into `main`. Home's in-app resume rail **is** in `main`.
- No full live-SABR renderer, interactive live-chat overlay, persistent queue/shuffle/repeat parity, general-purpose webview for website end-screen cards, full DeArrow/ambient-light/web-player setting parity, or all server account/profile/import tools.
- Additional real-device QA: first-generation/other Apple TV models, 4K/HDR/frame rate, VP9/AV1/HEVC, audio/subtitle variants, long sessions, remote touch gestures, server restarts/attestation and memory/thermal measurements.

## Verification checkpoint (2026-11-24)

At client `e4d44d462620`, [CI run #45062229700](https://github.com/bernhy/TypeType-tvOS/actions/runs/45062229700) passed localization validation, unsigned simulator build, unsigned Apple TV Debug **and** Release builds and **350 native unit/contract tests** (6 skipped, 0 failures). **56 of 57 tvOS UI tests passed**. The single UI failure involved focus-entry expectations when returning to Settings from the global rail (`testContentSettingsLeftFromSubnavigationRevealsMainSettings`). A paired experimental branch reproduced the same one-test failure; this did not demonstrate a SABR/codec regression. A documentation/test follow-up must be checked against its own CI before being called fully green.

Hardware feedback after the v1.19.1 server update confirmed persistence of `watchedThresholdPercent` and resumed video playback after service restart. This is an observation from one deployment, not an automated server/client end-to-end certification.

## Relevant upstream and client code

- Server: [SettingsItem](https://github.com/TypeType-Video/TypeType-Server/blob/v1.19.1/server-core/src/main/kotlin/dev/typetype/server/models/SettingsItem.kt), [SettingsRoutes](https://github.com/TypeType-Video/TypeType-Server/blob/v1.19.1/server-http/src/main/kotlin/dev/typetype/server/routes/SettingsRoutes.kt), [SabrPlaybackHandler](https://github.com/TypeType-Video/TypeType-Server/blob/v1.19.1/server-http/src/main/kotlin/dev/typetype/server/routes/SabrPlaybackHandler.kt).
- tvOS: `TypeTypeTV/TypeTypeAPI.swift`, `SabrAPI.swift`, `SabrPlayer.swift`, `SabrDirect/`, `TVHLSPlayback.swift`, `PreferencesView.swift`, `TVServerSettings.swift`, `TVPlaybackProgress.swift`, `BrowseView.swift`.
