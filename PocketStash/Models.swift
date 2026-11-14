import Foundation
import SwiftData
import CryptoKit

// MARK: - 播放历史

@Model
final class VideoScene {
    @Attribute(.unique) var key: String
    var title: String
    var site: String
    var mediaURL: String
    var bucket: String
    var addedAt: Date
    /// 重放时要补的 Referer（sm 站直链缺它就 404）
    var referer: String?

    init(key: String, title: String, site: String,
         mediaURL: String, bucket: String, addedAt: Date,
         referer: String? = nil) {
        self.key = key
        self.title = title
        self.site = site
        self.mediaURL = mediaURL
        self.bucket = bucket
        self.addedAt = addedAt
        self.referer = referer
    }
}

// MARK: - 站点配置（Sites.json 可改，无需动代码）

/// 三种源：
/// - cms  : 苹果CMS v10 JSON 接口，列表阶段就直出 m3u8/mp4
/// - html : 网页采集（神秘站群），标题 XOR-128，直链要进详情页解析
/// - web  : 必须靠 WKWebView 真浏览器渲染（Pornhub / OnlyFans 有风控与登录墙）
struct SiteConfig: Codable, Identifiable, Hashable {
    var id: String { name }

    let name: String
    var type: String?
    var apiBase: String?
    var cateId: String?
    var keyword: String?

    var listURL: String?
    var firstPageURL: String?
    var itemSelector: String?
    var titleSelector: String?
    var tagSelector: String?
    var thumbSelector: String?
    var titleDecode: Bool?
    var videoUrlTemplate: String?
    var vidPattern: String?
    var mediaPattern: String?

    var searchURL: String?
    var headers: [String: String]?
    var subRandom: Bool?
    var creator: String?

    var kind: String { (type ?? "html").lowercased() }
    var isCMS: Bool { kind == "cms" && !(apiBase ?? "").isEmpty }
    var isWeb: Bool { kind == "web" }
    var isHTML: Bool { kind == "html" && !(listURL ?? "").isEmpty }
}

enum SiteCatalog {
    static var cached: [SiteConfig] = []

    static func load() -> [SiteConfig] {
        if !cached.isEmpty { return cached }
        guard let url = Bundle.main.url(forResource: "Sites", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SiteConfig].self, from: data)
        else { return [] }
        cached = list.filter { !$0.name.isEmpty }
        return cached
    }

    static func reload() -> [SiteConfig] {
        cached = []
        return load()
    }

    static func find(_ name: String) -> SiteConfig? {
        load().first { $0.name == name }
    }
}

// MARK: - 工具

extension String {
    var md5: String {
        Insecure.MD5.hash(data: Data(utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var sanitized: String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        return components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }
}
