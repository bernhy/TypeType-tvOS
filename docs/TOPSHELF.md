# TypeType-tvOS: Top Shelf (experimental)

Native **TVTopShelfContentProvider** extension shows up to five unfinished videos
from **Ansehen fortsetzen** on the tvOS Home screen, with landscape posters,
progress indicators and a link to each video's detail page.

## Data flow and performance

- Home uses its existing /history and batch progress results. No new history,
  saved-position, or recommendation request is made for Top Shelf.
- The publisher retains up to 24 already-loaded local resume candidates, but
  publishes at most five eligible videos. Finishing a video can reveal the next
  cached candidate without reloading /history.
- Home triggers publication on changes to membership or card metadata, **not**
  on every position update or focus/scroll event.
- SABR and HLS use their existing forced progress checkpoints (pause, stop,
  background); watched/unwatched actions also signal the publisher. No new
  timer, per-card subscription, or network poll is introduced.
- A progress-only change with already prepared images writes a small atomic
  JSON snapshot synchronously, then calls tvOS Top Shelf invalidation. It
  neither starts an asynchronous image task nor downloads any artwork.
- When membership changes, the new list is also written immediately, before
  any missing posters are downloaded; images fill in asynchronously.
- The first export or a changed poster may download an image. The app reuses
  existing JPEGs by matching URL and cached file, and checks *all* candidate
  fallback files before attempting another download. The disk cache is bounded
  to 24 JPEGs. The extension itself does no network or image decoding.
- An initial Home load does not replace a valid snapshot with an empty one
  while /history is still pending (important for cold-start deep links).
- Each async export has a generation guard. Clear/account switch cancels
  unfinished work; cancelled image decoding cannot repopulate shared files.
- Failed writes are not treated as successful publications; a later event can
  retry. Diagnostics are Debug-only, use the prefix "TypeType TOPSHELF" and
  contain no URLs, tokens, account names or video titles.
- Progress and watched decisions use the same account-configured threshold as
  Home (90% fallback). Hidden Continue Watching does not publish new entries.

## Data protection and deep links

- No access token, refresh token, user cookie or password is copied to the
  JSON snapshot. Poster assets are local shared-container JPEG files; external
  HTTPS thumbnail URLs are only an extension fallback.
- Deep links contain an opaque SHA-256 video key, **not** the video URL.
  The app accepts only the expected scheme, host and single key query, and
  checks the current server/account scope against the saved snapshot.
- On sign-out, server change or household profile switch, the app cancels
  publishing and clears the saved list and local images.
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
  cancelling any ongoing poster jobs. Turning ON republishes only already
  loaded history, without a new server request. Inactive profiles' toggles
  never change the active account's Top Shelf.
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
- Failure of the existing Home history request hides any previous posters.
  The local JPEG cache is retained for efficient recovery. On a successful
  authenticated request, publication can resume without extra API calls.
- The extension is intentionally network-free: if the server goes offline
  while TypeType is entirely closed, the extension cannot detect that outage
  immediately. The fallback takes effect when the app detects a failed
  existing request, not by polling from the Home screen.
- No account IDs, personally configured App Groups or server addresses are
  hardcoded in this public repository.

### Diagnosing Top Shelf on a physical Apple TV

If the static logo remains despite an opted-in account and resume videos,
look for `TypeType TOPSHELF` in the **app** console. In a Debug build,
a failed write now includes its stage and the error domain/code without
printing paths, group identifiers, URLs or account details. In particular,
an unauthorized App Group can yield a non-nil container URL but still be
unwritable. Compare the built app's `TopShelfAppGroupID` in `Info.plist`
with the **signed** `com.apple.security.application-groups` entitlement;
the embedded extension must use the same group. Running
`xcodegen generate` from the public `project.yml` regenerates generic
`org.example` placeholders, so make required private signing changes
locally before generating the Xcode project.

On failed snapshot writes the publisher does not attempt poster downloads,
because the extension cannot display the result. When writing succeeds,
the existing async image cache and HTTPS fallback remain unchanged.

### One-time DEBUG storage probe for real Apple TV hardware

In Debug builds (not the simulator UI-preview fixtures), TypeType performs
one nonblocking storage probe per app process at launch. It tests the normal
app's `Application Support` as a control, then the shared App Group root and
`Library/Application Support` inside that group. Each location is tested with
a uniquely named small file using both **direct** and **atomic** writes and a
read-back, then the diagnostic files are deleted. No existing Top Shelf
snapshots, thumbnails or user settings are modified.

The app also writes a random challenge to `UserDefaults(suiteName:)`. The
extension tries to read and acknowledge that exact challenge when tvOS calls
`loadTopShelfContent` (for example, when the first-row TypeType app is
highlighted on the Apple TV Home screen). On returning to the app, an
`extension acknowledgement=MATCH` message confirms **cross-process** sharing,
which an app-only read-back would not prove.

Filter the device log for `TypeType TOPSHELF PROBE`. Example results:

- `app-support direct write=PASS read=PASS`: private sandbox works.
- `group-root direct-write failed domain=NSCocoaErrorDomain code=513`:
  writing at the shared container root is denied.
- `group-library-support atomic write=PASS read=PASS`: a standard shared
  support directory can be used instead (pending a separate fix).
- `suite localRead=PASS flush=PASS marker=...` and
  `extension acknowledgement=MATCH`: shared preferences work across processes.

All logging omits paths, configured App Group identifiers, account names,
server addresses, tokens and content titles. The only printed marker is the
first eight characters of a random UUID. The probe requires no network,
timers or user interaction, apart from visiting the Apple TV Home screen
to let the extension load. It does **not** change the production snapshot
storage location; do not treat it as a fix until hardware results are reviewed.
Release builds contain none of this probe.

## App Groups signing

For an app extension to display locally cached data while the app is closed,
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
   should show up to five posters, titles and progress.
3. Select a poster when the app is closed. It must open the matching detail
   page; different server or profile state must reject a stale link.
4. Watch a video, use the Apple TV Home button **without returning to TypeType
   Home**, then check Top Shelf progress. Also test pause and normal Back.
5. Finish a video past the configured completion threshold. It should disappear
   and the next cached candidate should take its place.
6. Change watched/unwatched via detail; test a fast account/profile switch.
   No previous account's data should remain.
7. Repeat with cached images and (if appropriate) temporarily unavailable
   thumbnails: progress-only updates must not cause repeated downloads.
8. Compare Home navigation/scroll and startup with main; monitor Debug
   `TypeType TOPSHELF` messages for failures.

Changes remain isolated in the feature branch pending validation and approval.
