import SwiftUI

/// Mirrors the Android TV settings group rail, while keeping actual Apple TV
/// decoder, remote and buffer controls device-local.
enum TVSettingsGroup: String, CaseIterable, Identifiable {
    case playback, sponsor, content, device, language, account, instance, about
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .playback: return "play.rectangle"
        case .sponsor: return "forward.end.fill"
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
        case .sponsor: return "sponsor.title"
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
        case .sponsor: return "sponsor.description"
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(readingFocus ? Color.white.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(readingFocus ? Color.white.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
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
    let focus: FocusState<String?>.Binding?
    let focusTarget: String?
    let onMoveLeft: (() -> Void)?
    @FocusState private var pickerFocus: Bool
    @ViewBuilder let options: Options

    init(_ title: LocalizedStringKey, selection: Binding<Value>,
         focus: FocusState<String?>.Binding? = nil,
         focusTarget: String? = nil,
         onMoveLeft: (() -> Void)? = nil,
         @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.focus = focus
        self.focusTarget = focusTarget
        self.onMoveLeft = onMoveLeft
        self.options = options()
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            options
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .onMoveCommand { direction in
            if direction == .left { onMoveLeft?() }
        }
    }

    var body: some View {
        HStack(spacing: 24) {
            Text(title).font(.body)
            Spacer(minLength: 20)
            if let focus, let focusTarget {
                picker.focused(focus, equals: focusTarget)
            } else {
                picker.focused($pickerFocus)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .onChange(of: selection) { _, _ in
            // Returning from a tvOS Picker menu should restore the very
            // Picker that opened it, not the Settings group to its left.
            Task { @MainActor in
                await Task.yield()
                if let focus, let focusTarget {
                    focus.wrappedValue = focusTarget
                } else {
                    pickerFocus = true
                }
            }
        }
    }
}


/// tvOS's default Toggle renders only ON/OFF text. This focusable button
/// keeps the native remote Select interaction while drawing a recognisable
/// sliding switch. The focus rectangle remains inside the settings card.
struct TVSettingsSwitchRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    let focus: FocusState<String?>.Binding?
    let focusID: String?
    let accessibilityID: String?
    let onMoveLeft: (() -> Void)?

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>,
         focus: FocusState<String?>.Binding? = nil,
         focusID: String? = nil, accessibilityID: String? = nil,
         onMoveLeft: (() -> Void)? = nil) {
        self.title = title
        self._isOn = isOn
        self.focus = focus
        self.focusID = focusID
        self.accessibilityID = accessibilityID
        self.onMoveLeft = onMoveLeft
    }

    private var switchButton: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 22) {
                Text(title)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(isOn ? TTTheme.accent : Color.white.opacity(0.27))
                    .frame(width: 72, height: 38)
                    .overlay {
                        Circle()
                            .fill(.white)
                            .frame(width: 30, height: 30)
                            .shadow(color: .black.opacity(0.25), radius: 2)
                            .offset(x: isOn ? 17 : -17)
                    }
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                focus?.wrappedValue == focusID && focusID != nil
                    ? Color.white.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .accessibilityValue(TVL10n.value(isOn ? "settings.hardwareYes" : "settings.hardwareNo"))
        .accessibilityIdentifier(accessibilityID ?? focusID ?? "settings-switch")
        .onMoveCommand { direction in
            if direction == .left { onMoveLeft?() }
        }
    }

    @ViewBuilder
    var body: some View {
        if let focus, let focusID {
            switchButton.focused(focus, equals: focusID)
        } else {
            switchButton
        }
    }
}
