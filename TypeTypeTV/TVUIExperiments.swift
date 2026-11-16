import SwiftUI

/// Device-local, opt-in visual experiments. Never read/write TypeType account settings.
enum TVUIMotion {
    static func transition(_ mode: String, reduceMotion: Bool,
                           anchor: UnitPoint = .center) -> AnyTransition {
        if reduceMotion { return .opacity }
        switch mode {
        case "pop":
            return .asymmetric(
                insertion: .scale(scale: 0.84, anchor: anchor).combined(with: .opacity),
                removal: .scale(scale: 0.94, anchor: anchor).combined(with: .opacity))
        case "slide":
            return .move(edge: .top).combined(with: .opacity)
        case "fade":
            return .opacity
        default:
            return .identity
        }
    }

    static func animation(_ mode: String, reduceMotion: Bool) -> Animation? {
        guard mode != "off" && mode != "standard" else { return nil }
        return reduceMotion ? .easeOut(duration: 0.15) :
            (mode == "pop" ? .spring(response: 0.32, dampingFraction: 0.72) :
                .easeOut(duration: 0.23))
    }

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

/// Applies native tvOS gimbal/specular highlight to artwork only, not its badges.
struct TVExperimentArtworkFocus: ViewModifier {
    let mode: String
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .hoverEffect(.highlight,
                         isEnabled: !reduceMotion && (mode == "highlight" || mode == "hybrid"))
            .hoverEffect(.lift, isEnabled: !reduceMotion && mode == "lift")
    }
}

struct TVExperimentGlass: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        } else {
            content
        }
    }
}

/// Loading is visual-only: it does not start additional network work or timers.
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

/// Independent focusable settings page. No changes to the server or the playback pipeline.
struct TVUIExperimentSettings: View {
    let focus: FocusState<String?>.Binding
    let onMoveLeft: () -> Void

    @AppStorage("typetype.exp.popup") private var popup = "off"
    @AppStorage("typetype.exp.focus") private var focusStyle = "classic"
    @AppStorage("typetype.exp.glass") private var glass = false
    @AppStorage("typetype.exp.toast") private var toast = "standard"
    @AppStorage("typetype.exp.page") private var page = "standard"
    @AppStorage("typetype.exp.hero") private var hero = "standard"
    @AppStorage("typetype.exp.background") private var background = "standard"
    @AppStorage("typetype.exp.symbols") private var symbols = false
    @AppStorage("typetype.exp.loading") private var loading = "standard"
    @AppStorage("typetype.exp.sidebar") private var sidebar = "standard"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPopup = false
    @State private var showToast = false

    var body: some View {
        VStack(spacing: 24) {
            TVSettingsCard("ui.experiments", summary: "ui.experimentsHelp") {
                Text("ui.experimentsWarning")
                    .font(.callout).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("ui.focusTitle", summary: "ui.focusHelp") {
                TVSettingsMenuRow("ui.focusTitle", selection: $focusStyle,
                                  focus: focus, focusTarget: "experiment.focus",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.focusClassic").tag("classic")
                    Text("ui.focusHighlight").tag("highlight")
                    Text("ui.focusLift").tag("lift")
                    Text("ui.focusHybrid").tag("hybrid")
                }
                Button {
                    // Preview takes focus like any ordinary tvOS button.
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(colors: [TTTheme.accent.opacity(0.85),
                                                          TTTheme.surface],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: 360, height: 195)
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 76))
                            }
                            .modifier(TVExperimentArtworkFocus(
                                mode: focusStyle, reduceMotion: reduceMotion))
                        Text("ui.focusPreview").font(.callout)
                    }
                }
                .buttonStyle(TVRailButtonStyle())
                .focusEffectDisabled(true)
            }
            TVSettingsCard("ui.popupTitle", summary: "ui.popupHelp") {
                TVSettingsMenuRow("ui.popupTitle", selection: $popup,
                                  focus: focus, focusTarget: "experiment.popup",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("off")
                    Text("ui.pop").tag("pop")
                    Text("ui.slide").tag("slide")
                    Text("ui.fade").tag("fade")
                }
                Button("ui.previewPopup") {
                    withAnimation(TVUIMotion.animation(popup, reduceMotion: reduceMotion)) {
                        showPopup.toggle()
                    }
                }
                .buttonStyle(.bordered)
                if showPopup {
                    Label("SponsorBlock", systemImage: "forward.end.fill")
                        .padding(18)
                        .background(TTTheme.surface, in: Capsule())
                        .transition(TVUIMotion.transition(popup, reduceMotion: reduceMotion,
                                                         anchor: .topTrailing))
                }
            }
            TVSettingsCard("ui.toastTitle", summary: "ui.toastHelp") {
                TVSettingsMenuRow("ui.toastTitle", selection: $toast,
                                  focus: focus, focusTarget: "experiment.toast",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("standard")
                    Text("ui.pop").tag("pop")
                    Text("ui.slide").tag("slide")
                    Text("ui.fade").tag("fade")
                }
                Button("ui.previewToast") {
                    withAnimation(TVUIMotion.animation(toast, reduceMotion: reduceMotion)) {
                        showToast.toggle()
                    }
                }
                .buttonStyle(.bordered)
                if showToast {
                    Label("ui.previewSuccess", systemImage: "checkmark.circle.fill")
                        .padding(15)
                        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .transition(TVUIMotion.transition(toast, reduceMotion: reduceMotion))
                }
            }
            TVSettingsCard("ui.transitions") {
                TVSettingsMenuRow("ui.page", selection: $page,
                                  focus: focus, focusTarget: "experiment.page",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("standard")
                    Text("ui.crossfade").tag("crossfade")
                    Text("ui.shift").tag("shift")
                }
                TVSettingsMenuRow("ui.hero", selection: $hero,
                                  focus: focus, focusTarget: "experiment.hero",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("standard")
                    Text("ui.fade").tag("fade")
                    Text("ui.zoom").tag("zoom")
                }
                Text("ui.heroNote")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("ui.materials") {
                TVSettingsSwitchRow("ui.glass", isOn: $glass,
                                    focus: focus, focusID: "experiment.glass",
                                    onMoveLeft: onMoveLeft)
                TVSettingsMenuRow("ui.background", selection: $background,
                                  focus: focus, focusTarget: "experiment.background",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("standard")
                    Text("ui.cinematic").tag("cinematic")
                    Text("ui.blurred").tag("blurred")
                }
                Text("ui.glassNote")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("ui.details") {
                TVSettingsSwitchRow("ui.symbols", isOn: $symbols,
                                    focus: focus, focusID: "experiment.symbols",
                                    onMoveLeft: onMoveLeft)
                TVSettingsMenuRow("ui.loading", selection: $loading,
                                  focus: focus, focusTarget: "experiment.loading",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("standard")
                    Text("ui.skeleton").tag("skeleton")
                    Text("ui.pulse").tag("pulse")
                }
                TVSettingsMenuRow("ui.sidebar", selection: $sidebar,
                                  focus: focus, focusTarget: "experiment.sidebar",
                                  onMoveLeft: onMoveLeft) {
                    Text("ui.off").tag("standard")
                    Text("ui.fade").tag("fade")
                }
            }
            Button("ui.reset") {
                popup = "off"; focusStyle = "classic"; glass = false
                toast = "standard"; page = "standard"; hero = "standard"
                background = "standard"; symbols = false; loading = "standard"
                sidebar = "standard"; showPopup = false; showToast = false
            }
            .buttonStyle(.bordered)
            .tint(TTTheme.accent)
        }
    }
}
