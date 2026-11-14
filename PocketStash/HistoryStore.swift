import Foundation
import SwiftData

/// 播放历史（点过就记一条，重复点只更新时间）
final class HistoryStore {
    static let shared = HistoryStore()
    var container: ModelContainer?

    func remember(_ item: VideoItem) {
        guard let container, let media = item.mediaURL?.absoluteString else { return }
        let ctx = ModelContext(container)
        let id = item.id
        let fd = FetchDescriptor<VideoScene>(predicate: #Predicate { $0.key == id })
        if let old = try? ctx.fetch(fd).first {
            old.addedAt = .now
            old.mediaURL = media
            old.referer = item.referer
            try? ctx.save()
            return
        }
        let scene = VideoScene(
            key: id,
            title: item.title,
            site: item.site,
            mediaURL: media,
            bucket: Self.bucket(item.tags),
            addedAt: .now,
            referer: item.referer
        )
        ctx.insert(scene)
        try? ctx.save()
    }

    func clearAll() {
        guard let container else { return }
        let ctx = ModelContext(container)
        for s in (try? ctx.fetch(FetchDescriptor<VideoScene>())) ?? [] {
            ctx.delete(s)
        }
        try? ctx.save()
    }

    static func bucket(_ tags: [String]) -> String {
        let map: [(String, [String])] = [
            ("港台", ["港台", "台湾", "香港", "三级"]),
            ("韩国", ["韩国", "korea"]),
            ("日本", ["日本", "japan"]),
            ("欧美", ["欧美", "西方", "western"]),
            ("写真", ["写真", "热舞", "舞蹈"]),
            ("短剧", ["短剧", "擦边"]),
            ("两性", ["两性", "课堂"]),
        ]
        let lower = tags.map { $0.lowercased() }
        for (b, keys) in map where lower.contains(where: { t in keys.contains { $0.contains(t) } }) {
            return b
        }
        return "未分类"
    }
}
