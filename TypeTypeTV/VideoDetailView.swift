import SwiftUI

struct VideoDetailView: View {
    let api: TypeTypeAPI
    let video: VideoItem

    private var youtube: Bool { VideoAddress.youtubeID(video.url) != nil }

    var body: some View {
        ScrollView {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    AsyncImage(url: api.relativeMediaURL(video.thumbnailUrl)) { image in
                        image.resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } placeholder: { TTTheme.surface }

                    LinearGradient(
                        stops: [
                            .init(color: TTTheme.ink, location: 0),
                            .init(color: TTTheme.ink.opacity(0.94), location: 0.36),
                            .init(color: TTTheme.ink.opacity(0.22), location: 1)
                        ], startPoint: .leading, endPoint: .trailing
                    )
                    LinearGradient(colors: [.clear, TTTheme.ink],
                                   startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 22) {
                        Text(video.isLive == true ? "LIVE" : "VIDEO")
                            .font(.subheadline.bold()).tracking(2.5)
                            .foregroundStyle(TTTheme.accent)
                        Text(video.title)
                            .font(.system(size: 53, weight: .bold))
                            .lineLimit(3)
                            .frame(maxWidth: 830, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let channel = video.uploaderName, !channel.isEmpty {
                            Label(channel, systemImage: "person.crop.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        HStack(spacing: 22) {
                            if video.isLive == true {
                                Label("Livestream", systemImage: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(TTTheme.accent)
                            } else if let seconds = video.duration, seconds > 0 {
                                Label(TTTheme.time(seconds), systemImage: "clock")
                            }
                            Text(youtube ? "YouTube · SABR" : "TypeType · nativer Player")
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.72))
                        HStack(spacing: 22) {
                            NavigationLink {
                                PlaybackView(api: api, video: video)
                            } label: {
                                Label(video.isLive == true ? "Live ansehen" : "Abspielen",
                                      systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(TTTheme.accent)

                            NavigationLink {
                                PlaybackView(api: api, video: video)
                            } label: {
                                Label("Im Player öffnen", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                        }
                        .focusSection()
                    }
                    .padding(.leading, 90)
                    .padding(.top, 110)
                }
            }
            .frame(height: 690)
            .clipped()

            VStack(alignment: .leading, spacing: 18) {
                Text("ÜBER DIESES VIDEO")
                    .font(.subheadline.bold()).tracking(1.8)
                    .foregroundStyle(TTTheme.muted)
                Text(video.title)
                    .font(.title2.bold())
                Text(youtube
                     ? "Wiedergabe über die bestehende SABR-Schnittstelle deines TypeType-Servers. Die native tvOS-Wiedergabe wird noch auf echter Hardware erprobt."
                     : "Wiedergabe mit den nativen Video-Funktionen von Apple TV, sofern die Quelle ein kompatibles Format bereitstellt.")
                    .font(.body)
                    .foregroundStyle(TTTheme.muted)
                    .frame(maxWidth: 960, alignment: .leading)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 110)
        }
        .background(TTTheme.ink)
    }
}
