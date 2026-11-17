import SwiftUI

/// Concept B: the player OSD is a real tvOS focus surface. Keep transport
/// and SABR decoding independent from these controls.
struct TVPlayerOSD: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let artwork: TVChannelArtwork?
    @ObservedObject var engine: SabrPlayerController
    let skipSeconds: Int
    let clockMode: Bool
    let onClockMode: () -> Void
    let onActivity: () -> Void
    let onSkip: (Int) -> Void
    let onToggle: () -> Void
    let onSeek: (Int64) -> Void
    let onVideo: () -> Void
    let onAudio: () -> Void
    let onSubtitle: () -> Void
    let onSettings: () -> Void

    @AppStorage("typetype.osdDebug") private var showsDiagnostics = false
    @State private var scrubSeconds: Double?
    @State private var dragging = false
    @FocusState private var focusedItem: FocusItem?

    private enum FocusItem: Hashable {
        case timeline, backward, playPause, forward, video, audio, subtitles, settings
    }

    private var duration: Double {
        max(0, Double(engine.durationMs) / 1_000)
    }
    private var playback: Double {
        min(duration, max(0, engine.playbackSeconds()))
    }
    private var position: Double {
        min(duration, max(0, scrubSeconds ?? playback))
    }
    private var cacheAhead: Int {
        max(0, Int(Double(engine.cachedThroughMs) / 1_000 - playback))
    }
    private var rendererAhead: Int {
        max(0, Int(Double(engine.rendererReadyThroughMs) / 1_000 - playback))
    }
    private var channel: String? {
        let name = video.uploaderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 50)
            VStack(spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: engine.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundStyle(.white.opacity(0.9))
                    Text(engine.state)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    if showsDiagnostics {
                        Label("\(cacheAhead) s", systemImage: "externaldrive")
                        Label("\(rendererAhead) s", systemImage: "waveform.path")
                        Text(engine.selectionDescription)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 9)

                timeline
                controls
            }
            .padding(28)
            .background {
                RoundedRectangle(cornerRadius: 30)
                    .fill(.black.opacity(0.27))
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        }
        .padding(.horizontal, 80)
        .padding(.top, 54)
        .padding(.bottom, 58)
        .background {
            LinearGradient(colors: [.black.opacity(0.67), .clear,
                                    .clear, .black.opacity(0.77)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .transition(.opacity.combined(with: .offset(y: 14)))
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedItem = .playPause
            }
        }
        .onChange(of: focusedItem) { _, _ in
            // Browsing controls must postpone auto-hide even when playback
            // is running and the user has not clicked an option yet.
            onActivity()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text(video.title)
                    .font(.system(size: 41, weight: .semibold))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.35), radius: 8)
                HStack(spacing: 14) {
                    if let channel {
                        TVChannelAvatar(api: api, imageURL: artwork?.avatarURL, size: 47)
                        Text(channel)
                            .font(.system(size: 23, weight: .semibold))
                    }
                    if let details = TVVideoMetadata.subtitle(for: video) {
                        Text("· " + details)
                            .font(.system(size: 21))
                            .foregroundStyle(.white.opacity(0.80))
                            .lineLimit(1)
                    }
                }
                if let date = TVVideoMetadata.publicationDate(for: video) {
                    Text(date, format: .dateTime.day().month(.wide).year())
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.66))
                }
            }
            Spacer(minLength: 32)
            Button(action: onClockMode) {
                Label(TVL10n.value(clockMode ? "player.osdClock" : "player.osdElapsed"),
                      systemImage: clockMode ? "clock" : "timer")
                    .font(.system(size: 18, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.22))
            .accessibilityLabel(TVL10n.value("player.osdClockToggle"))
        }
    }

    private var timeline: some View {
        // The playback clock advances independently of @Published state.
        // Re-evaluate slider/time labels without polling the SABR transport.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 12) {
            if dragging {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill")
                    Text("player.osdScrubbing")
                    Text(TTTheme.time(Int(position))).monospacedDigit()
                    Spacer()
                    Text("player.osdSeekRelease")
                }
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.86))
                .transition(.opacity)
            }

            HStack(spacing: 23) {
                Text(leftTime)
                    .frame(width: 136, alignment: .trailing)
                    .monospacedDigit()
                TVOSSeekScrubber(
                    duration: duration, current: playback,
                    preview: $scrubSeconds,
                    sponsorSegments: engine.sponsorSegments,
                    skipSeconds: skipSeconds,
                    onPreviewChange: {
                        dragging = $0
                        if $0 { onActivity() }
                    },
                    onCommit: { seconds in
                        onSeek(Int64(seconds * 1_000))
                        scrubSeconds = nil
                        dragging = false
                    }
                )
                .accessibilityIdentifier("osd-timeline")
                Text(rightTime)
                    .frame(width: 136, alignment: .leading)
                    .monospacedDigit()
            }
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(.white)
            if !engine.sponsorSegments.isEmpty {
                HStack(spacing: 16) {
                    Image(systemName: "flag")
                    Text("SponsorBlock")
                    Circle().fill(.green).frame(width: 11, height: 11)
                    Text("Eigenwerbung")
                    Circle().fill(.orange).frame(width: 11, height: 11)
                    Text("Intro")
                    Circle().fill(.red).frame(width: 11, height: 11)
                    Text("Sponsor")
                    Spacer()
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, 155)
            }
            }
        }
    }

    private var leftTime: String {
        if clockMode {
            return Date().formatted(date: .omitted, time: .shortened)
        }
        return TTTheme.time(Int(position))
    }

    private var rightTime: String {
        if clockMode {
            return Date().addingTimeInterval(max(0, duration - position))
                .formatted(date: .omitted, time: .shortened)
        }
        return "-" + TTTheme.time(Int(max(0, duration - position)))
    }

    private var controls: some View {
        HStack(spacing: 18) {
            control("−\(skipSeconds) s", icon: "gobackward", focus: .backward) {
                onSkip(-1)
            }
            control(TVL10n.value(engine.isPlaying ? "player.osdPause" : "player.osdPlay"),
                    icon: engine.isPlaying ? "pause.fill" : "play.fill",
                    focus: .playPause, primary: true, action: onToggle)
            control("+\(skipSeconds) s", icon: "goforward", focus: .forward) {
                onSkip(1)
            }
            Spacer(minLength: 18)
            control(TVL10n.value("player.osdVideo"), icon: "tv",
                    focus: .video, action: onVideo)
            control(TVL10n.value("player.optionsAudio"), icon: "speaker.wave.2",
                    focus: .audio, action: onAudio)
            control(TVL10n.value("player.optionsSubtitles"), icon: "captions.bubble",
                    focus: .subtitles, action: onSubtitle)
            control(TVL10n.value("player.osdSettings"), icon: "gearshape",
                    focus: .settings, action: onSettings)
        }
    }

    private func control(_ title: String, icon: String, focus: FocusItem,
                         primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: primary ? 23 : 20, weight: .medium))
                .padding(.horizontal, primary ? 13 : 6)
                .frame(minHeight: 46)
        }
        .buttonStyle(.bordered)
        .tint(primary ? .white.opacity(0.55) : .white.opacity(0.22))
        .focused($focusedItem, equals: focus)
    }
}
