# Player OSD — Liquid Glass Concept B (prototype)

## Branch and intent

First implementation of the user's preferred **Concept B**:
focusable tvOS control surface, channel-branded information (no TypeType
logo in the info tile), Apple-like scrubbing and right-hand direct popups.

This is an *experimental UI branch*. Leave `main` untouched until the
real Apple TV review confirms visibility, Siri Remote focus, and gestures.
No changes were made to SABR parser, A/V renderer, seek preroll, buffering,
session recovery, or TypeType account APIs.

## Controls

- OSD hidden: remote touch/select reveals the controls; left/right
  continue to skip by the configured interval, Play/Pause is preserved
- OSD visible: tab-focusable buttons for Back/Play/Forward, Video,
  Audio, Subtitles and Settings. The track is a custom tvOS focus target
  because SwiftUI Slider / DragGesture are unavailable on tvOS
- Track: move left/right on the focused seek track to preview in configured
  skip intervals, click Select to perform one seek. UIKit pan recognizer
  also attempts continuous Siri Remote touch scrubbing (device validation
  required). SponsorBlock segments are drawn from *actual* server times
- Back: first dismisses the visible OSD. If a popup is open, Back closes
  the popup. The video is exited only when the OSD is hidden
- Top-right native notifications are unchanged; the existing
  `typetype.playerNoticeSeconds` key governs their display duration
- Settings popup: skip seconds `typetype.skipSeconds`, OSD timeout
  `typetype.osdSeconds` (0 disables auto-hide), notice seconds, debug
  codec/buffer visibility `typetype.osdDebug`. These same values live
  under the main Device Settings
- Header: title, publisher/channel and real channel avatar when supplied,
  views and publication information when present. Time display can switch
  between elapsed/remaining and wall clock/expected end via top-right control

## Deliberately incomplete in the first prototype

- The existing TypeTypeTV StreamInfo/SabrBootstrap models currently contain
  SponsorBlock segments, but not independent chapter titles/preview storyboard
  descriptions. SponsorBlock chapter-category segments are marked if supplied;
  **no chapter titles or fabricated preview-thumbnail imagery** is displayed
- Real TypeType preview image/storyboard and chapter metadata integration
  should use verified server JSON fields or endpoints, with bounded
  thumbnail fetch/caching and without starting a second SABR extraction
- The second Siri Remote touch-to-toggle-time interaction needs hardware
  testing. The prototype includes a visible time-mode button as an
  accessible fallback
- Native tvOS focus movement, the UIKit pan adapter, text truncation and
  automatic hiding are not guaranteed by simulator tests alone

## Test plan on Apple TV

1. Open a long H.264/AAC video with known metadata and avatar; confirm top
   tile shows the channel instead of the TypeType branding and includes
   publication/views where available
2. Check the normal/clock time toggle; follow changing time labels while
   the video plays
3. Focus seek bar, move ±10 seconds and Select; then touch-scroll on
   Siri Remote and commit; no seek should happen during a mere preview
4. Check Video, Audio, Subtitles, Settings popups individually; Back should
   return to the OSD, then close the OSD, then exit playback
5. Change skip interval, notification lifetime, OSD lifetime and debug info;
   exit/reopen the app and confirm values persist in global Device Settings
6. Confirm subtitles, SponsorBlock skip, end screens, buffering, and pause
   don't regress

CI: use the PR check for tvOS simulator + device Debug/Release compilation,
unit and UI suites. The existing `main` baseline had two unrelated flaky UI
focus assertions in GitHub CI before this branch was created.
