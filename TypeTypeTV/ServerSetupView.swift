import SwiftUI

struct ServerSetupView: View {
    let onConfigured: (String) -> Void
    @AppStorage("typetype.lastServerOrigin") private var previousServer = ""
    @State private var host = ""
    @State private var mode: TVConnectionMode = .https
    @State private var isLoading = false
    @State private var message: String?
    @State private var certificate: TVCertificateReport?

    var body: some View {
        ZStack {
            TTTheme.ink.ignoresSafeArea()
            HStack(alignment: .center, spacing: 85) {
                VStack(alignment: .leading, spacing: 27) {
                    HStack(spacing: 17) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(TTTheme.accent)
                        Text("TypeType")
                            .font(.system(size: 72, weight: .bold))
                    }
                    Text("setup.tagline")
                        .font(.system(size: 44, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("setup.welcome")
                        .font(.title3)
                        .foregroundStyle(TTTheme.muted)
                        .frame(maxWidth: 510, alignment: .leading)
                }
                .frame(maxWidth: 550, alignment: .leading)

                VStack(alignment: .leading, spacing: 23) {
                    Text("setup.kicker")
                        .font(.subheadline.bold()).tracking(2.0)
                        .foregroundStyle(TTTheme.accent)
                    Text("setup.serverAddress")
                        .font(.title.bold())

                    Picker("setup.protocol", selection: $mode) {
                        Text("HTTPS · TLS").tag(TVConnectionMode.https)
                        Text("setup.httpLocal").tag(TVConnectionMode.http)
                    }
                    .accessibilityLabel("setup.protocol")

                    HStack(spacing: 14) {
                        Text(mode == .https ? "https://" : "http://")
                            .font(.body.monospaced())
                            .foregroundStyle(TTTheme.muted)
                        TextField("server.local:8080", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await connect() } }
                            .onChange(of: host) { value in
                                normalizePastedURL(value)
                                message = nil
                            }
                            .accessibilityLabel("setup.hostAccessibility")
                    }
                    .focusSection()

                    if mode == .http {
                        Label("setup.insecureWarning",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Label("setup.certificateHint",
                              systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(TTTheme.muted)
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        Label {
                            if isLoading { Text("setup.connectBusy") }
                            else { Text("setup.connect") }
                        } icon: {
                            Image(systemName: "network")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                    .disabled(isLoading || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isLoading { ProgressView("setup.connectProgress") }
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Divider()
                    Text("setup.keyboardHelp")
                        .font(.caption)
                        .foregroundStyle(TTTheme.muted)
                }
                .padding(42)
                .frame(maxWidth: 745, alignment: .leading)
                .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                .focusSection()
            }
            .frame(maxWidth: 1500)
            .padding(70)
        }
        .onAppear {
            if host.isEmpty && !previousServer.isEmpty {
                host = TVServerAddress.hostInput(from: previousServer)
                if previousServer.lowercased().hasPrefix("http://") {
                    mode = .http
                }
            }
        }
        .sheet(item: $certificate) { report in
            certificateAlert(report)
        }
    }

    private func normalizePastedURL(_ value: String) {
        let lower = value.lowercased()
        if lower.hasPrefix("https://") {
            mode = .https
            host = String(value.dropFirst(8))
        } else if lower.hasPrefix("http://") {
            mode = .http
            host = String(value.dropFirst(7))
        }
    }

    private func certificateAlert(_ report: TVCertificateReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                Label("certificate.title", systemImage: "exclamationmark.shield")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.orange)
                Text("certificate.untrusted")
                    .font(.title3)
                Text(TVL10n.formatted("certificate.connectionValue", report.origin.host ?? "", report.origin.port ?? 443))
                    .font(.headline)
                Text(TVL10n.formatted("certificate.subjectValue", report.subject))
                    .font(.headline)
                Text(report.problem)
                    .foregroundStyle(.orange)

                Text("certificate.fingerprint")
                    .font(.title3.bold())
                Text(report.formattedFingerprint)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                Text("certificate.chain")
                    .font(.title3.bold())
                ForEach(Array(report.chain.enumerated()), id: \.offset) { index, name in
                    Text("\(index + 1). \(name)")
                        .font(.callout)
                }
                Text("certificate.warning")
                    .font(.callout)
                    .foregroundStyle(TTTheme.muted)
                HStack(spacing: 23) {
                    Button("common.cancel") { certificate = nil }
                        .buttonStyle(.bordered)
                    Button("certificate.approve") {
                        if TVServerTrust.shared.approve(report) {
                            certificate = nil
                            Task { await connect() }
                        } else {
                            message = TVL10n.value("certificate.saveFailed")
                            certificate = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(70)
            .frame(maxWidth: 1250, alignment: .leading)
        }
    }

    @MainActor
    private func connect() async {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        var attempted: URL?
        do {
            let origin = try TVServerAddress.make(hostInput: host, mode: mode)
            attempted = origin
            TVServerTrust.shared.clearPending(for: origin)
            let api = try TypeTypeAPI(address: origin.absoluteString)
            let instance = try await api.instance()
            guard instance.apiVersion == 1 else {
                throw TypeTypeError.incompatibleServer(instance.apiVersion)
            }
            if instance.guestAllowed == true &&
                TypeTypeCredentials.shared.token(for: origin) == nil {
                try? await SabrService(api: api).guestLogin()
            }
            let configured = origin.absoluteString.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            previousServer = configured
            onConfigured(configured)
        } catch {
            if let attempted, let warning = TVServerTrust.shared.report(for: attempted) {
                certificate = warning
            } else {
                message = error.localizedDescription
            }
        }
    }
}
