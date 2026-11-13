# Multilingual localization in TypeType-tvOS

TypeType-tvOS uses Apple's current standard localization format: one String Catalog (TypeTypeTV/Localizable.xcstrings).
Source language is German (de). At present English (en), French (fr) and Spanish (es) have translations for the common UI. More languages require no Swift switch statements.

## Add another language

1. Open TypeTypeTV/Localizable.xcstrings in Xcode's String Catalog editor.
2. Click + and choose any language or regional variant such as it, nl, pt-BR or ja.
3. Translate each semantic key and keep variable placeholders (%@ and %d) intact. Use plural variants for languages that need them.
4. Build the tvOS app. The compiled localization becomes available automatically in the in-app language picker; the list is read from Bundle.main.localizations.
5. Run python3 scripts/check_localizations.py and inspect the screenshots produced by GitHub Actions for text clipping and directional-focus issues.

Xcode can also Export Localizations and Import Localizations for translators working with XLIFF / .xcloc packages. The checked-in String Catalog remains the source of truth.

## Conventions

- Do not embed human-language UI copy in production Swift files. Use semantic keys such as home.recommendations or error.serverAddress.
- For SwiftUI controls use Text("home.recommendations"), Label("nav.home", systemImage: "house"), etc. The locale environment performs the lookup.
- For non-view values, errors and interpolated strings, use TVL10n.value("error.serverAddress") or TVL10n.formatted("common.videoCount", count).
- User-provided video names, channel names and URLs are not translated.
- Codec names, protocol tokens, HTTP status codes, file names and units remain literal technical tokens.
- A new language requires an app rebuild, not an update to the TypeType server.
- German is the default for this project, and a System language option follows the Apple TV language setting.
- Missing translations may fall back to German; complete human review and plural rules are still needed before publication.

## Verification

CI validates source translations, missing referenced keys and matching printf placeholders. The tvOS Simulator UI tests include English Settings, French Home and Spanish Search snapshots.
Test on a real Apple TV for long labels, focus behavior, accessibility, date/number formatting, and right-to-left languages when they are added.
