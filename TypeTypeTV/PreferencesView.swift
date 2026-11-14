import Foundation
import SwiftUI

/// Settings use Android's two-panel TV navigation: a focused group rail on
/// the left and large, comfortably selectable controls on the right.
/// Device options stay on Apple TV; content flags write to TypeType Server.
struct PreferencesView: View {
    let api: TypeTypeAPI
    let onDisconnect: () -> Void
    let focusRequest: Int
    let autoPresentAddAccount: Bool
    var onAccountChanged: () -> Void = {}
    var onBackToMenu: () -> Void = {}
    var onGroupChanged: (TVSettingsGroup) -> Void = { _ in }
    var onAddAccountDismissed: () -> Void = {}

    @ObservedObject private var hardware = TVHardwareDiagnostics.shared
    @AppStorage("typetype.uiLanguage") private var uiLanguage = TVLanguages.followSystem
    @AppStorage("typetype.allowSoftwareDecode") private var allowSoftware = false
    @AppStorage("typetype.maxHeight") private var maxHeight = 2160
    @AppStorage("typetype.skipSeconds") private var skipSeconds = 10
    @AppStorage("typetype.bufferForwardSeconds") private var bufferForwardSeconds = 180
    @AppStorage("typetype.bufferBackSeconds") private var bufferBackSeconds = 120
    @AppStorage("typetype.bufferCacheMiB") private var bufferCacheMiB = 512
    @AppStorage("typetype.navigationAnimations") private var navigationAnimations = true
    @AppStorage("typetype.thumbnailCacheMiB") private var thumbnailCacheMiB = 128

    @State private var group: TVSettingsGroup
    @FocusState private var focusedGroup: TVSettingsGroup?
    @FocusState private var focusedControl: String?
    @State private var lastRemovalID: String?
    @State private var remote: TVServerSettings?
    @State private var remoteLoading = false
    @State private var remoteSaving = false
    @State private var remoteError: String?
    @State private var instanceInfo: InstanceInfo?
    @State private var instanceError: String?
    @State private var confirmCertificateRemoval = false
    @State private var confirmLogout = false
    @State private var showAddAccountSheet = false
    @State private var accountIdentity: TVAccountIdentity?
    @State private var savedAccounts: [TVSavedAccount] = []
    @State private var pendingProfileRemoval: TVSavedAccount?
    @State private var confirmProfileRemoval = false
    @State private var accountLoading = false
    @State private var accountError: String?
    @State private var status = ""

    init(api: TypeTypeAPI, onDisconnect: @escaping () -> Void,
         initialGroup: TVSettingsGroup = .playback,
         focusRequest: Int = 0,
         autoPresentAddAccount: Bool = false,
         onAccountChanged: @escaping () -> Void = {},
         onBackToMenu: @escaping () -> Void = {},
         onGroupChanged: @escaping (TVSettingsGroup) -> Void = { _ in },
         onAddAccountDismissed: @escaping () -> Void = {}) {
        self.api = api
        self.onDisconnect = onDisconnect
        self.focusRequest = focusRequest
        self.autoPresentAddAccount = autoPresentAddAccount
        self.onAccountChanged = onAccountChanged
        self.onBackToMenu = onBackToMenu
        self.onGroupChanged = onGroupChanged
        self.onAddAccountDismissed = onAddAccountDismissed
        _group = State(initialValue: initialGroup)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 23) {
            groupRail
                .frame(width: 234)
                // A default focus on the rail can steal focus back from
                // Picker menus and account dialogs when they close.
                .environment(\.isFocusEffectEnabled, false)
                .focusEffectDisabled(true)
                .clipped()
                .focusSection()

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("nav.settings")
                        .font(.system(size: 48, weight: .bold))
                    Text(TVL10n.value(group.titleKey).uppercased())
                        .tracking(1.8)
                        .font(.subheadline.bold())
                        .foregroundStyle(TTTheme.accent)
                    Text(TVL10n.value(group.subtitleKey))
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                }
                .padding(.leading, 10)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 24) {
                        groupContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 95)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                .onMoveCommand { direction in
                    if direction == .left {
                        returnFocusToGroup()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TTTheme.ink)
        // The global navigation and Settings have independent focus
        // states. Transfer focus explicitly once Settings joins the tree.
        .task(id: focusRequest) {
            await Task.yield()
            focusedGroup = group
            if autoPresentAddAccount && group == .account {
                showAddAccountSheet = true
            }
        }
        .task(id: group) {
            if group == .content && remote == nil { await refreshRemote() }
            if group == .instance && instanceInfo == nil { await refreshInstance() }
            if group == .account { await refreshAccountIdentity() }
        }
        .onChange(of: focusedGroup) { previous, next in
            if previous == nil, let next, next != group {
                // A Left swipe from content can make tvOS pick a vertically
                // adjacent group rather than the group just being viewed.
                // Restore the selected group; explicit Up/Down on the rail
                // (where previous != nil) is still allowed to change it.
                let selected = group
                Task { @MainActor in
                    await Task.yield()
                    if group == selected, focusedGroup == next {
                        focusedGroup = selected
                    }
                }
                return
            }
            if let next, group != next {
                // .onChange(of: group) is the only source of notification:
                // calling the callback here too produced duplicate updates.
                group = next
            }
        }
        .onChange(of: focusedControl) { previous, next in
            guard let previous, next == nil, focusedGroup == nil,
                  previous == "playback.software" ||
                  previous == "device.animations" ||
                  previous == "sponsor.refresh" ||
                  previous.hasPrefix("sponsor.sponsorBlock") ||
                  (previous.hasPrefix("content.") &&
                   previous != "content.refresh" && previous != "content.retry")
            else { return }
            // The engine sometimes skips the Settings rail entirely and
            // chooses a global icon. Restore the selected Settings group in
            // that case, without disturbing Picker presentations.
            let selected = group
            Task { @MainActor in
                await Task.yield()
                guard group == selected, focusedControl == nil,
                      focusedGroup == nil else { return }
                focusedGroup = selected
            }
        }
        .onChange(of: group) { _, next in
            onGroupChanged(next)
        }
        .onChange(of: showAddAccountSheet) { _, visible in
            if !visible {
                Task { @MainActor in
                    await Task.yield()
                    focusedControl = "account.add"
                }
            }
        }
        .onChange(of: confirmProfileRemoval) { _, showing in
            if !showing, let id = lastRemovalID {
                Task { @MainActor in
                    await Task.yield()
                    if savedAccounts.contains(where: { $0.id == id }) {
                        focusedControl = "account.remove." + id
                    } else {
                        focusedControl = "account.add"
                    }
                }
            }
        }
        .onExitCommand {
            // Back climbs one level at a time:
            // controls -> selected Settings group -> global Settings icon.
            // The global sidebar then handles Settings -> Home -> no-op.
            if focusedGroup == nil {
                focusedGroup = group
            } else {
                onBackToMenu()
            }
        }
        .sheet(isPresented: $showAddAccountSheet,
               onDismiss: onAddAccountDismissed) {
            TVAddAccountSheet(api: api) {
                // The add-account sheet persists the new profile before
                // switching the active TypeType session.
                savedAccounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
                showAddAccountSheet = false
                onAccountChanged()
            }
        }
        .confirmationDialog(
            TVL10n.value("settings.logoutConfirm"),
            isPresented: $confirmLogout
        ) {
            Button("settings.logout", role: .destructive) {
                logOut()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.logoutHelp")
        }
        .confirmationDialog(
            TVL10n.value("settings.removeProfileTitle"),
            isPresented: $confirmProfileRemoval
        ) {
            Button("settings.removeProfile", role: .destructive) {
                removePendingProfile()
            }
            Button("common.cancel", role: .cancel) {
                pendingProfileRemoval = nil
            }
        } message: {
            Text(TVL10n.formatted(
                "settings.removeProfileHelp", pendingProfileRemoval?.label ?? ""
            ))
        }
        .confirmationDialog(
            TVL10n.value("settings.certForgetTitle"),
            isPresented: $confirmCertificateRemoval
        ) {
            Button(TVL10n.value("settings.certForget"), role: .destructive) {
                TVServerTrust.shared.revoke(for: api.origin)
                status = TVL10n.value("settings.certForgotten")
            }
            Button(TVL10n.value("common.cancel"), role: .cancel) {}
        } message: {
            Text("settings.certForgetHelp")
        }
    }

    private var groupRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("nav.settings")
                .font(.subheadline.bold())
                .tracking(2.6)
                .foregroundStyle(TTTheme.accent)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            ForEach(TVSettingsGroup.allCases) { item in
                Button {
                    enterGroup(item)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 21))
                            .frame(width: 27)
                        Text(TVL10n.value(item.titleKey))
                            .font(.system(size: 18, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if item == group {
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .modifier(TVRailRowHighlight(
                        focused: focusedGroup == item, selected: group == item
                    ))
                }
                .buttonStyle(TVRailButtonStyle())
                .focusEffectDisabled(true)
                .focused($focusedGroup, equals: item)
                .onMoveCommand { direction in
                    if direction == .right {
                        enterGroup(item)
                    } else if direction == .left {
                        onBackToMenu()
                    }
                }
                .accessibilityIdentifier("settings-group-\(item.rawValue)")
                .accessibilityLabel(TVL10n.value(item.titleKey))
                .accessibilityAddTraits(item == group ? .isSelected : [])
            }
            Spacer(minLength: 20)
        }
    }

    /// A horizontal remote move is resolved by the tvOS focus engine after
    /// the button's move handler. Defer restoration to the following turn so
    /// the engine cannot overwrite it with the geometrically nearest icon.
    @MainActor
    private func returnFocusToGroup() {
        let destination = group
        Task { @MainActor in
            await Task.yield()
            guard group == destination else { return }
            focusedGroup = destination
        }
    }

    @MainActor
    private func firstTarget(for item: TVSettingsGroup) -> String {
        switch item {
        case .playback: return "playback.software"
        case .sponsor: return "sponsor.refresh"
        case .content:
            return remote == nil ? "content.retry" :
                "content." + TVServerToggle.allCases[0].rawValue
        case .device: return "device.skip"
        case .language: return "control.language"
        case .account:
            return savedAccounts.first.map { "account.remove." + $0.id } ?? "account.add"
        case .instance: return "instance.refresh"
        case .about: return "about.name"
        }
    }

    @MainActor
    private func enterGroup(_ item: TVSettingsGroup) {
        group = item
        let target = firstTarget(for: item)
        Task { @MainActor in
            await Task.yield()
            guard group == item else { return }
            focusedControl = target
        }
    }

    @ViewBuilder
    private var groupContent: some View {
        switch group {
        case .playback: playbackPanel
        case .sponsor:
            TVSponsorBlockSettingsView(api: api,
                                       focus: $focusedControl,
                                       onMoveLeft: returnFocusToGroup)
        case .content: contentPanel
        case .device: devicePanel
        case .language: languagePanel
        case .account: accountPanel
        case .instance: instancePanel
        case .about: aboutPanel
        }
    }

    private var playbackPanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.videoQuality", summary: "settings.localDeviceScope") {
                TVSettingsSwitchRow(
                    "settings.allowSoftware", isOn: $allowSoftware,
                    focus: $focusedControl, focusID: "playback.software",
                    accessibilityID: "settings-first-playback",
                    onMoveLeft: { returnFocusToGroup() }
                )
                Text("settings.softwareWarning")
                    .font(.caption).foregroundStyle(TTTheme.muted)
                TVSettingsMenuRow(
                    "settings.maxResolution", selection: $maxHeight,
                    focus: $focusedControl, focusTarget: "playback.resolution",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    Text("4K").tag(2160)
                    Text("1440p").tag(1440)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("480p").tag(480)
                }
            }
        }
    }

    private var contentPanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.contentControls", summary: "settings.remoteSynced") {
                if remoteLoading {
                    ProgressView("settings.remoteLoading")
                        .padding(18)
                } else if let remote {
                    ForEach(TVServerToggle.allCases) { field in
                        TVSettingsSwitchRow(
                            LocalizedStringKey(field.titleKey),
                            isOn: Binding(
                                get: { self.remote?.enabled(field) ?? remote.enabled(field) },
                                set: { setRemote(field, enabled: $0) }
                            ),
                            focus: $focusedControl, focusID: "content." + field.rawValue,
                            onMoveLeft: { returnFocusToGroup() }
                        )
                        // Disabling a focused tvOS button during a network write
                        // makes the focus engine jump to an unrelated rail.
                        // setRemote itself serializes requests and ignores
                        // input while saving, without destroying focus.
                    }
                    if remoteSaving { ProgressView("settings.remoteSaving") }
                    Button("common.refresh") { Task { await refreshRemote() } }
                        .buttonStyle(.bordered)
                        .disabled(remoteSaving)
                        .focused($focusedControl, equals: "content.refresh")
                } else {
                    Text(remoteError ?? TVL10n.value("settings.remoteLoginHelp"))
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                    Button("common.retry") { Task { await refreshRemote() } }
                        .buttonStyle(.bordered)
                        .focused($focusedControl, equals: "content.retry")
                }
                if let remoteError, remote != nil {
                    Text(remoteError)
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            TVSettingsCard("settings.remoteCompatibility", summary: "settings.remoteCompatibilityHelp") {
                Label("settings.remoteImplemented", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            }
        }
    }

    private var devicePanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.remote", summary: "settings.remoteHelp") {
                TVSettingsMenuRow(
                    "settings.skipLength", selection: $skipSeconds,
                    focus: $focusedControl, focusTarget: "device.skip",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    ForEach([5, 10, 15, 20], id: \.self) { seconds in
                        Text(TVL10n.formatted("common.seconds", seconds)).tag(seconds)
                    }
                }
            }
            TVSettingsCard("settings.buffer", summary: "settings.bufferHelp") {
                TVSettingsMenuRow(
                    "settings.forwardBuffer", selection: $bufferForwardSeconds,
                    focus: $focusedControl, focusTarget: "device.forward",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    ForEach([30, 60, 120, 180, 300, 600], id: \.self) { seconds in
                        Text(TVL10n.formatted("common.seconds", seconds)).tag(seconds)
                    }
                }
                TVSettingsMenuRow(
                    "settings.backwardBuffer", selection: $bufferBackSeconds,
                    focus: $focusedControl, focusTarget: "device.backward",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    ForEach([30, 60, 120, 180, 300], id: \.self) { seconds in
                        Text(TVL10n.formatted("common.seconds", seconds)).tag(seconds)
                    }
                }
                TVSettingsMenuRow(
                    "settings.maxCache", selection: $bufferCacheMiB,
                    focus: $focusedControl, focusTarget: "device.maxCache",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    ForEach([256, 512, 1024], id: \.self) { amount in
                        Text("\(amount) MiB").tag(amount)
                    }
                }
                Text("settings.bufferWarning")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("settings.performanceControls") {
                TVSettingsSwitchRow(
                    "settings.navigationAnimations", isOn: $navigationAnimations,
                    focus: $focusedControl, focusID: "device.animations",
                    onMoveLeft: { returnFocusToGroup() }
                )
                Text("settings.navigationAnimationsHelp")
                    .font(.caption).foregroundStyle(TTTheme.muted)
                TVSettingsMenuRow(
                    "settings.imageCacheSize", selection: $thumbnailCacheMiB,
                    focus: $focusedControl, focusTarget: "device.imageCache",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    ForEach([32, 64, 128, 256], id: \.self) { count in
                        Text("\(count) MiB").tag(count)
                    }
                }
                Text("settings.imageCacheHelp")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("settings.hardware", summary: "settings.hardwareHelp") {
                TVSettingsInfoRow(title: "settings.hardwareModel",
                                  value: hardware.deviceName)
                TVSettingsInfoRow(title: "settings.hardwareIdentifier",
                                  value: hardware.deviceIdentifier)
                TVSettingsInfoRow(title: "settings.hardwareSystem",
                                  value: hardware.systemVersion)
                TVSettingsInfoRow(title: "settings.hardwareMemory",
                                  value: "\(hardware.totalMemoryMiB) MiB")
                TVSettingsInfoRow(title: "settings.hardwareOutput",
                                  value: hardware.outputSize)
                Divider()
                Text("settings.hardwareCodecProbe")
                    .font(.headline)
                ForEach(hardware.probes) { result in
                    HStack {
                        Text(result.name)
                        Spacer()
                        Label(
                            TVL10n.value(
                                result.hardwareAvailable ?
                                    "settings.hardwareYes" : "settings.hardwareNo"
                            ),
                            systemImage: result.hardwareAvailable ?
                                "checkmark.circle" : "minus.circle"
                        )
                        .foregroundStyle(result.hardwareAvailable ? .green : .orange)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .focusable(true)
                    .focusEffectDisabled(true)
                }
                TVSettingsReadableText(key: "settings.hardwareProbeNote")
                Button("settings.hardwareRefresh") {
                    hardware.refresh()
                }
                .buttonStyle(.bordered)
            }
            TVSettingsCard("settings.hardwareLastDecoder") {
                if let attempt = hardware.lastAttempt {
                    TVSettingsInfoRow(
                        title: "settings.hardwareStreamCodec",
                        value: "\(attempt.codec) · \(attempt.resolution)"
                    )
                    TVSettingsInfoRow(
                        title: "settings.hardwareSessionStatus",
                        value: attempt.status == 0 ?
                            TVL10n.value("settings.hardwareSessionCreated") :
                            "VideoToolbox OSStatus \(attempt.status)"
                    )
                    TVSettingsInfoRow(
                        title: "settings.hardwareActiveHardware",
                        value: attempt.hardwareUsed.map {
                            TVL10n.value($0 ?
                                "settings.hardwareYes" : "settings.hardwareNo")
                        } ?? TVL10n.value("settings.hardwareUnknown")
                    )
                    TVSettingsInfoRow(
                        title: "settings.hardwareFrame",
                        value: TVL10n.value(attempt.decodedFrame ?
                            "settings.hardwareFrameYes" : "settings.hardwareFrameNo")
                    )
                } else {
                    Text("settings.hardwareNoStream")
                        .font(.callout).foregroundStyle(TTTheme.muted)
                }
                TVSettingsReadableText(key: "settings.hardwareStreamNote")
            }
            Button("settings.reset") {
                allowSoftware = false
                maxHeight = 2160
                skipSeconds = 10
                bufferForwardSeconds = 180
                bufferBackSeconds = 120
                bufferCacheMiB = 512
                navigationAnimations = true
                thumbnailCacheMiB = 128
            }
            .buttonStyle(.bordered)
        }
    }

    private var languagePanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.languageControls") {
                TVSettingsMenuRow(
                    "settings.languagePicker", selection: $uiLanguage,
                    focus: $focusedControl, focusTarget: "control.language",
                    onMoveLeft: { returnFocusToGroup() }
                ) {
                    Text("language.system").tag(TVLanguages.followSystem)
                    ForEach(TVLanguages.available, id: \.self) { lang in
                        Text(TVLanguages.nativeName(lang)).tag(lang)
                    }
                }
            }
        }
    }

    private var accountPanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.savedAccountsTitle",
                           summary: "settings.savedAccountsHelp") {
                if accountLoading {
                    ProgressView("login.accountChecking")
                }

                if savedAccounts.isEmpty {
                    Label("settings.noSavedAccounts", systemImage: "person.crop.circle")
                        .foregroundStyle(TTTheme.muted)
                        .padding(.vertical, 14)
                } else {
                    ForEach(savedAccounts) { profile in
                        HStack(spacing: 20) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(TTTheme.accent)
                                .frame(width: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.label)
                                    .font(.title3.weight(.medium))
                                    .lineLimit(1)
                                if accountIdentity?.id == profile.id {
                                    Label("profiles.current", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer(minLength: 12)
                            Button(role: .destructive) {
                                lastRemovalID = profile.id
                                pendingProfileRemoval = profile
                                confirmProfileRemoval = true
                            } label: {
                                Label("settings.removeProfile", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("accounts-remove-\(profile.id)")
                            .focused($focusedControl, equals: "account.remove." + profile.id)
                            .onMoveCommand { direction in
                                if let index = savedAccounts.firstIndex(where: { $0.id == profile.id }) {
                                    if direction == .down {
                                        focusedControl = index + 1 < savedAccounts.count
                                            ? "account.remove." + savedAccounts[index + 1].id
                                            : "account.add"
                                    } else if direction == .up, index > 0 {
                                        focusedControl = "account.remove." + savedAccounts[index - 1].id
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        if profile.id != savedAccounts.last?.id { Divider() }
                    }
                }

                Divider()

                Button {
                    showAddAccountSheet = true
                } label: {
                    Label("profiles.add", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(TTTheme.accent)
                .accessibilityIdentifier("accounts-add")
                .focused($focusedControl, equals: "account.add")
                .onMoveCommand { direction in
                    if direction == .up, let last = savedAccounts.last {
                        focusedControl = "account.remove." + last.id
                    } else if direction == .down, accountIdentity?.isGuest == false {
                        focusedControl = "account.logout"
                    }
                }

                // Logging out differs from deleting a saved family profile:
                // it closes the active session, but keeps the account in
                // the local profile list for later sign-in/switching.
                if accountIdentity?.isGuest == false {
                    Button("settings.logout", role: .destructive) {
                        confirmLogout = true
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: "account.logout")
                }

                if let accountError {
                    Text(accountError)
                        .foregroundStyle(.orange)
                    Button("common.retry") {
                        Task { await refreshAccountIdentity() }
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: "account.retry")
                }
                if !status.isEmpty {
                    Text(status).foregroundStyle(TTTheme.muted)
                }
            }
        }
    }

    private var instancePanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.instanceControls") {
                TVSettingsInfoRow(title: "settings.instanceAddress", value: api.origin.absoluteString)
                if let info = instanceInfo {
                    TVSettingsInfoRow(title: "settings.instanceName", value: info.name)
                    TVSettingsInfoRow(title: "settings.instanceVersion", value: info.version)
                }
                if let instanceError {
                    Text(instanceError).foregroundStyle(.orange)
                }
                Button("common.refresh") { Task { await refreshInstance() } }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: "instance.refresh")
                Divider()
                if let fingerprint = TVServerTrust.shared.fingerprint(for: api.origin) {
                    Label("settings.certTrusted", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .lineLimit(4)
                    Button("settings.certForget") { confirmCertificateRemoval = true }
                        .buttonStyle(.bordered)
                }
                Button("settings.changeServer", action: onDisconnect)
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                if !status.isEmpty { Text(status).foregroundStyle(TTTheme.muted) }
            }
        }
    }

    private var compileTimeLabel: String {
        guard let date = ISO8601DateFormatter().date(from: TVBuildInfo.compiledAtUTC) else {
            return TVBuildInfo.compiledAtUTC
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
    }

    private var aboutPanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.aboutControls") {
                TVSettingsInfoRow(title: "settings.appName", value: "TypeType tvOS")
                    .focused($focusedControl, equals: "about.name")
                TVSettingsInfoRow(
                    title: "settings.appVersion",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? TVL10n.value("settings.developmentBuild")
                )
                TVSettingsInfoRow(title: "settings.gitRevision", value: TVBuildInfo.gitShortRevision)
                TVSettingsInfoRow(title: "settings.buildTime", value: compileTimeLabel)
                TVSettingsInfoRow(title: "settings.gitBranch", value: TVBuildInfo.gitBranch)
                TVSettingsInfoRow(title: "settings.platform", value: "Apple TV 4K · tvOS 26+")
                Text("settings.licenseInfo")
                    .font(.callout).foregroundStyle(TTTheme.muted)
            }
        }
    }

    @MainActor
    private func refreshRemote() async {
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            let sample = #"{"hideHomeRecommendations":false,"hideContinueWatching":false,"hideRelatedVideos":false,"hideShorts":true,"hideComments":false,"disableWatchHistory":false}"#
            remote = try? JSONDecoder().decode(TVServerSettings.self, from: Data(sample.utf8))
            remoteError = nil
            return
        }
        #endif
        guard !remoteLoading && !remoteSaving else { return }
        remoteLoading = true
        remoteError = nil
        defer { remoteLoading = false }
        do {
            remote = try await api.accountSettings()
        } catch {
            remoteError = error.localizedDescription
        }
        if group == .content && focusedControl == "content.retry" && remote != nil {
            focusedControl = firstTarget(for: .content)
        }
    }

    @MainActor
    private func setRemote(_ field: TVServerToggle, enabled: Bool) {
        guard var next = remote, !remoteSaving else { return }
        let previous = next
        next.setEnabled(field, enabled)
        remote = next
        remoteSaving = true
        remoteError = nil
        Task {
            do {
                remote = try await api.setAccountSetting(field.rawValue, value: .boolean(!enabled))
            } catch {
                remote = previous
                remoteError = error.localizedDescription
            }
            remoteSaving = false
        }
    }

    @MainActor
    private func refreshInstance() async {
        if api.origin.host == "preview.invalid" { return }
        do {
            instanceInfo = try await api.instance()
            instanceError = nil
        } catch {
            instanceError = error.localizedDescription
        }
    }

    @MainActor
    private func refreshAccountIdentity() async {
        savedAccounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
        if api.origin.host == "preview.invalid" {
            accountIdentity = nil
            accountError = nil
            return
        }
        guard !accountLoading else { return }
        accountLoading = true
        accountError = nil
        defer { accountLoading = false }
        do {
            accountIdentity = try await api.currentAccount()
            if let accountIdentity, !accountIdentity.isGuest {
                TypeTypeCredentials.shared.rememberActive(accountIdentity, for: api.origin)
            }
            savedAccounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
        } catch TypeTypeError.http(401, _) {
            // A stale bearer is a server rejection, not evidence that Apple
            // removed the locally stored account profiles during an update.
            accountIdentity = nil
            accountError = TVL10n.value("login.sessionExpired")
        } catch {
            // Keep the existing display state on transient network failures.
            accountError = error.localizedDescription
        }
    }

    @MainActor
    private func removePendingProfile() {
        guard let profile = pendingProfileRemoval else { return }
        pendingProfileRemoval = nil
        let credentials = TypeTypeCredentials.shared
        guard credentials.forget(profile.id, for: api.origin) else {
            status = TVL10n.value("settings.removeProfileFailed")
            return
        }
        if accountIdentity?.id == profile.id {
            // Forgetting the active profile must also clear the legacy
            // selected token. Otherwise refreshAccountIdentity would silently
            // re-add the deleted user on the next appearance.
            credentials.clear(for: api.origin)
            accountIdentity = nil
            accountError = nil
            TVLocalProgress.shared.clear()
            remote = nil
            onAccountChanged()
        }
        savedAccounts = credentials.savedAccounts(for: api.origin)
        status = TVL10n.value("settings.profileRemoved")
    }

    @MainActor
    private func logOut() {
        // Any new-account authentication runs exclusively inside the modal
        // and is cancelled when the modal closes.
        showAddAccountSheet = false
        if let accountIdentity, !accountIdentity.isGuest {
            // Logging out removes the selected user from this Apple TV, but
            // never wipes another household member's saved credentials.
            TypeTypeCredentials.shared.forget(accountIdentity.id, for: api.origin)
        }
        TypeTypeCredentials.shared.clear(for: api.origin)
        savedAccounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
        accountIdentity = nil
        accountError = nil
        onAccountChanged()
        TVLocalProgress.shared.clear()
        remote = nil
        remoteError = nil
        status = TypeTypeCredentials.shared.token(for: api.origin) == nil
            ? TVL10n.value("login.signedOut")
            : TVL10n.value("settings.logoutFailed")
    }
}
