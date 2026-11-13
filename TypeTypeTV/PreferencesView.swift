import Foundation
import SwiftUI

struct PreferencesView: View {
    let api: TypeTypeAPI
    let onDisconnect: () -> Void
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
                    Text("Einstellungen").font(.system(size: 52, weight: .bold))
                    Text("Server: \(api.origin.host ?? "")")
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                }

                TVSettingsSection("Bild und Wiedergabe", symbol: "4k.tv",
                                  subtitle: "Beste passende Hardwarequalität auswählen und Softwaredecoding nur bei Bedarf freigeben.") {
                    Toggle("Softwaredecoding ausdrücklich erlauben", isOn: $allowSoftware)
                    Text("Standardmäßig AUS. Nicht hardwarekompatible Codecs werden dadurch nicht automatisch gewählt.")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                    Picker("Maximale Videoauflösung", selection: $maxHeight) {
                        Text("4K").tag(2160)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    }
                }

                TVSettingsSection("Fernbedienung", symbol: "hand.tap",
                                  subtitle: "Touch zeigt die Statusleiste. Links/rechts springt, Play/Pause steuert die Wiedergabe.") {
                    Picker("Sprungweite", selection: $skipSeconds) {
                        ForEach([5, 10, 15, 20], id: \.self) { value in
                            Text("\(value) Sekunden").tag(value)
                        }
                    }
                }

                TVSettingsSection("SABR-Puffer", symbol: "externaldrive",
                                  subtitle: "Großer Cache auf deinem Apple TV. Der Server kann kleinere Segmentfenster liefern.") {
                    Picker("Vorladeziel (Video-on-Demand)", selection: $bufferForwardSeconds) {
                        ForEach([30, 60, 120, 180, 300, 600], id: \.self) { value in
                            Text("\(value) Sekunden").tag(value)
                        }
                    }
                    Picker("Rückwärtspuffer", selection: $bufferBackSeconds) {
                        ForEach([30, 60, 120, 180, 300], id: \.self) { value in
                            Text("\(value) Sekunden").tag(value)
                        }
                    }
                    Picker("Maximaler lokaler Cache", selection: $bufferCacheMiB) {
                        ForEach([256, 512, 1024], id: \.self) { value in
                            Text("\(value) MiB").tag(value)
                        }
                    }
                    Text("Das Vorladeziel ist keine garantierte Füllmenge. Der Cache enthält nur komprimierte Mediensegmente.")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                }

                TVSettingsSection("Hardwarefähigkeiten", symbol: "cpu",
                                  subtitle: "Gerätespezifische VideoToolbox-Erkennung. Profile, HDR und Framerates erfordern zusätzliche Tests.") {
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
                                HardwareCodec.supported(name) ? "Hardware erkannt" : "Nicht erkannt",
                                systemImage: HardwareCodec.supported(name) ? "checkmark.circle" : "minus.circle"
                            )
                            .foregroundStyle(
                                HardwareCodec.supported(name) ? .green : .orange
                            )
                        }
                        .font(.body)
                    }
                }

                TVSettingsSection("Konto und Server", symbol: "person.crop.circle",
                                  subtitle: "Verbinde dein TypeType-Konto mit einem Gerätecode oder wechsle die Instanz.") {
                    if TypeTypeCredentials.shared.token(for: api.origin) != nil {
                        Label("Ein Zugriffstoken ist im Apple-Schlüsselbund gespeichert.",
                              systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                        Button("Lokal abmelden") {
                            TypeTypeCredentials.shared.clear(for: api.origin)
                            status = "Lokale Anmeldung beendet"
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("TypeType-Konto mit Gerätecode koppeln") {
                        poller?.cancel()
                        poller = Task { await startLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                    if let code = loginCode, let link = loginLink {
                        Text("GERÄTECODE: \(code)")
                            .font(.title.bold()).monospacedDigit()
                        Text(link.absoluteString)
                            .font(.callout)
                            .foregroundStyle(TTTheme.muted)
                        Text("Öffne den Link auf deinem Telefon oder Computer und bestätige den Code.")
                            .font(.callout)
                    }
                    if !status.isEmpty {
                        Text(status).foregroundStyle(TTTheme.muted)
                    }
                    Divider()
                    Button("TypeType-Server wechseln", action: onDisconnect)
                        .buttonStyle(.bordered)
                }

                Button("Wiedergabeeinstellungen auf Standard zurücksetzen") {
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
            status = "Starte Geräteanmeldung …"
            let flow = try await service.deviceLoginStart()
            loginCode = flow.userCode
            var link = api.origin.appendingPathComponent("link")
            if var components = URLComponents(url: link, resolvingAgainstBaseURL: false) {
                components.queryItems = [URLQueryItem(name: "code", value: flow.userCode)]
                if let url = components.url { link = url }
            }
            loginLink = link
            status = "Warte auf Bestätigung …"
            let interval = UInt64(max(1, flow.interval)) * 1_000_000_000
            let maxPolls = max(1, flow.expiresIn / max(1, flow.interval))
            for _ in 0..<maxPolls {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: interval)
                let answer = try await service.deviceLoginPoll(flow.deviceCode)
                if let token = answer.accessToken, !token.isEmpty {
                    TypeTypeCredentials.shared.save(token, for: api.origin)
                    status = "Anmeldung erfolgreich"
                    loginCode = nil
                    return
                }
                if answer.code == "access_denied" || answer.code == "denied" {
                    status = "Anmeldung abgelehnt"
                    return
                }
            }
            status = "Code abgelaufen. Bitte erneut starten."
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct TVSettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, subtitle: String,
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
