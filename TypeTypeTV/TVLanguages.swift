import Foundation
import SwiftUI

/// Language packs are resources, not cases in a fixed enum. Adding a
/// localization to Localizable.xcstrings makes it appear automatically.
enum TVLanguages {
    static let preferenceKey = "typetype.uiLanguage"
    static let defaultCode = "de"
    static let followSystem = "system"

    static var available: [String] {
        let found = Bundle.main.localizations
            .filter { $0 != "Base" && $0 != "root" }
        return Array(Set(found + [defaultCode])).sorted {
            if $0 == defaultCode { return true }
            if $1 == defaultCode { return false }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    static func locale(for choice: String) -> Locale {
        choice == followSystem ? .autoupdatingCurrent : Locale(identifier: choice)
    }

    static func nativeName(_ code: String) -> String {
        let ownLocale = Locale(identifier: code)
        let name = ownLocale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: ownLocale) + name.dropFirst()
    }

    static var currentChoice: String {
        UserDefaults.standard.string(forKey: preferenceKey) ?? followSystem
    }

    static var activeLanguage: String {
        if currentChoice == followSystem {
            let preference = Locale.preferredLanguages.first ?? defaultCode
            let exact = available.first { $0.caseInsensitiveCompare(preference) == .orderedSame }
            if let exact { return exact }
            return available.first { preference.lowercased().hasPrefix($0.lowercased() + "-") }
                   ?? defaultCode
        }
        return available.contains(currentChoice) ? currentChoice : defaultCode
    }
}

/// For error messages and model labels outside SwiftUI's localizable Text.
/// SwiftUI views should prefer Text("semantic.key") and the locale environment.
enum TVL10n {
    static func value(_ key: String, language: String? = nil) -> String {
        let code = language ?? TVLanguages.activeLanguage
        if let url = Bundle.main.url(forResource: code, withExtension: "lproj"),
           let resourceBundle = Bundle(url: url) {
            let translated = resourceBundle.localizedString(forKey: key, value: key, table: "Localizable")
            if translated != key { return translated }
        }
        // German fallback is always available for incompletely translated packs.
        if code != TVLanguages.defaultCode,
           let url = Bundle.main.url(forResource: TVLanguages.defaultCode, withExtension: "lproj"),
           let german = Bundle(url: url) {
            return german.localizedString(forKey: key, value: key, table: "Localizable")
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func formatted(_ key: String, _ args: CVarArg...) -> String {
        String(format: value(key), locale: TVLanguages.locale(for: TVLanguages.activeLanguage),
               arguments: args)
    }
}
