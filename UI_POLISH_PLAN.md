# tvOS UI polish: experiment plan

Status: **first experimental implementation** in `feat/tvos-ui-polish`. All effects are device-local opt-ins and default to the prior look. Open Settings → Device → GUI experiments (also available directly in the Settings rail). Do not merge until real Apple TV review. See `TypeTypeTV/TVUIExperiments.swift`.

## Principles

- Prefer native SwiftUI/tvOS focus and motion APIs; use UIKit only if native SwiftUI presentation cannot isolate the artwork as needed.
- Preserve the TypeType dark/red visual identity and existing Siri Remote semantics. Never let decorative animation change focus targets or navigation.
- In `VideoCard`, preserve full-image `.fit`, the 1.065 whole-card focus scale until deliberately replaced, the existing duration badge visual size, progress bar, rounded corners, and focus return after details.
- Keep the global sidebar and Settings rails' stable-size focus pills; never re-enable system focus effects globally. Existing `TVRailButtonStyle` and `.focusEffectDisabled(true)` are intentional.
- Avoid heavyweight visual effects in video playback and don't alter the SABR/decoder pipeline.
- Prefer state-driven transitions, and honor `@Environment(\.accessibilityReduceMotion)`; test on Apple TV 4K first generation as well as newer Apple TV devices (Liquid Glass appearance differs).
- Never assume focus/parallax APIs behave identically in the simulator and on actual Siri Remote hardware.

## Candidates

| ID | Area | Test | Implementation candidates | Priority |
| --- | --- | --- | --- | --- |
| A | SponsorBlock | Pop in/out on appearance and dismissal; no focus theft | `.transition(.asymmetric(...scale + opacity...))` with `.spring` and explicit visibility state, fade for reduced motion | First |
| B | Video grids | Native tvOS glint/tilt/lift and shadow on focused artwork, no crop or badge inflation | SwiftUI `.hoverEffect(.highlight)` scoped to thumbnail, compare with `.buttonStyle(.card)`, UIKit `UIImageView.adjustsImageWhenAncestorFocused` as fallback | First |
| C | Brief notifications | Small non-blocking toast, slide/fade/bounce for success and recoverable errors | Shared transient overlay component; no automatic focused button | First |
| D | Section and detail transitions | Subtle crossfade/move, optionally matched-geometry hero thumbnail; restore focus | `AnyTransition`, `matchedGeometryEffect` / navigation transitions where compatible | Second |
| E | Icons and status | Brief SF Symbols bounce/pulse on significant actions | `.symbolEffect`, `.contentTransition` | Second |
| F | Backgrounds | Delicate artwork-driven gradients/blur for video detail only | Background material or restrained blur, avoid full-screen animated gradients | Second |
| G | Loading | Skeleton placeholders only for true loading states | `redacted(reason: .placeholder)`, simple pulse if enabled | Later |
| H | Sidebar | Consider *only* gentle section preview transitions, not motion or focus changes to navigation controls | Existing `navigationAnimations` plus small opacity transition | Later |

## Existing code and risk boundaries

- `TypeTypeTV/TVSponsorBlockNotice.swift`: currently an instantly mounted Capsule, with Skip focus acquired in `.task`. Parent is `SabrPlayer.swift` and re-renders through `TimelineView`.
- `TypeTypeTV/BrowseView.swift`: `VideoCard` currently applies custom 1.065 scale/shadow to the whole card, while the duration badge counter-scales. `NavigationLink` explicitly disables native focus effects; enabling a native effect requires a *scoped* experiment, not a global removal of the disablement.
- `TVRailFocusStyle.swift` and `BrowseView.swift`: custom rail focus is carefully calibrated after past navigation regressions. Leave unchanged in early experiments.
- `VideoDetailView.swift`: existing Back/focus restoration is sensitive to scrolling; first test transitions without altering `NavigationStack` focus behavior.

## Real-device review checklist

1. Cold-launch first recommendation receives focus; Right and Select from the left sidebar enter content exactly once; Back never quits unexpectedly.
2. Scrolling deep into Home/Subscriptions and returning from details restores the same thumbnail.
3. Fast Siri Remote directional clicks and touchpad swipes show no stuck focus, unwanted glow, doubled scale, clipped artwork, or cut-off text/badges.
4. SponsorBlock overlay appears and disappears smoothly without delaying/dropping Skip or Back.
5. Open/close player and options rapidly; focus remains on the intended actionable control.
6. Compare first-generation Apple TV 4K and later devices: native Liquid Glass focus effects are only on second-generation 4K and later; preserve a readable fallback.
7. Compare Reduce Motion enabled/disabled; eliminate parallax/bounce in reduced-motion mode.
8. Observe frame pacing in playback, including high-resolution clips. Animation must not cause A/V renderer stalls.
9. Maintain no unexpected background networking, no account changes, and no generated project files in Git.

## API reference

- https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui
- https://developer.apple.com/documentation/swiftui/focus
- https://developer.apple.com/documentation/swiftui/hovereffect
- https://developer.apple.com/documentation/uikit/uiimageview/adjustsimagewhenancestorfocused
- https://developer.apple.com/documentation/uikit/uifocusanimationcoordinator
- https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/swiftui/transition
- https://developer.apple.com/documentation/swiftui/zoomnavigationtransition (not supported on tvOS; local detail-header zoom instead)
- https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
