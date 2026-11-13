import Foundation
import SwiftUI

struct PreferencesView: View {
    let api: TypeTypeAPI
    let onDisconnect: () -> Void
    @AppStorage("typetype.uiLanguage") private var uiLanguage = TVLanguages.defaultCode
    @AppStorage("typetype.allowSoftwareDecode") private var allowSoftware = false
    @AppStorage("typetype.maxHeight") private var maxHeight = 2160
    @AppStorage("typetype.skipSeconds") private var skipSeconds = 10
    @AppStorage("typetype.bufferForwardSeconds") private var bufferForwardSeconds = 180
    @AppStorage("typetype.bufferBackSeconds") private var bufferBackSeconds = 120
    @AppStorage("typetype.bufferCacheMiB") private var bufferCacheMiB = 512
    @State private var loginCode: String?
    @State private var loginLink: URL?
    @State private var status = ""
    @State private var poller: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("TYPE TYPE")
                        .font(.subheadline.bold()).tracking(2.2)
                        .foregroundStyle(TTTheme.accent)
                    Text("nav.settings").font(.system(size: 52, weight: .bold))
                    Text(TVL10n.formatted("common.serverValue", api.origin.host ?? ""))
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                }

                TVSettingsSection("settings.language", symbol: "globe",
                                  subtitle: "settings.languageHelp") {
                    Picker("settings.languagePicker", selection: $uiLanguage) {
                        Text("language.system").tag(TVLanguages.followSystem)
                        ForEach(TVLanguages.available, id: \.self) { code in
                            Text(TVLanguages.nativeName(code)).tag(code)
                        }
                    }
                    Text("settings.languageNote")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                }

                TVSettingsSection("settings.playback", symbol: "4k.tv",
                                  subtitle: "settings.playbackHelp") {
                    Toggle("settings.allowSoftware", isOn: $allowSoftware)
                    Text("settings.softwareWarning")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                    Picker("settings.maxResolution", selection: $maxHeight) {
                        Text("4K").tag(2160)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    }
                }

                TVSettingsSection("settings.remote", symbol: "hand.tap",
                                  subtitle: "settings.remoteHelp") {
                    Picker("settings.skipLength", selection: $skipSeconds) {
                        ForEach([5, 10, 15, 20], id: \.self) { value in
                            Text(TVL10n.formatted("common.seconds", value)).tag(value)
                        }
                    }
                }

                TVSettingsSection("settings.buffer", symbol: "externaldrive",
                                  subtitle: "settings.bufferHelp") {
                    Picker("settings.forwardBuffer", selection: $bufferForwardSeconds) {
                        ForEach([30, 60, 120, 180, 300, 600], id: \.self) { value in
                            Text("\(value) Sekunden").tag(value)
                        }
                    }
                    Picker("settings.backwardBuffer", selection: $bufferBackSeconds) {
                        ForEach([30, 60, 120, 180, 300], id: \.self) { value in
                            Text("\(value) Sekunden").tag(value)
                        }
                    }
                    Picker("settings.maxCache", selection: $bufferCacheMiB) {
                        ForEach([256, 512, 1024], id: \.self) { value in
                            Text("\(value) MiB").tag(value)
                        }
                    }
                    Text("settings.bufferWarning")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                }

                TVSettingsSection("settings.hardware", symbol: "cpu",
                                  subtitle: "settings.hardwareHelp") {
                    ForEach(["H.264", "HEVC", "VP9", "AV1"], id: \.self) { label in
                        let name: String = {
                            switch label {
                            case "H.264": return "avc1"
                            case "HEVC": return "hvc1"
                            case "VP9": return "vp09"
                            default: return "av01"
                            }
                        }()
                        HStack {
                            Text(label)
                            Spacer()
                            Label(
                                TVL10n.value(HardwareCodec.supported(name) ? "settings.hardwareYes" : "settings.hardwareNo"),
                                systemImage: HardwareCodec.supported(name) ? "checkmark.circle" : "minus.circle"
                            )
                            .foregroundStyle(
                                HardwareCodec.supported(name) ? .green : .orange
                            )
                        }
                        .font(.body)
                    }
                }

                TVSettingsSection("settings.account", symbol: "person.crop.circle",
                                  subtitle: "settings.accountHelp") {
                    if TypeTypeCredentials.shared.token(for: api.origin) != nil {
                        Label("settings.tokenSaved",
                              systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                        Button("settings.logout") {
                            TypeTypeCredentials.shared.clear(for: api.origin)
                            status = TVL10n.value("login.signedOut")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("settings.pair") {
                        poller?.cancel()
                        poller = Task { await startLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                    if let code = loginCode, let link = loginLink {
                        Text(TVL10n.formatted("login.deviceCode", code))
                            .font(.title.bold()).monospacedDigit()
                        Text(link.absoluteString)
                            .font(.callout)
                            .foregroundStyle(TTTheme.muted)
                        Text("settings.deviceHelp")
                            .font(.callout)
                    }
                    if !status.isEmpty {
                        Text(status).foregroundStyle(TTTheme.muted)
                    }
                    Divider()
                    Button("settings.changeServer", action: onDisconnect)
                        .buttonStyle(.bordered)
                }

                Button("settings.reset") {
                    allowSoftware = false
                    maxHeight = 2160
                    skipSeconds = 10
                    bufferForwardSeconds = 180
                    bufferBackSeconds = 120
                    bufferCacheMiB = 512
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: 1450)
            .padding(.horizontal, 80)
            .padding(.top, 55)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity)
        }
        .background(TTTheme.ink)
        .onDisappear { poller?.cancel() }
    }

    @MainActor
    private func startLogin() async {
        let service = SabrService(api: api)
        do {
            status = TVL10n.value("login.starting")
            let flow = try await service.deviceLoginStart()
            loginCode = flow.userCode
            var link = api.origin.appendingPathComponent("link")
            if var components = URLComponents(url: link, resolvingAgainstBaseURL: false) {
                components.queryItems = [URLQueryItem(name: "code", value: flow.userCode)]
                if let url = components.url { link = url }
            }
            loginLink = link
            status = TVL10n.value("login.waiting")
            let interval = UInt64(max(1, flow.interval)) * 1_000_000_000
            let maxPolls = max(1, flow.expiresIn / max(1, flow.interval))
            for _ in 0..<maxPolls {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: interval)
                let answer = try await service.deviceLoginPoll(flow.deviceCode)
                if let token = answer.accessToken, !token.isEmpty {
                    TypeTypeCredentials.shared.save(token, for: api.origin)
                    status = TVL10n.value("login.success")
                    loginCode = nil
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

private struct TVSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, symbol: String, subtitle: LocalizedStringKey,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 15) {
                Image(systemName: symbol)
                    .foregroundStyle(TTTheme.accent)
                    .font(.title2)
                Text(title).font(.title2.bold())
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(TTTheme.muted)
            Divider()
            content
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 24))
        .focusSection()
    }
}
