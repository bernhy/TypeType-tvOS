# TypeType tvOS – implementation status

> Maintain the API parity checklist in Git alongside feature changes. Link each
> implementing commit in the table below. Mark `[x]` **only when CI and contract
> tests have passed**, then record the implementing SHA in the same status row.
> Since a commit cannot reference its own SHA, update the status in a follow-up
> documentation commit once the feature commit has been verified. Keep partial
> implementations explicitly open.

## Scope and conventions

- Reference: TypeType Server, Android, and Frontend **main** branches (2026-11-16).
- `[ ]` means outstanding or awaiting verification; `[x]` means implemented **and verified**.
- `CI pending` in the Notes means code is committed but tests have not passed yet.
- Record all relevant implementation SHAs even before verification. Keep unimplemented parts open.
- Link source changes via commit SHA, not a date-only note. Put dependencies and
  known API-version limitations in the Notes column.
- Distinguish a setting stored via `/settings` from an effect actually applied to tvOS.

## Planned work

| ID | Status | Feature | Implementation commits | Notes |
| --- | --- | --- | --- | --- |
| API-01 | [ ] | Robust API errors: optional codes, request IDs, Retry-After, stable classifications | `10662f66, af7e3158, fdc8baa9, 474e2d9c` | Code integrated; CI pending. Includes bootstrap-vs-session classification and request IDs. |
| SEARCH-01 | [ ] | `/search/filters`: content filters, grouped filters, sort | `e8400793, e634a0f2` | Code integrated; CI pending. Server-advertised filters and Siri Remote controls. |
| SEARCH-02 | [ ] | Paginate search with `nextpage`; corrected search hints | `e8400793, e634a0f2` | Code integrated; CI pending. Opaque nextpage, correction and suggestion. |
| SEARCH-03 | [ ] | Display/search channel and public playlist results | `e634a0f2` | Code integrated; CI pending. Channels and public playlists have navigable cards. |
| CHANNEL-01 | [ ] | Channel video sorting: latest / popular / oldest | `36c1b554, a7219f6b` | Code integrated; CI pending. Sort not applied to Shorts tab. |
| CHANNEL-02 | [ ] | Channel playlists and public playlist playback | `36c1b554, f5feb683, a7219f6b` | Code integrated; CI pending. Public playlists distinct from own /playlists. |
| CHANNEL-03 | [ ] | Channel Community posts (text/images/polls/videos) | `36c1b554, f5feb683, a7219f6b` | Code integrated; CI pending. Read-only posts incl. images, poll choices and video links. |
| CHANNEL-04 | [ ] | Channel podcasts and courses | `36c1b554, f5feb683, a7219f6b` | Code integrated; CI pending. Courses shown when hasCourses is true. |
| BLOCK-01 | [ ] | View and remove blocked channels/videos in Settings | `db9f5e79` | Code integrated; CI pending. Global blocks intentionally read-only. |
| BLOCK-02 | [ ] | Manage blocked title keywords in Settings | `db9f5e79` | Code integrated; CI pending. Adds, lists and removes user keywords. |
| DETAIL-01 | [ ] | Related videos from `relatedStreams` on detail page | `7315e7f9, 4882e4c3` | Code integrated; CI pending. Honors hideRelatedVideos and filter preferences. |
| CONTENT-01 | [ ] | Honor hideContinueWatching and hideHomeRecommendations | `443554bf, 744bf946` | Code integrated; CI pending. Existing saved history still visible in Library. |
| CONTENT-02 | [ ] | Honor hideShorts, hideSubscriptionLiveStreams, hideMembersOnlyContent | `443554bf, 0931b730, 4882e4c3` | Code integrated; CI pending. Visibility metadata may be unavailable for some provider rows. |
| CONTENT-03 | [ ] | Honor hideRelatedVideos, hideEndScreens, hideComments | `7315e7f9, 4882e4c3` | PARTIAL: related videos obey setting; end screens and comments are not yet rendered at all. |
| CONTENT-04 | [ ] | Visibly explain disabled watch-history recording at playback start | `7315e7f9` | Code integrated; CI pending. HLS/SABR notices; read old progress but suppress new writes. |
| CONTENT-05 | [ ] | Startup landing, DeArrow, other content settings parity | — | Separate API/data pipeline |
| SETTINGS-01 | [ ] | Other account playback settings (autoplay, speed, audio only etc.) | — | Avoid destabilizing SABR |
| PROFILE-01 | [ ] | Integrate server account profiles under locally saved accounts | — | `/profiles` is user-scoped, not admin |
| COMMENTS-01 | [ ] | Comments/replies with images and voice replies on video detail | — | Keep in-player UI minimal |
| ACCOUNT-01 | [ ] | Notification and recommender features, backup/imports | — | Lower priority |
| API-02 | [ ] | Capability gating via `/instance` and audit unused fields | — | OpenAPI is manually maintained |

## Automated verification

- All new feature commits listed above are present on `main`, but no single
  end-to-end tvOS workflow has yet completed for the combined changes.
- Tests for HTTP error handling, search, channel extras and blocked routes:
  `TVServerErrorMappingTests.swift`, `TVAPIWireTests.swift`.
- The CI workflow performs Debug simulator build, Debug and Release device
  compilation, and automated unit/UI tests. Do not infer device behavior solely
  from simulator compilation.

## Prior completed baseline work

- Compact playlist and favorite badges in thumbnail metadata: `13b21db8` (follow-up `dad2969d`).
- Playlist picker shown over existing video UI: `0e6a4f0`.

## API audit notes

- The OpenAPI contract does **not** exhaustively reflect server `SettingsItem`.
  Cross-check Kotlin `SettingsItem` and actual handlers before assuming a field is unsupported.
- Do not equate local Apple TV saved accounts with server user profiles.
- Keep track of server responses with HTTP 202/409 and structured error codes;
  no silent conversion of transient playback problems to permanent video failure.
