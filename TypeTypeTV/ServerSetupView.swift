import SwiftUI

struct ServerSetupView: View {
    let onConfigured: (String) -> Void
    @AppStorage("typetype.lastServerOrigin") private var previousServer = ""
    @State private var address = ""
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        ZStack {
            TTTheme.ink.ignoresSafeArea()
            HStack(alignment: .center, spacing: 110) {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 20) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 78))
                            .foregroundStyle(TTTheme.accent)
                        Text("TypeType")
                            .font(.system(size: 76, weight: .bold))
                    }
                    Text("Deine Videos.\nDein Server.\nDein Apple TV.")
                        .font(.system(size: 46, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Verbinde dich mit deiner selbst gehosteten TypeType-Instanz.")
                        .font(.title3)
                        .foregroundStyle(TTTheme.muted)
                        .frame(maxWidth: 530, alignment: .leading)
                }
                .frame(maxWidth: 580, alignment: .leading)

                VStack(alignment: .leading, spacing: 28) {
                    Text("VERBINDUNG EINRICHTEN")
                        .font(.subheadline.bold()).tracking(2)
                        .foregroundStyle(TTTheme.accent)
                    Text("Serveradresse")
                        .font(.title.bold())
                    TextField("https://dein-server.example", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await connect() } }
                        .onChange(of: address) { message = nil }
                        .accessibilityLabel("TypeType HTTPS-Serveradresse")
                    Button {
                        Task { await connect() }
                    } label: {
                        Label(isLoading ? "Verbinde …" : "Mit TypeType verbinden",
                              systemImage: "network")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                    .disabled(isLoading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isLoading {
                        ProgressView("Prüfe TypeType API v1 …")
                    }
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Divider()
                    Text("HTTPS und eine kompatible TypeType-API-v1-Instanz werden benötigt. Anmeldetokens speichert die App geschützt im Apple-Schlüsselbund.")
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                }
                .padding(48)
                .frame(maxWidth: 730, alignment: .leading)
                .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 25))
                .focusSection()
            }
            .frame(maxWidth: 1500)
            .padding(70)
        }
        .onAppear {
            if address.isEmpty { address = previousServer }
        }
    }

    @MainActor
    private func connect() async {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let api = try TypeTypeAPI(address: address)
            let instance = try await api.instance()
            guard instance.apiVersion == 1 else {
                throw TypeTypeError.incompatibleServer(instance.apiVersion)
            }
            if instance.guestAllowed == true &&
                TypeTypeCredentials.shared.token(for: api.origin) == nil {
                try? await SabrService(api: api).guestLogin()
            }
            let configured = api.origin.absoluteString.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            previousServer = configured
            onConfigured(configured)
        } catch {
            message = error.localizedDescription
        }
    }
}
