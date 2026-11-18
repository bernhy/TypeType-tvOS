import SwiftUI
import AVFoundation
import Combine

/// Read-only comments. Created only while the Comments tab is selected:
/// opening a detail page never initiates an unnecessary comments fetch.
struct TVCommentsPanel: View {
    let api: TypeTypeAPI
    let videoURL: String
    @State private var comments: [TVCommentItem] = []
    @State private var nextPage: String?
    @State private var disabled = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var pageError: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if loading {
                ProgressView("video.commentsLoading")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            if disabled {
                Label("video.commentsDisabled", systemImage: "text.bubble.slash")
                    .foregroundStyle(TTTheme.muted)
            } else if let error {
                Text(error).foregroundStyle(.orange)
                Button("common.retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            } else if !loading && comments.isEmpty {
                Text("video.commentsEmpty")
                    .foregroundStyle(TTTheme.muted)
            }
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(comments) { comment in
                    TVCommentCard(api: api, videoURL: videoURL, comment: comment)
                }
            }
            .focusSection()
            if (nextPage != nil || loadingMore) && !disabled {
                Button {
                    Task { await more() }
                } label: {
                    HStack(spacing: 12) {
                        if loadingMore { ProgressView().controlSize(.small) }
                        Text("video.commentsLoadMore")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("video-comments-load-more")
                // Never remove/disable the focused button while paging:
                // tvOS otherwise jumps to the first comment.
            }
            if let pageError {
                Text(pageError).foregroundStyle(.orange)
                Button("common.retry") { Task { await more() } }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("video-comments-panel")
        .task(id: videoURL) { await load() }
        .onDisappear {
            // A slow page from this video must not populate a different video.
            requestID = UUID()
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        pageError = nil
        comments = []
        nextPage = nil
        disabled = false
        defer { if requestID == id { loading = false } }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            comments = [
                TVCommentItem(
                    id: "preview-comment", text: "Ein Beispielkommentar mit einer Antwort.",
                    author: "Beispielkanal", authorUrl: nil, authorAvatarUrl: nil,
                    likeCount: 10, textualLikeCount: "10",
                    publishedTime: "vor 1 Stunde", isHeartedByUploader: true,
                    isPinned: false, uploaderVerified: false,
                    replyCount: 1, repliesPage: nil, image: nil, voiceReply: nil
                )
            ]
            return
        }
        #endif
        do {
            let page = try await api.comments(videoURL: videoURL)
            guard requestID == id, !Task.isCancelled else { return }
            comments = page.comments
            disabled = page.commentsDisabled == true
            nextPage = page.nextpage?.isEmpty == false ? page.nextpage : nil
        } catch is CancellationError {
            return
        } catch {
            if requestID == id { self.error = error.localizedDescription }
        }
    }

    @MainActor
    private func more() async {
        guard !loadingMore, !loading, let cursor = nextPage else { return }
        let id = requestID
        loadingMore = true
        pageError = nil
        defer { if requestID == id { loadingMore = false } }
        do {
            let page = try await api.comments(videoURL: videoURL, nextpage: cursor)
            guard requestID == id, nextPage == cursor, !Task.isCancelled else { return }
            var known = Set(comments.map(\.id))
            comments += page.comments.filter { known.insert($0.id).inserted }
            disabled = page.commentsDisabled == true
            nextPage = page.nextpage == cursor ? nil : page.nextpage
        } catch is CancellationError {
            return
        } catch {
            if requestID == id { pageError = error.localizedDescription }
        }
    }
}

struct TVCommentCard: View {
    let api: TypeTypeAPI
    let videoURL: String
    let comment: TVCommentItem
    @State private var showReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            TVCommentContent(api: api, comment: comment)
            if (comment.replyCount ?? 0) > 0,
               let page = comment.repliesPage, !page.isEmpty {
                Button {
                    showReplies.toggle()
                } label: {
                    Label(
                        showReplies ? TVL10n.value("video.commentsHideReplies") :
                            TVL10n.formatted("video.commentsRepliesCount",
                                            comment.replyCount ?? 0),
                        systemImage: showReplies ? "chevron.up" : "bubble.left.and.bubble.right"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("video-comment-replies-" + comment.id)
                if showReplies {
                    TVCommentRepliesPanel(
                        api: api, videoURL: videoURL, firstPage: page
                    )
                    .padding(.leading, 36)
                }
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("video-comment-" + comment.id)
    }
}

struct TVCommentRepliesPanel: View {
    let api: TypeTypeAPI
    let videoURL: String
    let firstPage: String
    @State private var comments: [TVCommentItem] = []
    @State private var nextPage: String?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(comments) { comment in
                TVCommentContent(api: api, comment: comment)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            if loading { ProgressView("video.commentsLoading") }
            if let error {
                Text(error).foregroundStyle(.orange)
                Button("common.retry") {
                    Task { await fetch(nextPage ?? firstPage, reset: comments.isEmpty) }
                }
                .buttonStyle(.bordered)
            } else if let nextPage {
                Button {
                    Task { await fetch(nextPage, reset: false) }
                } label: {
                    HStack(spacing: 12) {
                        if loading { ProgressView().controlSize(.small) }
                        Text("video.commentsLoadMore")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .focusSection()
        .task(id: firstPage) { await fetch(firstPage, reset: true) }
        .onDisappear { requestID = UUID() }
    }

    @MainActor
    private func fetch(_ page: String, reset: Bool) async {
        guard !loading else { return }
        let id = UUID()
        requestID = id
        if reset { comments = []; nextPage = nil }
        error = nil
        loading = true
        defer { if requestID == id { loading = false } }
        do {
            let response = try await api.commentReplies(
                videoURL: videoURL, repliesPage: page
            )
            guard requestID == id, !Task.isCancelled else { return }
            var seen = Set(comments.map(\.id))
            comments += response.comments.filter { seen.insert($0.id).inserted }
            nextPage = response.nextpage == page ? nil : response.nextpage
        } catch is CancellationError {
            return
        } catch {
            if requestID == id { self.error = error.localizedDescription }
        }
    }
}

struct TVCommentContent: View {
    let api: TypeTypeAPI
    let comment: TVCommentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                Text(comment.author)
                    .font(.headline)
                if comment.uploaderVerified == true {
                    Image(systemName: "checkmark.seal.fill")
                        .accessibilityLabel("video.commentVerified")
                }
                Spacer()
                Text(comment.publishedTime ?? "")
                    .font(.caption)
                    .foregroundStyle(TTTheme.muted)
            }
            HStack(spacing: 18) {
                if comment.isPinned == true {
                    Label("video.commentPinned", systemImage: "pin.fill")
                }
                if comment.isHeartedByUploader == true {
                    Label("video.commentHearted", systemImage: "heart.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(TTTheme.muted)
            let plainText = TVCommentText.plain(comment.text)
            if !plainText.isEmpty {
                Text(plainText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let media = comment.image {
                if let imageURL = api.relativeMediaURL(media.url) {
                    TVThumbnail(url: imageURL, origin: api.origin)
                        .frame(maxWidth: 640, minHeight: 180, maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("video.commentImage")
                } else if let message = media.unavailableText, !message.isEmpty {
                    Label(message, systemImage: "photo.badge.exclamationmark")
                        .font(.callout).foregroundStyle(TTTheme.muted)
                }
            }
            if let voice = comment.voiceReply {
                TVCommentVoiceControl(api: api, reply: voice)
            }
            if let count = comment.textualLikeCount, !count.isEmpty {
                Label(count, systemImage: "hand.thumbsup")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .focusable(true)
        .focusEffectDisabled()
    }
}

struct TVCommentVoiceControl: View {
    let api: TypeTypeAPI
    let reply: TVCommentVoiceReply
    @StateObject private var playback = TVCommentVoicePlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if reply.playable {
                Button {
                    playback.toggle(api: api, reply: reply)
                } label: {
                    Label(
                        TVL10n.value(playback.isPlaying ? "video.commentVoiceStop" :
                                    "video.commentVoicePlay"),
                        systemImage: playback.isPlaying ? "stop.fill" : "waveform"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(playback.isLoading)
                .accessibilityIdentifier("video-comment-voice")
                if playback.isLoading {
                    ProgressView("video.commentVoiceLoading")
                }
                if let message = playback.error {
                    Text(message).font(.callout).foregroundStyle(.orange)
                }
            } else {
                Label(
                    reply.unavailableText ?? TVL10n.value("video.commentVoiceUnavailable"),
                    systemImage: "waveform.slash"
                )
                .font(.callout).foregroundStyle(TTTheme.muted)
            }
            if let transcript = reply.transcript, !transcript.isEmpty {
                Text(TVCommentText.plain(transcript))
                    .font(.callout).foregroundStyle(TTTheme.muted)
            }
        }
        .onDisappear { playback.stop() }
    }
}

@MainActor
final class TVCommentVoicePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0

    func toggle(api: TypeTypeAPI, reply: TVCommentVoiceReply) {
        if isPlaying { stop(); return }
        guard !isLoading else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        error = nil
        isLoading = true
        task = Task { @MainActor in
            defer {
                // The previous fetch may unwind after stop() and after a
                // new voice reply started loading. Never clear its state.
                if self.loadGeneration == generation {
                    self.isLoading = false
                    self.task = nil
                }
            }
            do {
                let bytes = try await api.commentVoiceAudio(watchURL: reply.url)
                try Task.checkCancellation()
                guard self.loadGeneration == generation else { return }
                let audio = try AVAudioPlayer(data: bytes)
                audio.delegate = self
                audio.prepareToPlay()
                guard audio.play() else { throw TypeTypeError.unavailableFormat }
                player = audio
                isPlaying = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        loadGeneration &+= 1
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        isLoading = false
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            // A late delegate callback from the old AVAudioPlayer must not
            // stop the new reply that was already started.
            guard let self, self.player === player else { return }
            self.player = nil
            self.isPlaying = false
        }
    }
}
