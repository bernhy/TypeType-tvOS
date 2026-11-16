import SwiftUI

/// User-owned blocked-content management, separate from moderator/global
/// policies. Parent Settings rail retains its usual focus handoff.
struct TVBlockedSettingsView: View {
    let api: TypeTypeAPI
    let focus: FocusState<String?>.Binding
    let onMoveLeft: () -> Void
    @State private var videos: [TVBlockedItem] = []
    @State private var channels: [TVBlockedItem] = []
    @State private var keywords: [TVBlockedKeyword] = []
    @State private var newKeyword = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var status: String?

    var body: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.groupBlocked", summary: "settings.groupBlockedHelp") {
                Button("common.refresh") { Task { await reload() } }
                    .buttonStyle(.bordered)
                    .focused(focus, equals: "blocked.refresh")
                    .onMoveCommand { if $0 == .left { onMoveLeft() } }
                if loading { ProgressView("settings.remoteLoading") }
                if let error { Text(error).foregroundStyle(.orange) }
                if let status { Text(status).foregroundStyle(.green) }
            }
            TVSettingsCard("settings.blockedVideos") {
                if videos.isEmpty { Text("settings.blockedEmpty").foregroundStyle(TTTheme.muted) }
                ForEach(videos) { video in
                    entry(video.name ?? video.url, id: video.id,
                          globallyBlocked: video.global == true, category: .videos)
                }
            }
            TVSettingsCard("settings.blockedChannels") {
                if channels.isEmpty { Text("settings.blockedEmpty").foregroundStyle(TTTheme.muted) }
                ForEach(channels) { channel in
                    entry(channel.name ?? channel.url, id: channel.id,
                          globallyBlocked: channel.global == true, category: .channels)
                }
            }
            TVSettingsCard("settings.blockedKeywords") {
                HStack(spacing: 16) {
                    TextField("settings.blockedKeywordPlaceholder", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused(focus, equals: "blocked.newKeyword")
                        .onSubmit { Task { await addKeyword() } }
                    Button("settings.blockedAdd") { Task { await addKeyword() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .focused(focus, equals: "blocked.addKeyword")
                        .onMoveCommand { if $0 == .left { onMoveLeft() } }
                }
                if keywords.isEmpty {
                    Text("settings.blockedEmpty").foregroundStyle(TTTheme.muted)
                }
                ForEach(keywords) { keyword in
                    entry(keyword.keyword, id: keyword.id,
                          globallyBlocked: keyword.global == true, category: .keywords)
                }
            }
        }
        .task(id: api.metadataCacheScope) { await reload() }
    }

    private func entry(_ label: String, id: String, globallyBlocked: Bool,
                       category: TVBlockedCategory) -> some View {
        HStack(spacing: 18) {
            Text(label).font(.callout).lineLimit(3)
            if globallyBlocked {
                Label("settings.blockedGlobal", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            Spacer()
            Button("settings.blockedUnblock") {
                Task { await remove(id, category: category) }
            }
            .buttonStyle(.bordered)
            .disabled(saving || globallyBlocked)
            .focused(focus, equals: "blocked." + category.rawValue + "." + id)
            .onMoveCommand { if $0 == .left { onMoveLeft() } }
        }
        .padding(.vertical, 7)
    }

    @MainActor
    private func reload() async {
        guard !loading, !saving else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let blockedVideos = api.blockedVideos()
            async let blockedChannels = api.blockedChannels()
            async let blockedKeywords = api.blockedKeywords()
            let (v, c, k) = try await (blockedVideos, blockedChannels, blockedKeywords)
            videos = v; channels = c; keywords = k
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func addKeyword() async {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(keyword.count), !saving else { return }
        saving = true
        error = nil
        do {
            try await api.addBlockedKeyword(keyword)
            newKeyword = ""
            status = TVL10n.value("settings.blockedSaved")
        } catch { self.error = error.localizedDescription }
        saving = false
        if error == nil { await reload() }
    }

    @MainActor
    private func remove(_ key: String, category: TVBlockedCategory) async {
        guard !saving else { return }
        saving = true
        error = nil
        do {
            try await api.removeBlock(category, value: key)
            status = TVL10n.value("settings.blockedRemoved")
        } catch { self.error = error.localizedDescription }
        saving = false
        if error == nil { await reload() }
    }
}
