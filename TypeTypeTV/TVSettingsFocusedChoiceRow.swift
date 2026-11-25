import SwiftUI

/// Native tvOS focus on the selected item of a stable, sorted option list.
/// SwiftUI Picker(.menu) indicates the selection, but cannot specify which
/// menu entry receives initial remote focus. This sheet uses the public
/// FocusState API instead of reordering options or delaying a focus change.
struct TVSettingsChoice<Value: Hashable> {
    let value: Value
    let titleKey: String
}

struct TVSettingsFocusedChoiceRow<Value: Hashable>: View {
    let titleKey: String
    @Binding var selection: Value
    let choices: [TVSettingsChoice<Value>]
    let focus: FocusState<String?>.Binding
    let focusTarget: String
    var enabled = true

    @State private var presented = false

    private var selectedTitle: String {
        let key = choices.first(where: { $0.value == selection })?.titleKey
        return key.map(TVL10n.value) ?? ""
    }

    var body: some View {
        HStack(spacing: 24) {
            Text(TVL10n.value(titleKey))
                .font(.body)
            Spacer(minLength: 20)
            Button {
                presented = true
            } label: {
                HStack(spacing: 12) {
                    Text(selectedTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .focused(focus, equals: focusTarget)
            .accessibilityIdentifier(focusTarget)
            .accessibilityValue(selectedTitle)
        }
        .padding(.vertical, 6)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .sheet(isPresented: $presented) {
            TVSettingsFocusedChoiceSheet(
                titleKey: titleKey,
                selection: $selection,
                choices: choices
            )
        }
    }
}

/// Every option is materialized so tvOS can focus an offscreen selected row.
/// FocusState/defaultFocus and ScrollViewReader establish selection and scroll
/// synchronously on presentation. No timers, UIKit overrides or focus polling.
private struct TVSettingsFocusedChoiceSheet<Value: Hashable>: View {
    let titleKey: String
    @Binding var selection: Value
    let choices: [TVSettingsChoice<Value>]

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedChoice: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(TVL10n.value(titleKey))
                .font(.largeTitle.bold())
                .padding(.horizontal, 18)
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(choices.indices, id: \.self) { index in
                            let item = choices[index]
                            Button {
                                selection = item.value
                                dismiss()
                            } label: {
                                HStack(spacing: 18) {
                                    Text(TVL10n.value(item.titleKey))
                                    Spacer()
                                    if item.value == selection {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(TTTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 22)
                                .frame(height: 56)
                                .background(
                                    focusedChoice == item.value
                                        ? Color.white.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                            }
                            .buttonStyle(TVRailButtonStyle())
                            .focusEffectDisabled(true)
                            .focused($focusedChoice, equals: item.value)
                            .id(item.value)
                            .accessibilityIdentifier("settings-choice-\(index)")
                            .accessibilityAddTraits(item.value == selection
                                ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                .defaultFocus($focusedChoice, selection, priority: .userInitiated)
                .onAppear {
                    // Scroll directly to the current value. Native FocusState
                    // selects that exact button even when it isn't the first.
                    scroll.scrollTo(selection, anchor: .center)
                    focusedChoice = selection
                }
            }
        }
        .padding(36)
        .frame(maxWidth: 930, maxHeight: .infinity)
        .background(TTTheme.ink)
        .onExitCommand { dismiss() }
    }
}
