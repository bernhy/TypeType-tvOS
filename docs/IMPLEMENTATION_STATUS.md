# TypeType tvOS – implementation status

> Maintain this list with feature changes. Every item has two checkboxes:
> **Code** is checked when implementation is committed; **Verified** is checked
> only after the corresponding build and automated contract/UI tests succeed.
> Record implementing commit SHAs, and update status in a follow-up documentation
> commit once CI verifies the code (a commit cannot reference its own SHA).
> Partial implementations stay open, with progress noted separately.

## Scope and conventions

- Reference: TypeType Server, Android, and Frontend **main** branches (2026-11-16).
- **Code**: `[x]` means feature implementation is committed; `[ ]` means open or partial.
- **Verified**: `[x]` means the combined CI build/tests passed; `[ ]` means still unverified.
- `CI pending` in Notes means code exists but validation is outstanding.
- Record relevant SHAs even before verification; retain unimplemented features as open tasks.
- Link source changes via commit SHA, not a date-only note. Put dependencies and
  known API-version limitations in the Notes column.
- Distinguish a setting stored via `/settings` from an effect actually applied to tvOS.

## Planned work

| ID | Code | Verified | Feature | Implementation commits | Notes |
| --- | --- | --- | --- | --- | --- |
| API-01 | [x] | [x] | Robust API errors: optional codes, request IDs, Retry-After, stable classifications | `10662f66, af7e3158, fdc8baa9, 474e2d9c, d02dbef1, 9fa5184b` | Corrected device-code error assertion and preserved SABR bootstrap-vs-session classification. |
| SEARCH-01 | [x] | [x] | `/search/filters`: content filters, grouped filters, sort | `e8400793, e634a0f2` | Server-advertised filters and Siri Remote controls. |
| SEARCH-02 | [x] | [x] | Paginate search with `nextpage`; corrected search hints | `e8400793, e634a0f2` | Opaque nextpage, correction and suggestion. |
| SEARCH-03 | [x] | [x] | Display/search channel and public playlist results | `e634a0f2` | Channels and public playlists have navigable cards. |
| CHANNEL-01 | [x] | [x] | Channel video sorting: latest / popular / oldest | `36c1b554, a7219f6b` | Sort not applied to Shorts tab. |
| CHANNEL-02 | [x] | [x] | Channel playlists and public playlist playback | `36c1b554, f5feb683, a7219f6b` | Public playlists distinct from own /playlists. |
| CHANNEL-03 | [x] | [x] | Channel Community posts (text/images/polls/videos) | `36c1b554, f5feb683, a7219f6b` | Read-only posts incl. images, poll choices and video links. |
| CHANNEL-04 | [x] | [x] | Channel podcasts and courses | `36c1b554, f5feb683, a7219f6b` | Courses shown when hasCourses is true. |
| BLOCK-01 | [x] | [x] | View and remove blocked channels/videos in Settings | `db9f5e79, a04f4937` | Encoded URL-tail routes tested; global blocks intentionally read-only. |
| BLOCK-02 | [x] | [x] | Manage blocked title keywords in Settings | `db9f5e79` | Adds, lists and removes user keywords. |
| DETAIL-01 | [x] | [x] | Related videos from `relatedStreams` on detail page | `7315e7f9, 4882e4c3` | Honors hideRelatedVideos and filter preferences. |
| CONTENT-01 | [x] | [x] | Honor hideContinueWatching and hideHomeRecommendations | `443554bf, 744bf946` | Existing saved history still visible in Library. |
| CONTENT-02 | [x] | [x] | Honor hideShorts, hideSubscriptionLiveStreams, hideMembersOnlyContent | `443554bf, 0931b730, 4882e4c3` | Visibility metadata may be unavailable for some provider rows. |
| CONTENT-03 | [x] | [ ] | Honor hideRelatedVideos, hideEndScreens, hideComments | `7315e7f9, 4882e4c3, fbc8450a` | Creator-placed YouTube end-screen cards now display over SABR VOD video with remote focus. hideEndScreens is respected; physical Apple TV confirmation pending. |
| CONTENT-04 | [x] | [x] | Visibly explain disabled watch-history recording at playback start | `7315e7f9` | HLS/SABR notices; existing positions remain readable, but no new progress/history is recorded. |
| CONTENT-05 | [ ] | [ ] | Startup landing, DeArrow, other content settings parity | — | Separate API/data pipeline |
| SETTINGS-02 | [x] | [x] | Explain each of the nine content settings in German, English, French and Spanish | `9fa5184b, 04482478` | Each setting has an inline explanation of its actual behavior, including unchanged old history and positions when recording is disabled. |
| SETTINGS-01 | [ ] | [ ] | Other account playback settings (autoplay, speed, audio only etc.) | — | Avoid destabilizing SABR |
| PROFILE-01 | [ ] | [ ] | Integrate server account profiles under locally saved accounts | — | `/profiles` is user-scoped, not admin |
| COMMENTS-01 | [x] | [x] | Switch description / comments on video detail; read comments, replies, images and voice replies | `e1c00a4e, ef2c8b15, fbc8450a, 3b2a4fba` | Read-only view; replies paginated, voice audio fetched via authenticated TypeType endpoint. CI green; live-server/device QA useful. |
| ACCOUNT-01 | [ ] | [ ] | Notification and recommender features, backup/imports | — | Lower priority |
| API-02 | [ ] | [ ] | Capability gating via `/instance` and audit unused fields | — | OpenAPI is manually maintained |

## Physical Apple TV feedback – 2026-11-16

All fixes below were committed after real-hardware feedback. **Code** is
committed, while **Verified** remains unchecked until the combined final
Xcode 26.2 CI run completes. Hardware revalidation is still recommended.

| ID | Code | Verified | User-visible correction | Implementation commits | Notes |
| --- | --- | --- | --- | --- | --- |
| QA-SEARCH-01 | [x] | [ ] | Group headings, four-language search filter labels, one unambiguous sort/default picker | `629c9a30`, `4da81150`, `20a043d4` | Preserve opaque server filter values and selectable default content types |
| QA-SEARCH-02 | [x] | [ ] | Remote navigation from Clear History to recent search terms | `629c9a30` | Await Apple TV focus confirmation |
| QA-CHANNEL-01 | [x] | [ ] | Correct Up focus through new channel actions, then Videos/Shorts and Subscribe | `6b666416`, `f46642c1` | UI regression updated for the new action row |
| QA-CHANNEL-02 | [x] | [ ] | Explicit Back and visible thumbnail focus in channel extra and public playlist pages | `1db3a6b6` | Includes empty/error subpage focus fallback |
| QA-CHANNEL-03 | [x] | [ ] | Friendly Community 404/501 explanation | `1db3a6b6`, `1de2d71d` | **Server diagnostic open**: `/channel/posts` is in upstream `v1.17.1`; deployed endpoint or reverse proxy should be checked |
| QA-DETAIL-01 | [x] | [ ] | Description excerpt opens full text in a Liquid Glass popup | `f79642d1`, `f46642c1` | Prevent outer scrolling from skipping to related videos; focus and Back regression tests |
| QA-COMMENTS-01 | [x] | [ ] | Preserve pagination button focus while loading comments/replies | `f79642d1` | Confirm on hardware, particularly last page |
| QA-CONTENT-01 | [x] | [ ] | Enable End Screens setting once implemented | `934fbcf7` | Setting now controls visible end-screen cards; hardware validation pending. |
| QA-BLOCK-01 | [x] | [ ] | Visible video/channel name in blocking confirmation | `75f65f2e`, `63ec7695` | System confirmation title explicitly visible |
| QA-BLOCK-02 | [x] | [ ] | Blocked name and short ID instead of full URL | `75f65f2e`, `1c1833c6` | TypeType 1.17.1 does not persist video titles; locally remembered for new Apple TV blocks, ID fallback for old/remote blocks |
| QA-BLOCK-03 | [x] | [ ] | Glass unblock acknowledgement on the row before delayed removal | `1c1833c6` | Entry remains visible ~1.8s before disappearing |
| QA-BLOCK-04 | [x] | [ ] | Explain keyword rules in Settings | `1c1833c6` | Case-insensitive matches in **video titles**, not channel names |
| QA-PLAYER-01 | [x] | [ ] | Short playback history-off notice in four languages | `934fbcf7` | Existing resume/progress semantics unchanged |

**Still awaiting representative live-server samples:** public playlist search hits,
podcasts, courses, comment images and voice replies, and global blocked entries.
CI covers contracts, but does not prove the presence of these upstream data.

**Latest code under verification:** `63ec7695` —
[GitHub Actions run #43939056877](https://github.com/bernhy/TypeType-tvOS/actions/runs/43939056877).
Previous combined run `46250e98` passed all three builds and 239 unit tests
(6 skips), but had three UI test failures. The follow-up updates the changed
UI flow assertions and popup accessibility before final verification.

## Automated verification

- **Confirmed passing:** [tvOS workflow #43915106174](https://github.com/bernhy/TypeType-tvOS/actions/runs/43915106174) on code commit `a04f4937c1abc4ccbb4bb936479a1991026cd736` (2026-11-16).
- Xcode 26.2: Debug simulator, Debug unsigned Apple TV device and Release unsigned Apple TV device builds **passed**.
- **239 unit/contract tests, 0 failures (6 skips)**; **38 UI tests, 0 failures**.
  All new comment API wire/HTML tests, the two previously failing API assertions,
  and the existing remote-scrollable description UI regression test passed.
- CI passing means simulator/API test verification; authentication, audio routing
  and comment-image behavior should additionally be checked against a real
  TypeType instance on physical Apple TV.
- No player media path changes were needed to render comments. The comments
  area is read-only, and voice audio is downloaded from the server with the
  existing account credential rather than leaking tokens to external URLs.

## Prior completed baseline work

- Compact playlist and favorite badges in thumbnail metadata: `13b21db8` (follow-up `dad2969d`).
- Playlist picker shown over existing video UI: `0e6a4f0`.

## API audit notes

- The OpenAPI contract does **not** exhaustively reflect server `SettingsItem`.
  Cross-check Kotlin `SettingsItem` and actual handlers before assuming a field is unsupported.
- Do not equate local Apple TV saved accounts with server user profiles.
- Keep track of server responses with HTTP 202/409 and structured error codes;
  no silent conversion of transient playback problems to permanent video failure.
