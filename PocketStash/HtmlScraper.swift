import Foundation

/// sm 站群域名池：前缀 sm + 3 位数字 + .vip，访问时前面再叠 6 位随机子域
enum SmPool {
    /// 「神秘电影」的 XOR-128 形态，页面里出现即判活
    static let mark = "\u{79e3}\u{7958}\u{75be}\u{5ff1}"

    /// 已知线路（从站点自己的 vip.js 里挖的，缺 234）
    static let known: [String] = [
        "sm230.vip", "sm231.vip", "sm232.vip", "sm233.vip", "sm235.vip",
        "sm236.vip", "sm237.vip", "sm238.vip", "sm239.vip", "sm240.vip",
        "sm241.vip", "sm242.vip", "sm243.vip", "sm244.vip", "sm245.vip",
        "sm246.vip", "sm247.vip", "sm248.vip"
    ]

    private static let lock = NSLock()
    private static var stored = "sm230.vip"

    static var currentHost: String {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func setHost(_ h: String) {
        let v = h.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        lock.lock()
        stored = v
        lock.unlock()
    }

    static let subChars = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    static func randomSub() -> String {
        var s = ""
        for _ in 0..<6 { s.append(subChars.randomElement() ?? "a") }
        return s
    }

    static func randomCandidates(_ n: Int = 30) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        var guardCount = 0
        while out.count < n && guardCount < n * 40 {
            guardCount += 1
            let h = "sm" + String(format: "%03d", Int.random(in: 0...999)) + ".vip"
            if seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    /// 最多试 2 个随机子域，命中站点特征即算活
    static func probe(_ h: String) async -> Bool {
        for _ in 0..<2 {
            let url = "https://" + randomSub() + "." + h + "/"
            guard let body = try? await Net.text(url, useCache: false) else { continue }
            if body.contains(mark) || body.contains("vodbox") { return true }
        }
        return false
    }

    /// 8 并发扫描候选域名
    static func scan(_ candidates: [String] = SmPool.randomCandidates()) async -> [String] {
        var alive: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for h in candidates.prefix(48) {
                group.addTask { (h, await SmPool.probe(h)) }
            }
            for await (h, ok) in group where ok {
                if !alive.contains(h) { alive.append(h) }
            }
        }
        return alive
    }
}

/// 标题混淆：每个字符 XOR 128
enum Obf {
    static func xor128(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if let v = UnicodeScalar(u.value ^ 128) { out.append(v) }
        }
        return String(out)
    }
}

struct HtmlBlock {
    let attrs: String
    let inner: String
}

/// 没有 Jsoup 的 Swift 端：够用就行的标签级解析
enum HTML {
    /// 只支持 tag / tag.class 两种写法，够覆盖站点配置
    static func blocks(_ html: String, selector: String) -> [HtmlBlock] {
        let sel = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sel.isEmpty else { return [] }
        var tag = sel
        var cls: String?
        if let dot = sel.firstIndex(of: ".") {
            tag = String(sel[sel.startIndex..<dot])
            cls = String(sel[sel.index(after: dot)...])
        }
        if tag.isEmpty { tag = "a" }
        // img/source 这类空元素没有结束标签，抓 [^>]* 就够
        let voids: Set<String> = ["img", "source", "input", "br", "hr", "meta",
                                  "link", "area", "base", "embed", "track", "wbr"]
        if voids.contains(tag.lowercased()) {
            let p = "<" + tag + "\\b([^>]*?)/?>"
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else {
                return []
            }
            let ns = html as NSString
            var flat: [HtmlBlock] = []
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let attrs = ns.substring(with: m.range(at: 1))
                if let c = cls, !hasClass(attrs, c) { continue }
                flat.append(HtmlBlock(attrs: attrs, inner: ""))
            }
            return flat
        }
        let pattern = "<" + tag + "\\b([^>]*)>([\\s\\S]*?)</" + tag + ">"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        var out: [HtmlBlock] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            if let c = cls, !hasClass(attrs, c) { continue }
            out.append(HtmlBlock(attrs: attrs, inner: inner))
        }
        return out
    }

    static func hasClass(_ attrs: String, _ want: String) -> Bool {
        guard let c = attr(attrs, "class") else { return false }
        for part in c.split(separator: " ") where part == Substring(want) { return true }
        return false
    }

    static func attr(_ attrs: String, _ name: String) -> String? {
        let pattern = "\\b" + name + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = attrs as NSString
        guard let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var i = 2
        while i <= 4 {
            let r = m.range(at: i)
            if r.location != NSNotFound {
                return ns.substring(with: r)
            }
            i += 1
        }
        return nil
    }

    static func stripTags(_ s: String) -> String {
        var t = s
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let ns = t as NSString
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        let map: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#x27;", "'")
        ]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        return t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    /// 页面里的直链常被 JSON 转义成 https:\/\/…，解码时得还原
    static func unescapeURL(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "\\/", with: "/")
        r = r.replacingOccurrences(of: "\\u0026", with: "&")
        r = r.replacingOccurrences(of: "&amp;", with: "&")
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 相对链接转绝对
    static func abs(_ href: String, base: String) -> String {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return "" }
        if h.hasPrefix("http://") || h.hasPrefix("https://") { return h }
        if h.hasPrefix("//") { return "https:" + h }
        guard let comps = URLComponents(string: base),
              let scheme = comps.scheme, let host = comps.host else { return h }
        var origin = scheme + "://" + host
        if let port = comps.port { origin += ":" + String(port) }
        if h.hasPrefix("/") { return origin + h }
        let path = comps.path
        if let slash = path.lastIndex(of: "/") {
            return origin + String(path[path.startIndex...slash]) + h
        }
        return origin + "/" + h
    }
}
