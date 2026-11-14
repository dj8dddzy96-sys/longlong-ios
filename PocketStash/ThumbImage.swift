import SwiftUI
import UIKit

enum ImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

/// 封面：带 Referer 取图（sm 站 CDN 会 404 无 Referer 的请求）
struct Thumb: View {
    let url: URL?
    let referer: String?

    @State private var image: UIImage?

    private var key: String { (url?.absoluteString ?? "") + "|" + (referer ?? "") }

    var body: some View {
        ZStack {
            Color.gray.opacity(0.18)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: key) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.object(forKey: key as NSString) {
            image = cached
            return
        }
        var req = URLRequest(url: url)
        req.setValue(Net.ua, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode < 400,
              let img = UIImage(data: data) else { return }
        ImageCache.shared.setObject(img, forKey: key as NSString)
        image = img
    }
}
