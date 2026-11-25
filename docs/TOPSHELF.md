# TypeType-tvOS: Top Shelf (experimental)

Native **TVTopShelfContentProvider** extension shows up to five unfinished videos
from **Ansehen fortsetzen** on the tvOS Home screen, with landscape posters,
progress indicators, per-video channel names and deep links to detail pages.

## Data flow and performance

- Top Shelf receives up to five unfinished videos from already loaded Home
  history; up to 24 candidates are kept in memory to fill empty slots.
- A single JSON-encoded value (maximum 64 KiB) in App Group
  `UserDefaults(suiteName:)` contains the complete versioned snapshot.
  Reading and writing `resume.json` was removed after hardware testing showed
  `NSCocoaErrorDomain 513` for both direct and atomic file writes.
- Shared `UserDefaults` cross-process exchange was verified on a physical
  Apple TV through the one-time DEBUG challenge/acknowledgement probe.
  That temporary probe has now been removed.
- No JPEGs or base64 images are stored in shared preferences. The main
  application checks the following public candidates for each *new* poster:
  (1) the original TypeType-provided image through a known public server
  endpoint (including `/api/dearrow/thumbnail` or a supported upstream image
  wrapped in `/api/proxy`), (2) `hqdefault` and then `mqdefault` via
  TypeType's public `/api/proxy`, (3) the same two YouTube URLs **directly**.
  Private account media and arbitrary server paths are never published.
- Publication of the initial snapshot does **not** wait for thumbnail GETs.
  Up to five posters are checked asynchronously, and candidates are tried
  sequentially *per video*. A maximum six-second request timeout applies to
  each image. HTTP 200 and an actual image payload are required; a successful
  HTML page or error placeholder is not a valid thumbnail. Results are kept
  in a small in-memory dictionary for the lifetime of the app. Updated poster
  URLs are published together in one shared snapshot after verification.
- Existing player checkpoints and focus movement never restart verification
  for an unchanged poster. A profile/server change, authentication failure
  or opt-out cancels in-flight jobs and clears their temporary results.
  No new history request, repeat timer, on-focus request or background service
  is introduced. Apple TV may suspend validation when the main app exits;
  cached or already published URLs remain usable by the system.
- A verified image URL is handed to tvOS; both 1x and 2x TVServices traits
  use that same URL. tvOS remains responsible for the final download and its
  own system cache. A successful preflight does not guarantee that a later
  system download cannot fail.
- Normal app thumbnail cards also try `mqdefault` if their original image
  and `hqdefault` fail. Successful images use the existing bounded
  in-memory image cache. Top Shelf uses independent URL-only validation.
- Each video's existing `uploaderName` is stored as optional `channelName`
  in the snapshot. The sectioned Top Shelf row uses one collection per video:
  the video title remains the item title, while the channel appears above it
  as `Ansehen fortsetzen · <Kanalname>`. Missing channel metadata falls back
  to `Ansehen fortsetzen`. The layout is still one horizontal row.
- The native sectioned Top Shelf API does not support separate channel
  avatar icons or thumbnail overlays. A server-generated composite poster
  would be a future option, not part of this change.
- The tvOS Top Shelf extension performs no TypeType API request or token access.
  The OS may fetch public poster images from the supplied TypeType/YouTube
  URLs. The app's *optional* bounded preflight uses existing certificate
  pinning for its own server and never attaches account credentials.
- Home publishes only when candidate membership or metadata changes; normal
  scrolling and focus moves never publish. Pause, stop, background and explicit
  watched toggles reuse existing player checkpoints.
- Shared preference writes are not a cross-process transaction; tvOS may apply
  updates to the extension asynchronously. Each write is a single replaceable
  encoded value, not multiple independently updated video keys.
- On clear, the entire shared value is removed. Sign-out, server change,
  account switch, privacy opt-out and authentication errors invalidate Top Shelf.
- No new timers, history requests or background polling. Thumbnail preflight
  is limited to new candidates and may use network/CPU on a background task.
  There is no image bitmap retained or written in the app group.
- tvOS warns when the defaults database grows to 512 KiB and may terminate
  apps at 1 MiB. The 64 KiB snapshot cap leaves ample room for other settings.

## Data protection and deep links

- No access token, refresh token, user cookie or password is copied to the
  shared snapshot. Poster URLs are restricted to verified public TypeType
  image paths, allowlisted upstream media via the TypeType proxy, or direct
  public YouTube CDN URLs. The entire payload is limited to 64 KiB.
- Deep links contain an opaque SHA-256 video key, **not** the video URL.
  The app accepts only the expected scheme, host and single key query, and
  checks the current server/account scope against the saved snapshot.
- On sign-out, server change or household profile switch, the app stops
  publishing and clears the shared snapshot. There is no JPEG cache to clear.
- Empty/new installations show the app's existing static Top Shelf artwork.

## Per-account Top Shelf privacy switch

- **Einstellungen → Konten** shows a compact Top Shelf on/off switch immediately
  to the left of the existing per-profile **Konto entfernen** action.
  Both controls have independent focus targets. Entry from the Settings
  category rail chooses the profile's remove action; Left moves to Top Shelf
  and a second Left returns to the Settings rail. Up/Down between account rows
  and Right between same-row actions use native tvOS focus movement.
- The choice is local to this Apple TV, separately persisted for each
  combination of server origin and verified household account ID. The
  UserDefaults key is SHA-256-derived, without raw server addresses/account
  names or credentials. **Default OFF** until the user explicitly enables it.
- Only the **currently selected**, verified, opted-in account with a
  successful history request can publish dynamic Top Shelf. All other cases
  show the existing static TypeType logo.
- Turning OFF the active account clears its published snapshot immediately,
  cancelling any ongoing poster checks. Turning ON republishes only already
  loaded history; it may validate public poster URLs but never requests
  additional history. Inactive profiles' toggles never change the active
  account's Top Shelf.
- A successful account switch already clears the old snapshot and local
  progress and verifies the newly active account. Its own opt-in is checked
  before publishing again.
- Removing an individual saved profile or logging it out also removes its
  locally saved Top Shelf permission. Other profiles retain theirs.
- The settings are local to the Apple TV, not synchronized with TypeType
  server preferences or other clients. This is deliberate for a
  homescreen-specific privacy decision.

## Static logo on first launch, sign-out and network errors

- The extension deliberately returns `nil` when no readable snapshot or
  eligible posters exist. tvOS then uses the app's regular static Top Shelf
  artwork; there is no additional image asset or placeholder view.
- A new installation / server setup clears previously published content.
- The existing `/auth/me` check is the gate for personalized Top Shelf:
  missing credentials, guest identity, invalid sessions and disabled per-account
  opt-in are not eligible.
  An empty history also produces static artwork.
- Failure of the existing Home history request clears previous posters.
  On a successful authenticated request, publication can resume without
  extra API calls.
- The extension is intentionally network-free: if the server goes offline
  while TypeType is entirely closed, the extension cannot detect that outage
  immediately. The fallback takes effect when the app detects a failed
  existing request, not by polling from the Home screen.
- No account IDs, personally configured App Groups or server addresses are
  hardcoded in this public repository.

### Debugging on a physical Apple TV

Earlier real-device tests showed denied local file writes (`NSCocoaErrorDomain
513`) to both normal `Application Support` and the shared App Group root.
Shared UserDefaults worked: the Top Shelf extension acknowledged the exact
challenge written by the main app (`extension acknowledgement=MATCH`).

The temporary DEBUG-only filesystem write probe was removed after proving
the shared `UserDefaults` path on physical Apple TV hardware. It no longer
creates error 513 log messages or invokes `synchronize()`.

Check `TypeType TOPSHELF shared preferences updated` in the app log and
then inspect the Apple TV Home screen with TypeType in the first row. If
personal posters do not appear, distinguish whether the extension has read
the snapshot from whether public thumbnail downloads are accessible. The
shared preferences approach does not rely on writable `Caches` or `tmp`.

## App Groups signing

For an app extension to read shared preferences while the app is closed,
both targets require access to the **same App Group**.

The public repository uses placeholder group `group.org.example.typetype.tv`
and matching `org.example.typetype.tv` bundle IDs in `project.yml`. Keep
personal group/team IDs and generated entitlements out of Git. Replace these
values only in a local working copy before using `xcodegen generate`.
Both app and extension must have matching signed App Group capabilities.
Free/Personal Team entitlement support can vary by signing configuration.

The two generated entitlements paths are excluded in `.gitignore`:
`TypeTypeTV/TypeTypeTV.entitlements` and
`TypeTypeTVTopShelf/TopShelf.entitlements`.

## Validation on an Apple TV

1. Build/install the **TypeTypeTV** scheme, not the extension separately.
   Place TypeType in the Apple TV Home screen's first row.
2. Open Home with a signed-in account and unfinished history. The Top Shelf
   should show up to five posters, video titles, channel section labels and progress.
3. Select a poster when the app is closed. It must open the matching detail
   page; different server or profile state must reject a stale link.
4. Watch a video, use the Apple TV Home button **without returning to TypeType
   Home**, then check Top Shelf progress. Also test pause and normal Back.
5. Finish a video past the configured completion threshold. It should disappear
   and the next cached candidate should take its place.
6. Change watched/unwatched via detail; test a fast account/profile switch.
   No previous account's data should remain.
7. Test failing original/DeArrow, proxied hq/mq and direct YouTube artwork.
   The app should choose the next successful URL asynchronously without
   blocking Home. If all sources fail, the initial image may stay blank until
   the source recovers or history refreshes.
8. Compare Home navigation/scroll and startup with main; monitor Debug
   `TypeType TOPSHELF` messages for failures.

Changes remain isolated in the feature branch pending validation and approval.
