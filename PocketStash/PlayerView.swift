import SwiftUI
import AVKit
import AVFoundation

/// AVPlayer 播放页：m3u8 原生支持；sm 站直链必须带详情页 Referer，否则 404
struct PlayerView: View {
    let url: URL
    let referer: String?
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer

    init(url: URL, referer: String? = nil) {
        self.url = url
        self.referer = referer
        _player = State(initialValue: AVPlayer(playerItem: PlayerView.makeItem(url, referer)))
    }

    static func makeItem(_ url: URL, _ referer: String?) -> AVPlayerItem {
        var opts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": Net.ua,
                "Referer": referer ?? url.absoluteString
            ]
        ]
        opts[AVURLAssetPreferPreciseDurationAndTimingKey] = false
        let asset = AVURLAsset(url: url, options: opts)
        return AVPlayerItem(asset: asset)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                player.pause()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(.leading, 12)
            .padding(.top, 8)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
