import Foundation
import SwiftUI

/// Settings use Android's two-panel TV navigation: a focused group rail on
/// the left and large, comfortably selectable controls on the right.
/// Device options stay on Apple TV; content flags write to TypeType Server.
struct PreferencesView: View {
    let api: TypeTypeAPI
    let onDisconnect: () -> Void
    var onAccountChanged: () -> Void = {}

    @ObservedObject private var hardware = TVHardwareDiagnostics.shared
    @AppStorage("typetype.uiLanguage") private var uiLanguage = TVLanguages.defaultCode
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
    @State private var remote: TVServerSettings?
    @State private var remoteLoading = false
    @State private var remoteSaving = false
    @State private var remoteError: String?
    @State private var instanceInfo: InstanceInfo?
    @State private var instanceError: String?
    @State private var confirmCertificateRemoval = false
    @State private var confirmLogout = false
    @State private var username = ""
    @State private var password = ""
    @State private var passwordSigningIn = false
    @State private var accountIdentity: TVAccountIdentity?
    @State private var accountLoading = false
    @State private var accountError: String?
    @State private var changingAccount = false
    @State private var loginCode: String?
    @State private var loginLink: URL?
    @State private var status = ""
    @State private var poller: Task<Void, Never>?

    init(api: TypeTypeAPI, onDisconnect: @escaping () -> Void,
         initialGroup: TVSettingsGroup = .playback,
         onAccountChanged: @escaping () -> Void = {}) {
        self.api = api
        self.onDisconnect = onDisconnect
        self.onAccountChanged = onAccountChanged
        _group = State(initialValue: initialGroup)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 23) {
            groupRail
                .frame(width: 234)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TTTheme.ink)
        // Initial focus belongs to the selected settings category, not Home.
        .onAppear {
            if focusedGroup == nil { focusedGroup = group }
        }
        .task(id: group) {
            if group == .content && remote == nil { await refreshRemote() }
            if group == .instance && instanceInfo == nil { await refreshInstance() }
            if group == .account { await refreshAccountIdentity() }
        }
        .onChange(of: focusedGroup) { _, next in
            if let next { group = next }
        }
        .onDisappear { poller?.cancel() }
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
            Text("TYPE TYPE")
                .font(.subheadline.bold())
                .tracking(2.6)
                .foregroundStyle(TTTheme.accent)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            ForEach(TVSettingsGroup.allCases) { item in
                Button {
                    group = item
                    focusedGroup = item
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
                    .foregroundStyle(item == focusedGroup ? .white :
                                     (item == group ? TTTheme.accent : TTTheme.muted))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled(true)
                .focused($focusedGroup, equals: item)
                .accessibilityLabel(TVL10n.value(item.titleKey))
                .accessibilityAddTraits(item == group ? .isSelected : [])
            }
            Spacer(minLength: 20)
            Label("settings.deviceOnly", systemImage: "appletv")
                .font(.caption)
                .foregroundStyle(TTTheme.muted)
                .padding(.horizontal, 15)
        }
    }

    @ViewBuilder
    private var groupContent: some View {
        switch group {
        case .playback: playbackPanel
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
                Toggle("settings.allowSoftware", isOn: $allowSoftware)
                Text("settings.softwareWarning")
                    .font(.caption).foregroundStyle(TTTheme.muted)
                TVSettingsMenuRow("settings.maxResolution", selection: $maxHeight) {
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
                        Toggle(isOn: Binding(
                            get: { self.remote?.enabled(field) ?? remote.enabled(field) },
                            set: { setRemote(field, enabled: $0) }
                        )) {
                            Text(TVL10n.value(field.titleKey))
                        }
                        .disabled(remoteSaving)
                    }
                    if remoteSaving { ProgressView("settings.remoteSaving") }
                    Button("common.refresh") { Task { await refreshRemote() } }
                        .buttonStyle(.bordered)
                        .disabled(remoteSaving)
                } else {
                    Text(remoteError ?? TVL10n.value("settings.remoteLoginHelp"))
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                    Button("common.retry") { Task { await refreshRemote() } }
                        .buttonStyle(.bordered)
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
                TVSettingsMenuRow("settings.skipLength", selection: $skipSeconds) {
                    ForEach([5, 10, 15, 20], id: \.self) { seconds in
                        Text(TVL10n.formatted("common.seconds", seconds)).tag(seconds)
                    }
                }
            }
            TVSettingsCard("settings.buffer", summary: "settings.bufferHelp") {
                TVSettingsMenuRow("settings.forwardBuffer", selection: $bufferForwardSeconds) {
                    ForEach([30, 60, 120, 180, 300, 600], id: \.self) { seconds in
                        Text(TVL10n.formatted("common.seconds", seconds)).tag(seconds)
                    }
                }
                TVSettingsMenuRow("settings.backwardBuffer", selection: $bufferBackSeconds) {
                    ForEach([30, 60, 120, 180, 300], id: \.self) { seconds in
                        Text(TVL10n.formatted("common.seconds", seconds)).tag(seconds)
                    }
                }
                TVSettingsMenuRow("settings.maxCache", selection: $bufferCacheMiB) {
                    ForEach([256, 512, 1024], id: \.self) { amount in
                        Text("\(amount) MiB").tag(amount)
                    }
                }
                Text("settings.bufferWarning")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            TVSettingsCard("settings.performanceControls") {
                Toggle("settings.navigationAnimations", isOn: $navigationAnimations)
                Text("settings.navigationAnimationsHelp")
                    .font(.caption).foregroundStyle(TTTheme.muted)
                TVSettingsMenuRow("settings.imageCacheSize", selection: $thumbnailCacheMiB) {
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
                TVSettingsMenuRow("settings.languagePicker", selection: $uiLanguage) {
                    Text("language.system").tag(TVLanguages.followSystem)
                    ForEach(TVLanguages.available, id: \.self) { lang in
                        Text(TVLanguages.nativeName(lang)).tag(lang)
                    }
                }
                Text("settings.languageNote")
                    .font(.callout).foregroundStyle(TTTheme.muted)
            }
        }
    }

    private var accountPanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.accountControls") {
                if accountLoading {
                    ProgressView("login.accountChecking")
                }
                if let identity = accountIdentity {
                    if identity.isGuest {
                        Label("login.guestActive", systemImage: "person.crop.circle")
                            .foregroundStyle(TTTheme.muted)
                    } else {
                        Label("login.accountActive", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        let label = identity.visibleName
                            ?? TypeTypeCredentials.shared.displayIdentifier(for: api.origin)
                            ?? TVL10n.value("login.accountUnnamed")
                        Text(label)
                            .font(.title2.bold())
                            .lineLimit(2)
                            .accessibilityLabel(label)
                        HStack(spacing: 22) {
                            Button("settings.logout", role: .destructive) {
                                confirmLogout = true
                            }
                            .buttonStyle(.bordered)
                            Button("login.switchAccount") {
                                changingAccount = true
                                status = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else if !accountLoading && TypeTypeCredentials.shared.token(for: api.origin) == nil {
                    Label("login.notSignedIn", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(TTTheme.muted)
                }

                if let accountError {
                    Text(accountError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("common.retry") { Task { await refreshAccountIdentity() } }
                        .buttonStyle(.bordered)
                }

                // Guest sessions, signed-out devices and explicit account
                // switching can log in. Successful sign-in hides these fields.
                if !accountLoading &&
                    (accountIdentity == nil || accountIdentity?.isGuest == true || changingAccount) {
                    TextField("login.identifier", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("login.password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await passwordSignIn() } }
                    Button {
                        Task { await passwordSignIn() }
                    } label: {
                        if passwordSigningIn {
                            ProgressView()
                        } else {
                            Text("login.passwordButton")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(passwordSigningIn ||
                        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        password.isEmpty)
                    Divider()
                    Button("settings.pair") {
                        poller?.cancel()
                        poller = Task { await startLogin() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(passwordSigningIn)
                }

                if let code = loginCode, let link = loginLink {
                    Text(TVL10n.formatted("login.deviceCode", code))
                        .font(.title2.bold())
                        .monospacedDigit()
                    Text(link.absoluteString)
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                    Text("settings.deviceHelp").font(.callout)
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

    private var aboutPanel: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.aboutControls") {
                TVSettingsInfoRow(title: "settings.appName", value: "TypeType tvOS")
                TVSettingsInfoRow(
                    title: "settings.appVersion",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? TVL10n.value("settings.developmentBuild")
                )
                TVSettingsInfoRow(title: "settings.gitRevision", value: TVBuildInfo.gitShortRevision)
                TVSettingsInfoRow(title: "settings.gitBranch", value: TVBuildInfo.gitBranch)
                TVSettingsInfoRow(title: "settings.platform", value: "Apple TV 4K · tvOS 17+")
                Text("settings.licenseInfo")
                    .font(.callout).foregroundStyle(TTTheme.muted)
                Text("settings.playerExperimental")
                    .font(.caption).foregroundStyle(.orange)
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
        } catch {
            // Keep the existing display state on transient network failures.
            accountError = error.localizedDescription
        }
    }

    @MainActor
    private func logOut() {
        // Invalidate pending device-code polls before clearing credentials.
        // Otherwise an in-flight token response could sign us back in.
        poller?.cancel()
        poller = nil
        loginCode = nil
        loginLink = nil
        TypeTypeCredentials.shared.clear(for: api.origin)
        accountIdentity = nil
        accountError = nil
        changingAccount = false
        username = ""
        password = ""
        onAccountChanged()
        TVLocalProgress.shared.clear()
        remote = nil
        remoteError = nil
        status = TypeTypeCredentials.shared.token(for: api.origin) == nil
            ? TVL10n.value("login.signedOut")
            : TVL10n.value("settings.logoutFailed")
    }

    @MainActor
    private func passwordSignIn() async {
        guard !passwordSigningIn else { return }
        poller?.cancel()
        poller = nil
        loginCode = nil
        loginLink = nil
        passwordSigningIn = true
        status = TVL10n.value("login.passwordStarting")
        defer { passwordSigningIn = false; password = "" }
        do {
            let token = try await api.passwordLogin(identifier: username, password: password)
            TypeTypeCredentials.shared.save(token, for: api.origin)
            guard TypeTypeCredentials.shared.token(for: api.origin) == token else {
                status = TVL10n.value("settings.loginSaveFailed")
                return
            }
            TypeTypeCredentials.shared.saveDisplayIdentifier(
                username.trimmingCharacters(in: .whitespacesAndNewlines), for: api.origin
            )
            username = ""
            changingAccount = false
            TVLocalProgress.shared.clear()
            remote = nil
            status = TVL10n.value("login.success")
            await refreshAccountIdentity()
            onAccountChanged()
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor
    private func startLogin() async {
        let service = SabrService(api: api)
        do {
            status = TVL10n.value("login.starting")
            let flow = try await service.deviceLoginStart()
            try Task.checkCancellation()
            loginCode = flow.userCode
            var link = api.origin.appendingPathComponent("link")
            if var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) {
                parts.queryItems = [URLQueryItem(name: "code", value: flow.userCode)]
                if let url = parts.url { link = url }
            }
            loginLink = link
            status = TVL10n.value("login.waiting")
            let interval = UInt64(max(1, flow.interval)) * 1_000_000_000
            let maxPolls = max(1, flow.expiresIn / max(1, flow.interval))
            for _ in 0..<maxPolls {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: interval)
                let answer = try await service.deviceLoginPoll(flow.deviceCode)
                try Task.checkCancellation()
                if let token = answer.accessToken, !token.isEmpty {
                    TypeTypeCredentials.shared.save(token, for: api.origin)
                    changingAccount = false
                    username = ""
                    password = ""
                    TVLocalProgress.shared.clear()
                    status = TypeTypeCredentials.shared.token(for: api.origin) == token
                        ? TVL10n.value("login.success")
                        : TVL10n.value("settings.loginSaveFailed")
                    remote = nil
                    loginCode = nil
                    loginLink = nil
                    await refreshAccountIdentity()
                    onAccountChanged()
                    return
                }
                if answer.code == "access_denied" || answer.code == "denied" {
                    status = TVL10n.value("login.denied")
                    return
                }
            }
            status = TVL10n.value("login.expired")
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription
        }
    }
}
