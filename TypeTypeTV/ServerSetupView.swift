import SwiftUI

struct ServerSetupView: View {
    let onConfigured: (String) -> Void
    @State private var address = ""
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("TypeType")
                .font(.system(size: 64, weight: .bold))
            Text("Mit deiner TypeType-Instanz verbinden")
                .font(.title2)
            TextField("https://dein-server.example", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(isLoading ? "Verbinde …" : "Verbinden") {
                Task { await connect() }
            }
            .disabled(isLoading)
            if let message {
                Text(message).foregroundStyle(.orange).font(.body)
            }
            Text("Für den Start wird HTTPS und TypeType API v1 benötigt. Zugangsdaten werden nicht gespeichert.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(80)
    }

    @MainActor
    private func connect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let api = try TypeTypeAPI(address: address)
            try await api.validate()
            onConfigured(api.origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        } catch {
            message = error.localizedDescription
        }
    }
}
