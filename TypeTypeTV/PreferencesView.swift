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
            VStack(alignment: .leading, spacing: 30) {
                Text("TypeType Einstellungen").font(.largeTitle.bold())
                Text("Server: \(api.origin.host ?? "")").foregroundStyle(.secondary)
                Toggle("Softwaredecoding erlauben (standardmäßig AUS)", isOn: $allowSoftware)
                Text("Ohne Freigabe akzeptiert TypeType nur Codecs, für die VideoToolbox Hardwaredecoding meldet.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Maximale Videoauflösung", selection: $maxHeight) {
                    Text("4K").tag(2160)
                    Text("1440p").tag(1440)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                Divider()
                Text("Fernbedienung und Puffer").font(.title2)
                Picker("Sprung bei Links-/Rechtsklick", selection: $skipSeconds) {
                    ForEach([5, 10, 15, 20], id: \.self) { value in
                        Text("\(value) Sekunden").tag(value)
                    }
                }
                Text("Berühren der Touchfläche blendet die Statusleiste ein. Links und rechts klicken springt um den eingestellten Wert.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Picker("Maximaler Cache für komprimierte Segmente", selection: $bufferCacheMiB) {
                    ForEach([256, 512, 1024], id: \.self) { value in
                        Text("\(value) MiB").tag(value)
                    }
                }
                Text("Standard: 180 Sekunden voraus, 120 Sekunden zurück, 512 MiB lokaler Cache. Der TypeType-Server kann kleinere SABR-Fenster liefern; wir erzwingen keine aggressiven Neuanfragen.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Hardwaredecoder dieses Gerätes").font(.title2)
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
                        Text(HardwareCodec.supported(name) ? "Hardware erkannt" : "Hardware nicht erkannt")
                            .foregroundStyle(HardwareCodec.supported(name) ? .green : .orange)
                    }
                }
                Text("Eine Codec-Erkennung allein bestätigt noch nicht alle Profile, Framerates und HDR-Modi. Dafür sind zusätzliche Tests auf dem Apple TV erforderlich.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Anmeldung").font(.title2)
                if TypeTypeCredentials.shared.token(for: api.origin) != nil {
                    Text("Anmeldetoken im System-Schlüsselbund gespeichert.")
                    Button("Lokal abmelden") {
                        TypeTypeCredentials.shared.clear(for: api.origin)
                        status = "Abgemeldet"
                    }
                }
                Button("TypeType-Konto mit Gerätecode verbinden") {
                    poller?.cancel()
                    poller = Task { await startLogin() }
                }
                if let code = loginCode, let link = loginLink {
                    Text("Gerätecode: \(code)").font(.title)
                    Text(link.absoluteString)
                    Text("Öffne den Link auf einem Telefon oder Computer und bestätige den Gerätecode.")
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                Button("Server wechseln", action: onDisconnect)
            }
            .padding(60)
        }
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
