# TypeType tvOS – implementation status

> The status of tvOS API parity is tracked in Git. Update this file **in the same commit**
> that changes an item. Mark a completed item `[x]` and include the implementing commit
> SHA in the **Completed in** column. Do not mark anything done until it is implemented
> and its tests/build are verified. Track partially implemented items honestly.

## Scope and conventions

- Reference: TypeType Server, Android, and Frontend **main** branches (2026-11-16).
- `[ ]` means outstanding; `[x]` means implemented. Sub-steps can be checked separately.
- Link source changes via commit SHA, not a date-only note. Put dependencies and
  known API-version limitations in the Notes column.
- Distinguish a setting stored via `/settings` from an effect actually applied to tvOS.

## Planned work

| ID | Status | Feature | Completed in | Notes |
| --- | --- | --- | --- | --- |
| API-01 | [ ] | Robust API errors: optional codes, request IDs, Retry-After, stable classifications | — | Treat transient and permanent failures differently; do not corrupt SABR recovery |
| SEARCH-01 | [ ] | `/search/filters`: content filters, grouped filters, sort | — | TV remote controls |
| SEARCH-02 | [ ] | Paginate search with `nextpage`; corrected search hints | — | Keep scroll/focus stable |
| SEARCH-03 | [ ] | Display/search channel and public playlist results | — | Navigable result types |
| CHANNEL-01 | [ ] | Channel video sorting: latest / popular / oldest | — | `/channel?sort=` |
| CHANNEL-02 | [ ] | Channel playlists and public playlist playback | — | Separate server playlists from user-owned playlists |
| CHANNEL-03 | [ ] | Channel Community posts (text/images/polls/videos) | — | Handle unknown post types gracefully |
| CHANNEL-04 | [ ] | Channel podcasts and courses | — | Capability-dependent |
| BLOCK-01 | [ ] | View and remove blocked channels/videos in Settings | — | Existing block actions must remain functional |
| BLOCK-02 | [ ] | Manage blocked title keywords in Settings | — | `/blocked/keywords` |
| DETAIL-01 | [ ] | Related videos from `relatedStreams` on detail page | — | Honor hideRelatedVideos |
| CONTENT-01 | [ ] | Honor hideContinueWatching and hideHomeRecommendations | — | Distinct sections, not just hide all |
| CONTENT-02 | [ ] | Honor hideShorts, hideSubscriptionLiveStreams, hideMembersOnlyContent | — | Server metadata where available |
| CONTENT-03 | [ ] | Honor hideRelatedVideos, hideEndScreens, hideComments | — | Apply wherever feature is presented |
| CONTENT-04 | [ ] | Visibly explain disabled watch-history recording at playback start | — | Existing progress remains displayable; no new progress written |
| CONTENT-05 | [ ] | Startup landing, DeArrow, other content settings parity | — | Separate API/data pipeline |
| SETTINGS-01 | [ ] | Other account playback settings (autoplay, speed, audio only etc.) | — | Avoid destabilizing SABR |
| PROFILE-01 | [ ] | Integrate server account profiles under locally saved accounts | — | `/profiles` is user-scoped, not admin |
| COMMENTS-01 | [ ] | Comments/replies with images and voice replies on video detail | — | Keep in-player UI minimal |
| ACCOUNT-01 | [ ] | Notification and recommender features, backup/imports | — | Lower priority |
| API-02 | [ ] | Capability gating via `/instance` and audit unused fields | — | OpenAPI is manually maintained |

## Prior completed baseline work

- Compact playlist and favorite badges in thumbnail metadata: `13b21db8` (follow-up `dad2969d`).
- Playlist picker shown over existing video UI: `0e6a4f0`.

## API audit notes

- The OpenAPI contract does **not** exhaustively reflect server `SettingsItem`.
  Cross-check Kotlin `SettingsItem` and actual handlers before assuming a field is unsupported.
- Do not equate local Apple TV saved accounts with server user profiles.
- Keep track of server responses with HTTP 202/409 and structured error codes;
  no silent conversion of transient playback problems to permanent video failure.
