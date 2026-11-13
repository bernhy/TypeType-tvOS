import SwiftUI

struct VideoDetailView: View {
    let api: TypeTypeAPI
    let video: VideoItem

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 50) {
                AsyncImage(url: api.relativeMediaURL(video.thumbnailUrl)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Rectangle().fill(.gray.opacity(0.25))
                }
                .frame(width: 650)
                VStack(alignment: .leading, spacing: 25) {
                    Text(video.title).font(.largeTitle.bold())
                    Text(video.uploaderName ?? "").font(.title3).foregroundStyle(.secondary)
                    if video.isLive == true {
                        Text("Live").foregroundStyle(.red)
                    }
                    NavigationLink("Abspielen") {
                        PlaybackView(api: api, video: video)
                    }
                    Text("Dieser erste Prototyp spielt direkt verfügbare HLS-Streams mit AVPlayer ab. TypeType SABR wird im nächsten Schritt portiert.")
                        .font(.body).foregroundStyle(.secondary)
                }
            }
            .padding(70)
        }
        .navigationTitle("Video")
    }
}
