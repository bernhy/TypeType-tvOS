import SwiftUI

/// Edit an account playlist without resetting its existing video order or
/// description. The server's PUT /playlists/{id} only mutates metadata.
struct TVPlaylistRenameView: View {
    let api: TypeTypeAPI
    let playlistID: String
    let initialName: String
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("action.renamePlaylist").font(.title.bold())
            TextField("action.newPlaylist", text: $name)
                .autocorrectionDisabled()
            HStack(spacing: 20) {
                Button("common.cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("action.savePlaylist") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if busy { ProgressView() }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(46)
        .frame(width: 760)
        .background(TTTheme.ink)
        .task {
            name = initialName
            do {
                let current = try await api.playlist(playlistID)
                guard !Task.isCancelled else { return }
                name = current.name
                description = current.description ?? ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func save() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await api.renamePlaylist(
                playlistID, name: name, description: description
            )
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
