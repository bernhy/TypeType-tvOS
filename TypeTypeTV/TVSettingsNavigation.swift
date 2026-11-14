import SwiftUI

/// Mirrors the Android TV settings group rail, while keeping actual Apple TV
/// decoder, remote and buffer controls device-local.
enum TVSettingsGroup: String, CaseIterable, Identifiable {
    case playback, content, device, language, account, instance, about
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .playback: return "play.rectangle"
        case .content: return "square.grid.2x2"
        case .device: return "appletv"
        case .language: return "globe"
        case .account: return "person.crop.circle"
        case .instance: return "server.rack"
        case .about: return "info.circle"
        }
    }
    var titleKey: String {
        switch self {
        case .playback: return "settings.playback"
        case .content: return "settings.groupContent"
        case .device: return "settings.groupDevice"
        case .language: return "settings.language"
        case .account: return "settings.groupAccounts"
        case .instance: return "settings.groupInstance"
        case .about: return "settings.groupAbout"
        }
    }
    var subtitleKey: String {
        switch self {
        case .playback: return "settings.playbackHelp"
        case .content: return "settings.groupContentHelp"
        case .device: return "settings.groupDeviceHelp"
        case .language: return "settings.languageHelp"
        case .account: return "settings.accountHelp"
        case .instance: return "settings.groupInstanceHelp"
        case .about: return "settings.groupAboutHelp"
        }
    }
}

struct TVSettingsCard<Content: View>: View {
    let title: String
    let summary: String?
    @ViewBuilder let content: Content

    init(_ title: String, summary: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text(TVL10n.value(title)).font(.title2.bold())
            if let summary {
                Text(TVL10n.value(summary))
                    .font(.callout)
                    .foregroundStyle(TTTheme.muted)
            }
            Divider()
            content
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .focusSection()
    }
}

/// Focusable read-only rows let the Siri Remote move through long diagnostic
/// reports line by line. ScrollView will scroll the focused row into view,
/// unlike a stack of static Text labels between two distant buttons.
struct TVSettingsInfoRow: View {
    let title: String
    let value: String
    @FocusState private var readingFocus: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(TVL10n.value(title))
                .font(.body)
            Spacer(minLength: 22)
            Text(value).font(.callout.weight(.medium))
                .foregroundStyle(readingFocus ? .white : .white.opacity(0.9))
                .lineLimit(3)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .focusable(true)
        .focusEffectDisabled(true)
        .focused($readingFocus)
        .accessibilityElement(children: .combine)
    }
}

struct TVSettingsReadableText: View {
    let key: String
    @FocusState private var readingFocus: Bool

    var body: some View {
        Text(TVL10n.value(key))
            .font(.callout)
            .foregroundStyle(readingFocus ? .white : TTTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .focusable(true)
            .focusEffectDisabled(true)
            .focused($readingFocus)
    }
}

/// A focusable, accessible choice row with a visible title and the selected
/// value on the right. tvOS .menu Pickers otherwise hide their label and
/// display only a bare value, unlike TypeType Android's settings rows.
struct TVSettingsMenuRow<Value: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder let options: Options

    init(_ title: LocalizedStringKey, selection: Binding<Value>,
         @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        HStack(spacing: 24) {
            Text(title).font(.body)
            Spacer(minLength: 20)
            Picker(title, selection: $selection) {
                options
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
