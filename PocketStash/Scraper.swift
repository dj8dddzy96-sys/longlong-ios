import Foundation

struct VideoItem: Identifiable, Hashable {
    let id: String
    let site: String
    let title: String
    let mediaURL: URL?
    let thumbURL: URL?
    let tags: [String]
    /// 详情页地址：html/web 站点解析直链要用，也是封面的 Referer
    let pageURL: String
    /// 播放与取图时必须带的 Referer（null 表示不需要）
    let referer: String?

    init(id: String, site: String, title: String,
         mediaURL: URL?, thumbURL: URL?, tags: [String],
         pageURL: String = "", referer: String? = nil) {
        self.id = id
        self.site = site
        self.title = title
        self.mediaURL = mediaURL
        self.thumbURL = thumbURL
        self.tags = tags
        self.pageURL = pageURL
        self.referer = referer
    }

    func media(_ url: URL, referer: String?) -> VideoItem {
        VideoItem(id: id, site: site, title: title, mediaURL: url,
                  thumbURL: thumbURL, tags: tags, pageURL: pageURL, referer: referer)
    }
}

/// 三种源统一入口：
/// - cms  : 苹果CMS v10，列表阶段就带直链
/// - html : 网页采集（神秘站群），详情页解析 m3u8，播放要 Referer
/// - web  : WKWebView 渲染（Pornhub / OnlyFans）
final class Scraper {
    let cfg: SiteConfig
    init(cfg: SiteConfig) { self.cfg = cfg }

    private var base: String {
        (cfg.apiBase ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var cate: String { cfg.cateId ?? "" }
    private var kw: String { (cfg.keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var headers: [String: String] { cfg.headers ?? [:] }

    private var sub: String { cfg.subRandom == true ? SmPool.randomSub() : "" }

    private func u(_ s: String) -> String {
        var r = s
        if cfg.subRandom == true {
            r = r.replacingOccurrences(of: "{sub}", with: sub)
            r = r.replacingOccurrences(of: "{host}", with: SmPool.currentHost)
        }
        if let c = cfg.creator, !c.isEmpty {
            r = r.replacingOccurrences(of: "{creator}", with: c)
        }
        return r
    }

    // MARK: - 列表

    func list(page: Int = 1) async throws -> [VideoItem] {
        if cfg.isCMS { return try await cmsList(page: page) }

        guard let raw = cfg.listURL, !raw.isEmpty else { throw URLError(.badURL) }
        var tpl = raw
        if page == 1, let first = cfg.firstPageURL, !first.isEmpty { tpl = first }
        let url = u(tpl.replacingOccurrences(of: "{page}", with: String(page)))
        guard let parsed = URL(string: url) else { throw URLError(.badURL) }

        if cfg.isWeb {
            let html = try await WebLoader.shared.html(url, headers: headers,
                                                       waitSelector: cfg.itemSelector,
                                                       scroll: true)
            return parseItems(html, base: url)
        }
        let html = try await Net.text(url, headers: headers)
        return parseItems(html, base: url)
    }

    // MARK: - 搜索

    func search(_ keyword: String, page: Int = 1) async throws -> [VideoItem] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        if cfg.isCMS {
            let t = cate.isEmpty ? "" : "&t=" + cate
            let url = base + "/api.php/provide/vod/?ac=videolist&wd=" + Net.enc(q)
                + "&pg=" + String(page) + t
            return try parseCms(try await Net.text(url, headers: headers))
        }

        guard let tpl = cfg.searchURL, !tpl.isEmpty else {
            throw NSError(domain: "Scraper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "这个源不支持搜索"])
        }
        let url = u(tpl.replacingOccurrences(of: "{q}", with: Net.enc(q))
                       .replacingOccurrences(of: "{page}", with: String(page)))

        if cfg.isWeb {
            let html = try await WebLoader.shared.html(url, headers: headers,
                                                       waitSelector: cfg.itemSelector,
                                                       scroll: true)
            return parseItems(html, base: url)
        }
        // 神秘站 /so.html 只吃 POST，GET 一律空列表
        if cfg.subRandom == true || url.hasSuffix("/so.html") {
            let html = try await Net.form(url, params: ["wd": q], headers: headers)
            return parseItems(html, base: url)
        }
        let html = try await Net.text(url, headers: headers)
        return parseItems(html, base: url)
    }

    // MARK: - 直链解析

    func resolve(_ item: VideoItem) async throws -> VideoItem {
        if let m = item.mediaURL { return item }

        if cfg.isCMS {
            guard !base.isEmpty, !item.pageURL.isEmpty else { throw URLError(.badURL) }
            let url = base + "/api.php/provide/vod/?ac=detail&ids=" + item.pageURL
            let raw = try await Net.text(url, headers: headers)
            if let first = try parseCms(raw).first, let m = first.mediaURL {
                return item.media(m, referer: nil)
            }
            throw NSError(domain: "Scraper", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "CMS 没给出直链"])
        }

        let page = item.pageURL
        guard !page.isEmpty else { throw URLError(.badURL) }

        var h = headers
        let referer = h["Referer"] ?? page
        if h["Referer"] == nil { h["Referer"] = page }

        let html: String
        if cfg.isWeb {
            html = try await WebLoader.shared.html(page, headers: h, waitSelector: nil, scroll: false)
        } else {
            html = try await Net.text(page, headers: h, useCache: false)
        }

        if let tpl = cfg.videoUrlTemplate, !tpl.isEmpty {
            let pat = (cfg.vidPattern?.isEmpty == false) ? cfg.vidPattern! : "data-id=\"(\\d+)\""
            if let vid = HTML.firstGroup(pat, in: html) {
                let s = tpl.replacingOccurrences(of: "{vid}", with: vid)
                if let url = URL(string: s) { return item.media(url, referer: referer) }
            }
        }

        if let pat = cfg.mediaPattern, !pat.isEmpty,
           let raw = HTML.firstGroup(pat, in: html),
           let url = URL(string: HTML.unescapeURL(raw)) {
            return item.media(url, referer: referer)
        }

        for prop in ["og:video:url", "og:video:secure_url", "og:video"] {
            let pat = "<meta[^>]+property=\"" + prop + "\"[^>]+content=\"([^\"]+)\""
            if let s = HTML.firstGroup(pat, in: html), let url = URL(string: s) {
                return item.media(url, referer: referer)
            }
        }

        let patterns = [
            "(https?:[^\"'\\s]+?\\.m3u8[^\"'\\s]*)",
            "(https?:[^\"'\\s]+?\\.mp4[^\"'\\s]*)",
            "(https?:[^\"'\\s]+?\\.mkv[^\"'\\s]*)",
            "(https?:[^\"'\\s]+?\\.webm[^\"'\\s]*)"
        ]
        for pat in patterns {
            if let raw = HTML.firstGroup(pat, in: html),
               let url = URL(string: HTML.unescapeURL(raw)) {
                return item.media(url, referer: referer)
            }
        }
        throw NSError(domain: "Scraper", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "详情页里没找到直链"])
    }

    // MARK: - 苹果CMS v10

    private func cmsList(page: Int) async throws -> [VideoItem] {
        guard !base.isEmpty else { throw URLError(.badURL) }
        var s = base + "/api.php/provide/vod/?ac=videolist&pg=" + String(page)
        // 题材源用 wd= 搜索代替 t= 分类，「黑丝/户外」这类题材也能当分类点
        if !kw.isEmpty {
            s += "&wd=" + Net.enc(kw)
        } else if !cate.isEmpty {
            s += "&t=" + cate
        }
        return try parseCms(try await Net.text(s, headers: headers))
    }

    private func parseCms(_ raw: String) throws -> [VideoItem] {
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["list"] as? [[String: Any]]
        else { return [] }

        var out: [VideoItem] = []
        out.reserveCapacity(list.count)
        for o in list {
            let vid = str(o["vod_id"])
            guard !vid.isEmpty else { continue }
            guard let media = Self.pickMedia(str(o["vod_play_url"])) else { continue }
            let name = str(o["vod_name"])
            let pic = str(o["vod_pic"])
            var tags: [String] = []
            let tn = str(o["type_name"])
            if !tn.isEmpty { tags.append(tn) }
            let rm = str(o["vod_remarks"])
            if !rm.isEmpty { tags.append(rm) }

            out.append(VideoItem(
                id: "\(cfg.name)|\(vid)|\(name)".md5,
                site: cfg.name,
                title: name.isEmpty ? "未命名 " + vid : name,
                mediaURL: media,
                thumbURL: (pic.isEmpty || pic == "null") ? nil : URL(string: pic),
                tags: tags,
                pageURL: vid,
                referer: nil
            ))
        }
        return out
    }

    /// vod_play_url = "第1集$https://x/index.m3u8#第2集$https://y/index.m3u8"
    static func pickMedia(_ playUrl: String) -> URL? {
        guard !playUrl.isEmpty else { return nil }
        let first = playUrl.components(separatedBy: "#").first ?? playUrl
        let cand = (first.components(separatedBy: "$").last ?? first)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cand.hasPrefix("http"), let u = URL(string: cand) { return u }

        let pattern = "https?://[^\\s\"'$]+?\\.(?:m3u8|mp4|mkv|webm)"
        if let s = HTML.firstGroup("(" + pattern + ")", in: first) {
            return URL(string: s)
        }
        return nil
    }

    // MARK: - 网页采集

    private func parseItems(_ html: String, base: String) -> [VideoItem] {
        let selector = (cfg.itemSelector?.isEmpty == false) ? cfg.itemSelector! : "a"
        let blocks = HTML.blocks(html, selector: selector)
        var out: [VideoItem] = []
        out.reserveCapacity(blocks.count)

        for b in blocks {
            var href = HTML.abs(HTML.attr(b.attrs, "href") ?? "", base: base)
            // li.videoBox 这类容器本身没有 href，链接在里面的 <a> 上
            if href.isEmpty, let a = HTML.blocks(b.inner, selector: "a").first,
               let inner2 = HTML.attr(a.attrs, "href") {
                href = HTML.abs(inner2, base: base)
            }
            if href.isEmpty { continue }

            var title = HTML.attr(b.attrs, "title") ?? ""
            if title.isEmpty, let ts = cfg.titleSelector, !ts.isEmpty {
                let inner = HTML.blocks(b.inner, selector: ts)
                if let f = inner.first {
                    let alt = HTML.attr(f.attrs, "alt") ?? ""
                    title = alt.isEmpty ? HTML.stripTags(f.inner) : alt
                }
            }
            if title.isEmpty { title = HTML.stripTags(b.inner) }

            if cfg.titleDecode == true {
                let pats = ["l\\('(.+?)'\\)", "l\\(\"(.+?)\"\\)"]
                for p in pats {
                    if let enc = HTML.firstGroup(p, in: b.inner) {
                        let dec = Obf.xor128(enc).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !dec.isEmpty { title = dec; break }
                    }
                }
            }
            if title.isEmpty { title = href.components(separatedBy: "/").last ?? href }

            var thumb: String?
            if let ts = cfg.thumbSelector, !ts.isEmpty {
                if let img = HTML.blocks(b.inner, selector: ts).first {
                    let cands = ["data-original", "data-src", "data-mediumthumb", "src"]
                    for a in cands {
                        if let v = HTML.attr(img.attrs, a), !v.isEmpty, !v.hasPrefix("data:") {
                            thumb = HTML.abs(v, base: base)
                            break
                        }
                    }
                }
            }

            var tags: [String] = []
            if let ts = cfg.tagSelector, !ts.isEmpty {
                tags = HTML.blocks(b.inner, selector: ts)
                    .map { HTML.stripTags($0.inner) }
                    .filter { !$0.isEmpty }
            }

            out.append(VideoItem(
                id: href.md5,
                site: cfg.name,
                title: title,
                mediaURL: nil,
                thumbURL: thumb.flatMap { URL(string: $0) },
                tags: tags,
                pageURL: href,
                referer: href
            ))
        }
        return out
    }

    private func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
}
