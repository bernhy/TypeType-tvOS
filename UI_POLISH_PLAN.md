# tvOS GUI polish — remaining experiments

This branch contains only the **five effects not yet approved** for stable. It is a **draft PR**, not ready for merging. It remains based on and compatible with the latest `main`.

## Promoted into main

The following are now regular TypeType behavior, not experimental settings:

- Existing **1.065× whole-card thumbnail zoom**, plus an **artwork-only light reflection** on focus. Artwork still uses `.fit`, remains uncropped, and the duration badge retains its original size.
- **Slide + fade** for SponsorBlock notices and the player options overlay.
- **Fade in/out** for short action feedback after video context-menu operations.
- **Liquid Glass** on SponsorBlock and player option surfaces.
- Video detail background remains the **original standard** appearance (no blur or cinematic color treatment).
- Library's secondary navigation rail is now **black** like Settings. The global main rail remains dark gray.

The streamer/SABR/video decoder was not changed by this GUI work.

## Remaining options and how to see them

Open **Settings → Device → GUI experiments** or select **GUI experiments** directly in the Settings category rail.

| Option | Location in the app | Trigger and limitations |
| --- | --- | --- |
| Page transitions: Standard / Crossfade / Shift | Home, Subscriptions, Library, Search and other pages | Focus the global left sidebar and switch between sections. Only the *page content* animates; the sidebar itself does not slide away. SwiftUI/tvOS may not visibly apply a transition to every navigation container change. |
| Video detail header: Standard / Fade / Zoom | Large artwork behind the video title on video detail | Select a thumbnail to open a *new* detail screen. The artwork fades or zooms in once when first mounted. Nothing continuously moves after it has appeared. Not a shared-element thumbnail zoom. |
| Animated action symbols: Off / On | Heart and Watch Later bookmark buttons in the video detail controls | Activate/deactivate Favorites or Watch Later (logged-in account with an enabled button). Their icons briefly bounce. Not part of the thumbnail list or playback HUD. |
| Loading indicator: Standard / Cards / Pulsing cards | Home recommendations and history, Library grid, Subscriptions feed | Refresh/re-enter a page when data must be fetched; animation exists **only while loading**. A fast or cached response may show no difference. Does not throttle the server. |
| Sidebar reveal: Standard / Fade | **Global** left TypeType icon rail labels | Navigate into the left icon rail, then leave it for content. The rail expands from 56 to 214 points, but remains *visible* in both modes; only label opacity/timing changes. |

The code contains help text under each option in German, English, French and Spanish. There are no longer popup/toast preview buttons or focus/glass/background selectors: those are promoted or left at Standard. The **Reset** button resets only the five remaining experimental settings.

## Test safety

1. Exercise remote Right, Select, Up, Down, Left, and Back from the global rail and the settings rail. Do not change the previously fixed focus restoration.
2. Repeat the test with Reduce Motion enabled; decorative movement should be reduced.
3. Compare actual Apple TV behavior: simulator focus treatment and effects may differ.
4. No new background network requests, server/account settings, or stream decoding logic.
5. Only merge the remaining experiments when explicitly approved.

See `TypeTypeTV/TVUIExperiments.swift` for the experiment settings and `TypeTypeTV/TVStableVisualEffects.swift` for the approved, shared effects.
