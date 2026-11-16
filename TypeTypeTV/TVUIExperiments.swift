import SwiftUI

/// Only unapproved, device-local interface experiments remain in this file.
/// The adopted focus glint, slide notices, fade feedback and Liquid Glass are
/// shared by both branches through TVStableVisualEffects.
enum TVUIMotion {
    static func pageTransition(_ mode: String, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion || mode == "crossfade" { return .opacity }
        if mode == "shift" {
            return .asymmetric(
                insertion: .offset(x: 22).combined(with: .opacity),
                removal: .opacity)
        }
        return .identity
    }
}

/// tvOS does not support the iOS zoom NavigationTransition; move the local view.
struct TVExperimentNavigation: ViewModifier {
    let style: String
    let reduceMotion: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if style == "crossfade" || reduceMotion && style != "standard" {
            content.transition(.opacity)
        } else if style == "shift" {
            content.transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            content
        }
    }
}

/// Visual placeholders only during actual loading; never extra requests.
struct TVExperimentLoading: View {
    @AppStorage("typetype.exp.loading") private var style = "standard"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = false

    var body: some View {
        Group {
            if style == "standard" {
                ProgressView().frame(maxWidth: .infinity, minHeight: 165)
            } else {
                HStack(spacing: 22) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(TTTheme.surface)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(TTTheme.surface)
                                .frame(height: 19)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(TTTheme.surface)
                                .frame(width: 110, height: 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(style == "pulse" && !reduceMotion && highlighted ? 0.48 : 1)
                .animation(style == "pulse" && !reduceMotion
                           ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                           : nil, value: highlighted)
                .onAppear { highlighted = true }
                .onDisappear { highlighted = false }
                .accessibilityLabel(TVL10n.value("home.loading"))
            }
        }
    }
}

/// A fixed Siri Remote Up/Down sequence for all remaining experimental rows.
enum TVExperimentFocusPath {
    static let order = [
        "experiment.page", "experiment.hero", "experiment.symbols",
        "experiment.loading", "experiment.sidebar", "experiment.reset"
    ]

    static func destination(from id: String, direction: MoveCommandDirection) -> String? {
        guard let index = order.firstIndex(of: id) else { return nil }
        switch direction {
        case .up: return index > 0 ? order[index - 1] : nil
        case .down: return index + 1 < order.count ? order[index + 1] : nil
        default: return nil
        }
    }
}

/// Remaining experiments are device-local. Nothing changes TypeType accounts
/// or the SABR video renderer.
struct TVUIExperimentSettings: View {
    let focus: FocusState<String?>.Binding
    let onMoveLeft: () -> Void

    @AppStorage("typetype.exp.page") private var page = "standard"
    @AppStorage("typetype.exp.hero") private var hero = "standard"
    @AppStorage("typetype.exp.symbols") private var symbols = false
    @AppStorage("typetype.exp.loading") private var loading = "standard"
    @AppStorage("typetype.exp.sidebar") private var sidebar = "standard"

    private func move(_ direction: MoveCommandDirection, from id: String) {
        if direction == .left {
            onMoveLeft()
        } else if let destination = TVExperimentFocusPath.destination(
            from: id, direction: direction
        ) {
            focus.wrappedValue = destination
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            TVSettingsCard("ui.experiments", summary: "ui.experimentsHelp") {
                Text("ui.experimentsWarning")
                    .font(.callout).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("ui.transitions") {
                TVSettingsMenuRow("ui.page", selection: $page,
                                  focus: focus, focusTarget: "experiment.page",
                                  onMoveLeft: onMoveLeft,
                                  onVerticalMove: { move($0, from: "experiment.page") }) {
                    Text("ui.off").tag("standard")
                    Text("ui.crossfade").tag("crossfade")
                    Text("ui.shift").tag("shift")
                }
                Text("ui.pageInstructions")
                    .font(.caption).foregroundStyle(TTTheme.muted)

                TVSettingsMenuRow("ui.hero", selection: $hero,
                                  focus: focus, focusTarget: "experiment.hero",
                                  onMoveLeft: onMoveLeft,
                                  onVerticalMove: { move($0, from: "experiment.hero") }) {
                    Text("ui.off").tag("standard")
                    Text("ui.fade").tag("fade")
                    Text("ui.zoom").tag("zoom")
                }
                Text("ui.heroInstructions")
                    .font(.caption).foregroundStyle(TTTheme.muted)
                Text("ui.heroNote")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("ui.details") {
                TVSettingsSwitchRow("ui.symbols", isOn: $symbols,
                                    focus: focus, focusID: "experiment.symbols",
                                    onMoveLeft: onMoveLeft,
                                    onVerticalMove: { move($0, from: "experiment.symbols") })
                Text("ui.symbolsInstructions")
                    .font(.caption).foregroundStyle(TTTheme.muted)

                TVSettingsMenuRow("ui.loading", selection: $loading,
                                  focus: focus, focusTarget: "experiment.loading",
                                  onMoveLeft: onMoveLeft,
                                  onVerticalMove: { move($0, from: "experiment.loading") }) {
                    Text("ui.off").tag("standard")
                    Text("ui.skeleton").tag("skeleton")
                    Text("ui.pulse").tag("pulse")
                }
                Text("ui.loadingInstructions")
                    .font(.caption).foregroundStyle(TTTheme.muted)

                TVSettingsMenuRow("ui.sidebar", selection: $sidebar,
                                  focus: focus, focusTarget: "experiment.sidebar",
                                  onMoveLeft: onMoveLeft,
                                  onVerticalMove: { move($0, from: "experiment.sidebar") }) {
                    Text("ui.off").tag("standard")
                    Text("ui.fade").tag("fade")
                }
                Text("ui.sidebarInstructions")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            HStack {
                Spacer(minLength: 0)
                Button("ui.reset") {
                    page = "standard"; hero = "standard"; symbols = false
                    loading = "standard"; sidebar = "standard"
                }
                .buttonStyle(.bordered)
                .tint(TTTheme.accent)
                .focused(focus, equals: "experiment.reset")
                .accessibilityIdentifier("experiment-reset")
                .onMoveCommand { move($0, from: "experiment.reset") }
            }
        }
    }
}
