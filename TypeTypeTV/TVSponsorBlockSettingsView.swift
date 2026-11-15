import SwiftUI

/// Inline settings category, not a modal: the outer PreferencesView owns the
/// left-hand rail, ScrollView and Back navigation. Every row has a stable
/// focus target, including the Refresh button while account data is loading.
struct TVSponsorBlockSettingsView: View {
    let api: TypeTypeAPI
    let focus: FocusState<String?>.Binding
    var onMoveLeft: () -> Void = {}

    @State private var settings: TVServerSettings?
    @State private var lastConfirmedSettings: TVServerSettings?
    @State private var loading = true
    @State private var refreshInFlight = false
    @State private var saving = false
    @State private var lastWrite: Task<Void, Never>?
    @State private var writeGeneration = 0
    @State private var error: String?
    @State private var pendingFocusMove: Task<Void, Never>?

    /// tvOS's geometric Focus Engine would otherwise skip the global mode
    /// (right-aligned Picker) and jump from Refresh into the categories.
    /// One explicit ordering is shared by every remote-focusable control.
    private var orderedFocusIDs: [String] {
        ["sponsor.refresh", "sponsor.mode"] +
        TVSponsorBlock.categories.map { "sponsor.category." + $0 } +
        ["sponsor.minimum",
         "sponsor.sponsorBlockShowCurrentSegment",
         "sponsor.sponsorBlockShowChapters",
         "sponsor.sponsorBlockShowFullVideoLabels",
         "sponsor.sponsorBlockManualSkipOnFullVideo",
         "sponsor.sponsorBlockSkipNonMusicOnlyOnMusicVideos",
         "sponsor.sponsorBlockMuteInsteadOfSkip"]
    }

    private func moveFocus(from current: String, direction: MoveCommandDirection) {
        guard let index = orderedFocusIDs.firstIndex(of: current) else { return }
        let step: Int
        if direction == .up { step = -1 }
        else if direction == .down { step = 1 }
        else { return }
        let destination = index + step
        guard orderedFocusIDs.indices.contains(destination) else { return }
        let next = orderedFocusIDs[destination]
        pendingFocusMove?.cancel()
        // tvOS commits its geometrically chosen focus *after* onMoveCommand.
        // One Task.yield() may run before that commit, causing the native
        // engine to override the requested Picker with a category below it.
        // Reassert once the native move has settled. A subsequent press
        // cancels any outstanding transfer, so rapid remote input cannot
        // replay an obsolete focus request.
        pendingFocusMove = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            focus.wrappedValue = next
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVSettingsCard("sponsor.title", summary: "settings.remoteSynced") {
                ZStack(alignment: .topLeading) {
                    Text("sponsor.lookupPrivacy")
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                    #if DEBUG
                    if api.origin.host == "preview.invalid" {
                        // The native tvOS Picker renders its highlight, but
                        // XCUIElement.hasFocus does not reliably expose it.
                        // Assert the real SwiftUI FocusState in preview tests.
                        Text(focus.wrappedValue ?? "none")
                            .font(.system(size: 1))
                            .foregroundStyle(.clear)
                            .accessibilityIdentifier("sponsor-focus-state")
                    }
                    #endif
                }
                Button("common.refresh") { Task { await reload() } }
                    .buttonStyle(.bordered)
                    .focused(focus, equals: "sponsor.refresh")
                    .onMoveCommand { direction in
                        if direction == .left {
                            onMoveLeft()
                        } else {
                            moveFocus(from: "sponsor.refresh", direction: direction)
                        }
                    }
                    .accessibilityIdentifier("sponsor-refresh")
                if loading {
                    ProgressView("settings.remoteLoading")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let settings {
                    choice("sponsor.mode",
                           current: settings.sponsorBlockMode ?? "auto_skip",
                           focusID: "sponsor.mode",
                           choices: ["auto_skip", "mark_only", "disabled"]) { mode in
                        setGlobalMode(mode)
                    }
                }
                if saving {
                    ProgressView("settings.remoteSaving")
                }
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if let settings {
                TVSettingsCard("sponsor.categories") {
                    ForEach(TVSponsorBlock.categories, id: \.self) { category in
                        choice(TVSponsorBlock.titleKey(category),
                               current: TVSponsorBlock.action(category, settings: settings),
                               focusID: "sponsor.category." + category,
                               choices: ["auto_skip", "mark_only", "disabled"]) { action in
                            var actions = settings.sponsorBlockCategoryActions ??
                                TVSponsorBlock.defaults
                            actions[category] = action
                            update("sponsorBlockCategoryActions", value: .actions(actions)) {
                                $0.sponsorBlockCategoryActions = actions
                            }
                        }
                    }
                }

                TVSettingsCard("sponsor.advanced") {
                    choice("sponsor.minimum",
                           current: String(settings.sponsorBlockMinimumDuration ?? 0),
                           focusID: "sponsor.minimum",
                           choices: ["0", "3", "5", "10", "15", "30"]) { amount in
                        let seconds = Int(amount) ?? 0
                        update("sponsorBlockMinimumDuration", value: .integer(seconds)) {
                            $0.sponsorBlockMinimumDuration = seconds
                        }
                    }

                    settingSwitch("sponsor.showCurrent",
                                  field: "sponsorBlockShowCurrentSegment",
                                  keyPath: \.sponsorBlockShowCurrentSegment,
                                  defaultValue: true)
                    settingSwitch("sponsor.showChapters",
                                  field: "sponsorBlockShowChapters",
                                  keyPath: \.sponsorBlockShowChapters,
                                  defaultValue: false)
                    settingSwitch("sponsor.showFull",
                                  field: "sponsorBlockShowFullVideoLabels",
                                  keyPath: \.sponsorBlockShowFullVideoLabels,
                                  defaultValue: true)
                    settingSwitch("sponsor.manualFull",
                                  field: "sponsorBlockManualSkipOnFullVideo",
                                  keyPath: \.sponsorBlockManualSkipOnFullVideo,
                                  defaultValue: true)
                    settingSwitch("sponsor.music",
                                  field: "sponsorBlockSkipNonMusicOnlyOnMusicVideos",
                                  keyPath: \.sponsorBlockSkipNonMusicOnlyOnMusicVideos,
                                  defaultValue: false)
                    settingSwitch("sponsor.mute",
                                  field: "sponsorBlockMuteInsteadOfSkip",
                                  keyPath: \.sponsorBlockMuteInsteadOfSkip,
                                  defaultValue: false)
                }
            } else if !loading {
                TVSettingsCard("sponsor.loadError") {
                    Text("settings.remoteLoginHelp")
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                }
            }
        }
        .task { await reload() }
        .onDisappear { pendingFocusMove?.cancel() }
    }

    private func choice(_ title: String, current: String, focusID: String,
                        choices: [String], change: @escaping (String) -> Void) -> some View {
        TVSettingsMenuRow(
            LocalizedStringKey(title),
            selection: Binding(
                get: { current },
                set: { selected in
                    change(selected)
                    // Only a genuine user selection may restore this Picker.
                    // Bulk mode updates only update the Binding's getter.
                    Task { @MainActor in
                        await Task.yield()
                        if focus.wrappedValue == focusID ||
                           focus.wrappedValue == nil {
                            focus.wrappedValue = focusID
                        }
                    }
                }
            ),
            focus: focus,
            focusTarget: focusID,
            onMoveLeft: onMoveLeft,
            onVerticalMove: { direction in
                moveFocus(from: focusID, direction: direction)
            },
            restoreFocusOnSelectionChange: false
        ) {
            ForEach(choices, id: \.self) { option in
                Text(optionLabel(option)).tag(option)
            }
        }
    }

    private func optionLabel(_ value: String) -> String {
        switch value {
        case "auto_skip": return TVL10n.value("sponsor.auto")
        case "mark_only": return TVL10n.value("sponsor.mark")
        case "disabled": return TVL10n.value("sponsor.disabled")
        default: return value + " s"
        }
    }

    private func settingSwitch(_ title: String, field: String,
                               keyPath: WritableKeyPath<TVServerSettings, Bool?>,
                               defaultValue: Bool) -> some View {
        TVSettingsSwitchRow(
            LocalizedStringKey(title),
            isOn: Binding(
                get: { settings?[keyPath: keyPath] ?? defaultValue },
                set: { enabled in
                    update(field, value: .boolean(enabled)) {
                        $0[keyPath: keyPath] = enabled
                    }
                }
            ),
            focus: focus, focusID: "sponsor." + field,
            onMoveLeft: onMoveLeft,
            onVerticalMove: { direction in
                moveFocus(from: "sponsor." + field, direction: direction)
            }
        )
    }

    /// Update the screen immediately so a Picker or Switch does not jump
    /// back to its previous value while waiting on the server. Network writes
    /// are serialized without disabling the currently focused control.
    private func update(_ field: String, value: TVSettingValue,
                        mutate: @escaping (inout TVServerSettings) -> Void) {
        guard var next = settings else { return }
        mutate(&next)
        settings = next
        enqueue([field: value])
    }

    private func setGlobalMode(_ mode: String) {
        guard var next = settings else { return }
        let actions = Dictionary(uniqueKeysWithValues:
            TVSponsorBlock.categories.map { ($0, mode) })
        next.sponsorBlockMode = mode
        next.sponsorBlockCategoryActions = actions
        settings = next
        enqueue([
            "sponsorBlockMode": .text(mode),
            "sponsorBlockCategoryActions": .actions(actions)
        ])
    }

    /// Queue fast remote interactions rather than silently dropping them
    /// while the previous PUT is in flight. Only the latest response may
    /// replace the optimistic UI snapshot, so old replies cannot undo it.
    private func enqueue(_ fields: [String: TVSettingValue]) {
        writeGeneration &+= 1
        let generation = writeGeneration
        let predecessor = lastWrite
        saving = true
        error = nil
        lastWrite = Task { @MainActor in
            await predecessor?.value
            do {
                let response = try await api.setAccountSettings(fields)
                if generation == writeGeneration {
                    settings = response
                    lastConfirmedSettings = response
                    error = nil
                }
            } catch {
                if generation == writeGeneration {
                    let message = error.localizedDescription
                    if let fresh = try? await api.accountSettings() {
                        settings = fresh
                        lastConfirmedSettings = fresh
                    } else {
                        // A failed save + failed refresh must not leave an
                        // unconfirmed toggle looking successfully enabled.
                        settings = lastConfirmedSettings
                    }
                    self.error = message
                }
            }
            if generation == writeGeneration {
                saving = false
                lastWrite = nil
            }
        }
    }

    @MainActor
    private func reload() async {
        guard !saving, !refreshInFlight else { return }
        refreshInFlight = true
        loading = true
        defer {
            loading = false
            refreshInFlight = false
        }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            // Deterministic network-free tvOS screenshots and focus tests.
            settings = try? JSONDecoder().decode(
                TVServerSettings.self, from: Data("{}".utf8)
            )
            lastConfirmedSettings = settings
            error = nil
            return
        }
        #endif
        do {
            let fresh = try await api.accountSettings()
            settings = fresh
            lastConfirmedSettings = fresh
            error = nil
        } catch is CancellationError {
            return
        } catch {
            // Keep the last usable settings on transient refresh failures.
            self.error = error.localizedDescription
        }
    }
}
