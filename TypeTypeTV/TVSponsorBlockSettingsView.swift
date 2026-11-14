import SwiftUI

/// Dedicated SponsorBlock settings panel. Preferences stay on TypeType Server
/// and are shared with the web interface.
struct TVSponsorBlockSettingsView: View {
    let api: TypeTypeAPI
    @Environment(\.dismiss) private var dismiss
    @State private var settings: TVServerSettings?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("sponsor.title").font(.system(size: 36, weight: .bold))
                Spacer()
                Button("common.back") { dismiss() }.buttonStyle(.bordered)
            }
            if loading {
                ProgressView("settings.remoteLoading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let settings {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("sponsor.mode").font(.title3.bold())
                        Text("sponsor.lookupPrivacy")
                            .font(.caption)
                            .foregroundStyle(TTTheme.muted)
                        choice("sponsor.mode", current: settings.sponsorBlockMode ?? "auto_skip",
                               choices: ["auto_skip", "mark_only", "disabled"]) { mode in
                            Task { await updateGlobalMode(mode) }
                        }
                        Divider()
                        Text("sponsor.categories").font(.title3.bold())
                        ForEach(TVSponsorBlock.categories, id: \.self) { category in
                            choice(TVSponsorBlock.titleKey(category),
                                   current: TVSponsorBlock.action(category, settings: settings),
                                   choices: ["auto_skip", "mark_only", "disabled"]) { next in
                                var actions = settings.sponsorBlockCategoryActions ??
                                    TVSponsorBlock.defaults
                                actions[category] = next
                                Task { await write("sponsorBlockCategoryActions",
                                                   value: .actions(actions)) }
                            }
                        }
                        Divider()
                        Text("sponsor.advanced").font(.title3.bold())
                        choice("sponsor.minimum",
                               current: String(settings.sponsorBlockMinimumDuration ?? 0),
                               choices: ["0", "3", "5", "10", "15", "30"]) { next in
                            Task { await write("sponsorBlockMinimumDuration",
                                               value: .integer(Int(next) ?? 0)) }
                        }
                        settingSwitch("sponsor.showCurrent", field: "sponsorBlockShowCurrentSegment",
                                      value: settings.sponsorBlockShowCurrentSegment ?? true)
                        settingSwitch("sponsor.showChapters", field: "sponsorBlockShowChapters",
                                      value: settings.sponsorBlockShowChapters ?? false)
                        settingSwitch("sponsor.showFull", field: "sponsorBlockShowFullVideoLabels",
                                      value: settings.sponsorBlockShowFullVideoLabels ?? true)
                        settingSwitch("sponsor.manualFull", field: "sponsorBlockManualSkipOnFullVideo",
                                      value: settings.sponsorBlockManualSkipOnFullVideo ?? true)
                        settingSwitch("sponsor.music", field: "sponsorBlockSkipNonMusicOnlyOnMusicVideos",
                                      value: settings.sponsorBlockSkipNonMusicOnlyOnMusicVideos ?? false)
                        settingSwitch("sponsor.mute", field: "sponsorBlockMuteInsteadOfSkip",
                                      value: settings.sponsorBlockMuteInsteadOfSkip ?? false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 55)
                }
                .scrollIndicators(.visible)
                .focusSection()
                if saving { ProgressView("settings.remoteSaving") }
            } else {
                Text("sponsor.loadError").foregroundStyle(TTTheme.muted)
                Button("common.retry") { Task { await reload() } }.buttonStyle(.bordered)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange).lineLimit(3)
            }
        }
        .padding(36)
        .frame(width: 1050, height: 910)
        .background(.ultraThickMaterial,
                    in: RoundedRectangle(cornerRadius: 24))
        .task { await reload() }
        .onExitCommand { dismiss() }
    }

    private func choice(_ title: String, current: String, choices: [String],
                        change: @escaping (String) -> Void) -> some View {
        HStack(spacing: 18) {
            Text(TVL10n.value(title)).font(.body)
            Spacer(minLength: 14)
            Picker(TVL10n.value(title), selection: Binding(
                get: { current },
                set: { change($0) }
            )) {
                ForEach(choices, id: \.self) { next in
                    Text(optionLabel(next)).tag(next)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 310)
        }
        .frame(minHeight: 46)
    }

    private func optionLabel(_ value: String) -> String {
        switch value {
        case "auto_skip": return TVL10n.value("sponsor.auto")
        case "mark_only": return TVL10n.value("sponsor.mark")
        case "disabled": return TVL10n.value("sponsor.disabled")
        default: return value + " s"
        }
    }

    private func settingSwitch(_ title: String, field: String, value: Bool) -> some View {
        TVSettingsSwitchRow(
            LocalizedStringKey(title),
            isOn: Binding(
                get: { value },
                set: { next in
                    Task { await write(field, value: .boolean(next)) }
                }
            )
        )
    }

    @MainActor
    private func reload() async {
        guard !saving else { return }
        loading = true
        defer { loading = false }
        do {
            settings = try await api.accountSettings()
            error = nil
        } catch {
            settings = nil
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func updateGlobalMode(_ mode: String) async {
        guard !saving else { return }
        saving = true
        error = nil
        do {
            // Global mode and categories must always change together.
            // Two separate PUTs could otherwise leave inconsistent rules.
            let actions = Dictionary(uniqueKeysWithValues:
                TVSponsorBlock.categories.map { ($0, mode) })
            settings = try await api.setAccountSettings([
                "sponsorBlockCategoryActions": .actions(actions),
                "sponsorBlockMode": .text(mode)
            ])
        } catch {
            self.error = error.localizedDescription
            settings = try? await api.accountSettings()
        }
        saving = false
    }

    @MainActor
    private func write(_ field: String, value: TVSettingValue) async {
        guard !saving else { return }
        saving = true
        error = nil
        do {
            settings = try await api.setAccountSetting(field, value: value)
        } catch {
            self.error = error.localizedDescription
            settings = try? await api.accountSettings()
        }
        saving = false
    }
}