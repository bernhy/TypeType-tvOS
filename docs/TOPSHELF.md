# TypeType-tvOS: Top Shelf (experimental)

The feature branch adds a native **TVTopShelfContentProvider** extension. It
shows the five newest *eligible* items from the existing **Ansehen fortsetzen**
rail, using 16:9 / HDTV thumbnails, titles and playback progress. Tapping
opens the matching video detail page.

## Data flow and performance

- Home continues using its existing `/history`, batch progress and
  `TVContinueWatchingPolicy` (started, unfinished, known duration,
  account-configured watched threshold; 90% when the setting is absent).
- Only an actual change to the first five items, their thumbnails, or their
  positions schedules snapshot export. Focus and scrolling do not schedule it.
- The app locally caches up to five JPEG thumbnails for the extension, using
  its existing authenticated TLS session if necessary. Initial export can
  download up to five **images**, with fallback requests if an image source
  is unavailable; there are no extra video/history API calls. Cached URLs
  can be reused, and the disk cache is bounded to 24 JPEGs.
- The extension does no network or image decoding. It only loads a small JSON
  snapshot and already prepared local files.
- No access token, refresh token, user cookie or password is copied to the
  snapshot. Deep links contain only an opaque key and are accepted by the app
  for the matching account scope and server.
- On sign-out, server change, or household profile switch, the app clears
  the published list to prevent showing a previous account's activity.
- Empty/new installations show the app's existing static Top Shelf artwork.

## Important: Apple App Groups signing

For an app extension to display private, locally cached data while the app
is closed, both targets must have access to the **same App Group**.

This experiment ships a **placeholder** `group.org.example.typetype.tv` in
`project.yml` on both targets. You must replace it with an App Group
registered for your own Apple team, and sign both the app and the embedded
`TypeTypeTVTopShelf` extension using that team. Also use matching bundle IDs
for the app and extension (the extension should be a child ID of the app).

**Xcode Personal Team/free provisioning may not permit App Groups.** The
extension can build unsigned in CI, but *functioning shared data on a physical
Apple TV requires entitlement support in your provisioning profiles*. Do
not bypass this restriction by copying authenticated URLs or credentials into
an unprotected location. If Personal Team rejects the capability, the dynamic
five-video shelf cannot be validated with that signing setup.

Run `xcodegen generate` after checking out the branch. Before using this on
a physical Apple TV, inspect Signing & Capabilities for both targets.

## Validation

1. Install the signed app and launch Home with a signed-in account that has
   five unfinished VODs and known positions.
2. Move TypeType into the Apple TV's top row; highlight the app icon and
   inspect the Top Shelf.
3. Confirm five landscape images, titles, and progress. Selecting a poster
   should open the corresponding detail page.
4. Complete a video beyond 90%, return Home, and verify that it disappears.
5. Switch household profiles or disconnect the server; the former user's
   activity must not remain in Top Shelf.
6. Compare the app's launch and Home scroll performance with main.

All changes remain isolated in the feature branch until user approval.
