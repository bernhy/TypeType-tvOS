import SwiftUI

/// tvOS focus-driven options, opened with Up/Down on the Siri Remote.
/// The remote capture layer is hidden while this sheet is presented.
struct SabrPlayerOptions: View {
    @ObservedObject var engine: SabrPlayerController
    let onQuality: (Int?) -> Void
    let onAudio: (SabrBootstrap.Audio) -> Void
    let onSubtitle: (SabrBootstrap.Subtitle?) -> Void
    let onClose: () -> Void

    private enum Section: Hashable {
        case quality, audio, subtitles
    }
    @State private var section: Section = .quality
    @State private var qualityCodec: SabrVideoCodecFamily?
    @FocusState private var focusedSection: Section?
    @FocusState private var focusedQualityRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Text("player.optionsTitle").font(.title2.bold())
                Spacer()
                Button("player.optionsClose", action: onClose)
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 14) {
                Button("player.optionsQuality") { section = .quality }
                    .buttonStyle(.bordered)
                    .tint(section == .quality ? TTTheme.accent : TTTheme.muted)
                    .focused($focusedSection, equals: .quality)
                Button("player.optionsAudio") { section = .audio }
                    .buttonStyle(.bordered)
                    .tint(section == .audio ? TTTheme.accent : TTTheme.muted)
                    .focused($focusedSection, equals: .audio)
                Button("player.optionsSubtitles") { section = .subtitles }
                    .buttonStyle(.bordered)
                    .tint(section == .subtitles ? TTTheme.accent : TTTheme.muted)
                    .focused($focusedSection, equals: .subtitles)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if section == .quality {
                        if let qualityCodec {
                            Button {
                                showCodecList()
                            } label: {
                                Label("player.optionsBackToCodecs", systemImage: "chevron.left")
                            }
                            .buttonStyle(.bordered)
                            .focused($focusedQualityRow, equals: "quality.back")
                            Text(qualityCodec.title + " · " +
                                 TVL10n.value("player.optionsVideoResolution"))
                                .font(.headline)
                                .padding(.top, 8)
                            ForEach(SabrVideoQualityGroups.variants(
                                codec: qualityCodec, from: engine.availableVideos,
                                selectedItag: engine.fixedVideoItag
                            ), id: \.itag) { track in
                                optionRow(
                                    "\(track.height ?? 0)p · \(track.fps ?? 0) fps",
                                    checked: engine.fixedVideoItag == track.itag
                                ) { onQuality(track.itag) }
                                .focused($focusedQualityRow, equals: "quality.video.\(track.itag)")
                            }
                        } else {
                            Text("player.optionsVideoCodec")
                                .font(.headline)
                            optionRow(
                                TVL10n.value("player.optionsAuto"),
                                checked: engine.fixedVideoItag == nil
                            ) { onQuality(nil) }
                            .focused($focusedQualityRow, equals: "quality.auto")
                            ForEach(SabrVideoQualityGroups.codecs(
                                from: engine.availableVideos
                            )) { codec in
                                optionRow(
                                    codec.title,
                                    checked: engine.fixedVideoItag.flatMap { id in
                                        engine.availableVideos.first { $0.itag == id }
                                            .flatMap { SabrVideoCodecFamily(codec: $0.codec) }
                                    } == codec
                                ) { openCodec(codec) }
                                .focused($focusedQualityRow, equals: "quality.codec.\(codec.rawValue)")
                            }
                        }
                    } else if section == .audio {
                        ForEach(
                            Array(engine.availableAudios.enumerated()),
                            id: \.offset
                        ) { item in
                            let track = item.element
                            optionRow(
                                track.audioTrackName ?? track.audioLocale ??
                                    "AAC · itag \(track.itag)",
                                checked: engine.currentAudioItag == track.itag &&
                                    engine.currentAudioTrackId == track.audioTrackId
                            ) { onAudio(track) }
                        }
                    } else {
                        optionRow(
                            TVL10n.value("player.optionsOff"),
                            checked: engine.selectedSubtitleURL == nil
                        ) { onSubtitle(nil) }
                        ForEach(engine.availableSubtitles, id: \.url) { track in
                            optionRow(
                                track.label + (track.isAutoGenerated == true ?
                                    " (" + TVL10n.value("player.optionsGenerated") + ")" : ""),
                                checked: engine.selectedSubtitleURL == track.url
                            ) { onSubtitle(track) }
                        }
                        if let failure = engine.subtitleError {
                            Text(failure)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(36)
        .frame(width: 790, height: 780)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onAppear {
            focusedQualityRow = "quality.auto"
        }
        .onExitCommand {
            if section == .quality, qualityCodec != nil {
                showCodecList()
            } else {
                onClose()
            }
        }
    }

    private func openCodec(_ codec: SabrVideoCodecFamily) {
        qualityCodec = codec
        focusedQualityRow = nil
        let choices = SabrVideoQualityGroups.variants(
            codec: codec, from: engine.availableVideos,
            selectedItag: engine.fixedVideoItag
        )
        Task { @MainActor in
            await Task.yield()
            if qualityCodec == codec {
                focusedQualityRow = choices.first.map { "quality.video.\($0.itag)" }
            }
        }
    }

    private func showCodecList() {
        guard let old = qualityCodec else { return }
        qualityCodec = nil
        focusedQualityRow = nil
        Task { @MainActor in
            await Task.yield()
            if qualityCodec == nil, section == .quality {
                focusedQualityRow = "quality.codec.\(old.rawValue)"
            }
        }
    }

    private func optionRow(_ label: String, checked: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label).lineLimit(1)
                Spacer()
                if checked { Image(systemName: "checkmark.circle.fill") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(checked ? TTTheme.accent : TTTheme.muted)
    }
}

    
/// The quality menu has only two levels: codec, then resolution.
/// Multiple representations of the same codec, height and frame rate are
/// deliberately folded into one choice; the ranked stream is preferred,
/// unless the user previously selected a different representation.
enum SabrVideoCodecFamily: String, CaseIterable, Identifiable {
    case av1, hevc, vp9, h264

    var id: String { rawValue }
    var title: String {
        switch self {
        case .av1: return "AV1"
        case .hevc: return "H.265 / HEVC"
        case .vp9: return "VP9"
        case .h264: return "H.264 / AVC"
        }
    }

    init?(codec: String) {
        let value = codec.lowercased()
        if value.hasPrefix("av01") { self = .av1 }
        else if value.hasPrefix("hvc") || value.hasPrefix("hev") { self = .hevc }
        else if value.hasPrefix("vp09") || value.hasPrefix("vp9") { self = .vp9 }
        else if value.hasPrefix("avc1") || value.hasPrefix("avc3") { self = .h264 }
        else { return nil }
    }
}

enum SabrVideoQualityGroups {
    static func codecs(from tracks: [SabrBootstrap.Video]) -> [SabrVideoCodecFamily] {
        let available = Set(tracks.compactMap { SabrVideoCodecFamily(codec: $0.codec) })
        return SabrVideoCodecFamily.allCases.filter { available.contains($0) }
    }

    static func variants(codec: SabrVideoCodecFamily,
                         from tracks: [SabrBootstrap.Video],
                         selectedItag: Int?) -> [SabrBootstrap.Video] {
        let eligible = tracks.filter { SabrVideoCodecFamily(codec: $0.codec) == codec }
        let sorted = eligible.sorted {
            if $0.height != $1.height { return ($0.height ?? 0) > ($1.height ?? 0) }
            if $0.fps != $1.fps { return ($0.fps ?? 0) > ($1.fps ?? 0) }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }
        var byResolution: [String: SabrBootstrap.Video] = [:]
        var order: [String] = []
        for track in sorted {
            let key = "\(track.height ?? 0):\(track.fps ?? 0)"
            if byResolution[key] == nil {
                byResolution[key] = track
                order.append(key)
            } else if track.itag == selectedItag {
                byResolution[key] = track
            }
        }
        return order.compactMap { byResolution[$0] }
    }
}
