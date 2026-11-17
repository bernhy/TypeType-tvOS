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
    @State private var removedOverlay: Set<String> = []

    var body: some View {
        VStack(spacing: 24) {
            TVSettingsCard("settings.groupBlocked", summary: "settings.groupBlockedHelp") {
                Button("common.refresh") { Task { await reload() } }
                    .buttonStyle(.bordered)
                    .focused(focus, equals: "blocked.refresh")
                    .accessibilityIdentifier("blocked.refresh")
                    .onMoveCommand { direction in
                        if direction == .left {
                            onMoveLeft()
                        } else if direction == .down {
                            // In a long ScrollView, jump to the first enabled
                            // Unblock action rather than an unrelated rail.
                            if let first = videos.first(where: { $0.global != true }) {
                                focus.wrappedValue = unblockFocusID(.videos, first.id)
                            } else if let first = channels.first(where: { $0.global != true }) {
                                focus.wrappedValue = unblockFocusID(.channels, first.id)
                            } else {
                                focus.wrappedValue = "blocked.newKeyword"
                            }
                        }
                    }
                if loading { ProgressView("settings.remoteLoading") }
                if let error { Text(error).foregroundStyle(.orange) }
                if let status { Text(status).foregroundStyle(.green) }
            }
            TVSettingsCard("settings.blockedVideos") {
                if videos.isEmpty { Text("settings.blockedEmpty").foregroundStyle(TTTheme.muted) }
                ForEach(videos) { video in
                    entry(
                        video.name ?? TVBlockedNameCache.title(for: video.url, api: api)
                            ?? TVL10n.value("settings.blockedUnknownVideo"),
                        id: video.id, globallyBlocked: video.global == true,
                        category: .videos
                    )
                }
            }
            TVSettingsCard("settings.blockedChannels") {
                if channels.isEmpty { Text("settings.blockedEmpty").foregroundStyle(TTTheme.muted) }
                ForEach(channels) { channel in
                    entry(channel.name ?? TVL10n.value("settings.blockedUnknownChannel"),
                          id: channel.id,
                          globallyBlocked: channel.global == true, category: .channels)
                }
            }
            TVSettingsCard("settings.blockedKeywords") {
                Text("settings.blockedKeywordHelp")
                    .font(.callout)
                    .foregroundStyle(TTTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    TextField("settings.blockedKeywordPlaceholder", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused(focus, equals: "blocked.newKeyword")
                        .accessibilityIdentifier("blocked-keyword-input")
                        .onSubmit { Task { await addKeyword() } }
                        // tvOS otherwise sometimes searches sideways into
                        // the settings rail rather than continuing into the
                        // lower, offscreen keyword unblock rows.
                        .onMoveCommand { direction in
                            if direction == .down, let target = firstKeywordUnblockID {
                                focus.wrappedValue = target
                            } else if direction == .left {
                                onMoveLeft()
                            }
                        }
                    Button("settings.blockedAdd") { Task { await addKeyword() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .focused(focus, equals: "blocked.addKeyword")
                        .onMoveCommand { direction in
                            if direction == .down, let target = firstKeywordUnblockID {
                                focus.wrappedValue = target
                            } else if direction == .left {
                                focus.wrappedValue = "blocked.newKeyword"
                            }
                        }
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

    private func unblockFocusID(_ category: TVBlockedCategory, _ id: String) -> String {
        "blocked." + category.rawValue + "." + id
    }

    private var firstKeywordUnblockID: String? {
        keywords.first(where: { $0.global != true }).map {
            unblockFocusID(.keywords, $0.id)
        }
    }

    private func nextUserKeyword(after id: String, movingDown: Bool) -> String? {
        let candidates = keywords.filter { $0.global != true }.map(\.id)
        guard let index = candidates.firstIndex(of: id) else { return nil }
        let next = movingDown ? index + 1 : index - 1
        guard candidates.indices.contains(next) else { return nil }
        return unblockFocusID(.keywords, candidates[next])
    }

    private func entry(_ label: String, id: String, globallyBlocked: Bool,
                       category: TVBlockedCategory) -> some View {
        let token = category.rawValue + "|" + id
        let target = unblockFocusID(category, id)
        let rowFocused = focus.wrappedValue == target
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.callout).lineLimit(3)
                if category != .keywords {
                    Text("(" + TVBlockedNameCache.shortID(id, category: category) + ")")
                        .font(.caption).foregroundStyle(TTTheme.muted)
                }
            }
            if globallyBlocked {
                Label("settings.blockedGlobal", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            Spacer()
            Button("settings.blockedUnblock") {
                Task { await remove(id, category: category) }
            }
            .buttonStyle(.bordered)
            .disabled(globallyBlocked)
            .focused(focus, equals: target)
            .accessibilityIdentifier("blocked-unblock-" + token)
            .onMoveCommand { direction in
                if direction == .left {
                    onMoveLeft()
                } else if direction == .down {
                    if category == .videos, id == videos.last?.id,
                       let first = channels.first(where: { $0.global != true }) {
                        focus.wrappedValue = unblockFocusID(.channels, first.id)
                    } else if category == .channels, id == channels.last?.id {
                        focus.wrappedValue = "blocked.newKeyword"
                    } else if category == .keywords,
                              let next = nextUserKeyword(after: id, movingDown: true) {
                        focus.wrappedValue = next
                    }
                } else if direction == .up, category == .keywords {
                    focus.wrappedValue = nextUserKeyword(after: id, movingDown: false)
                        ?? "blocked.newKeyword"
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        // Highlight the entire record, but keep the actual tvOS focus on
        // its Unblock button (the row is not an additional focus target).
        .background(
            Color.white.opacity(rowFocused ? 0.13 : 0),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .animation(.easeOut(duration: 0.14), value: rowFocused)
        .overlay {
            if removedOverlay.contains(token) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.45))
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    Label("settings.blockedRemoved", systemImage: "checkmark.circle.fill")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    @MainActor
    private func reload() async {
        guard !loading, !saving else { return }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            videos = [TVBlockedItem(
                url: "https://youtu.be/ABCDEFGHIJK",
                name: "Gesperrtes Beispielvideo",
                thumbnailUrl: nil, blockedAt: nil, global: false
            )]
            channels = [TVBlockedItem(
                url: "https://www.youtube.com/channel/UC-preview",
                name: "Gesperrter Beispielkanal",
                thumbnailUrl: nil, blockedAt: nil, global: false
            )]
            keywords = [
                TVBlockedKeyword(keyword: "Beispielwort Eins",
                                 blockedAt: nil, global: false),
                TVBlockedKeyword(keyword: "Beispielwort Zwei",
                                 blockedAt: nil, global: false)
            ]
            return
        }
        #endif
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
        let token = category.rawValue + "|" + key
        guard !saving, !removedOverlay.contains(token) else { return }
        saving = true
        error = nil
        do {
            try await api.removeBlock(category, value: key)
            withAnimation(.easeOut(duration: 0.2)) {
                removedOverlay.insert(token)
            }
            // Keep the original row visible under its glass confirmation.
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut(duration: 0.2)) {
                switch category {
                case .videos: videos.removeAll { $0.url == key }
                case .channels: channels.removeAll { $0.url == key }
                case .keywords: keywords.removeAll { $0.keyword == key }
                }
                removedOverlay.remove(token)
            }
            if category == .videos {
                TVBlockedNameCache.remove(url: key, api: api)
            }
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
