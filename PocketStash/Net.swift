import Foundation

/// 极简 HTTP 层：固定 UA + 5 分钟内存缓存 + 自定义头 + 表单 POST
enum Net {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private static let lock = NSLock()
    private static var cache: [String: (Date, Data)] = [:]
    private static let ttl: TimeInterval = 300

    private static func cacheKey(_ url: String, _ headers: [String: String]) -> String {
        guard !headers.isEmpty else { return url }
        let h = headers.sorted { $0.key < $1.key }
            .map { $0.key + "=" + $0.value }
            .joined(separator: "&")
        return url + "|" + h
    }

    static func data(_ urlStr: String,
                     headers: [String: String] = [:],
                     useCache: Bool = true) async throws -> Data {
        let k = cacheKey(urlStr, headers)
        if useCache {
            lock.lock()
            let hit = cache[k]
            lock.unlock()
            if let hit, Date().timeIntervalSince(hit.0) < ttl { return hit.1 }
        }
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/json,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (hk, hv) in headers { req.setValue(hv, forHTTPHeaderField: hk) }
        req.timeoutInterval = 25

        let (body, _) = try await URLSession.shared.data(for: req)
        if useCache, !body.isEmpty {
            lock.lock()
            cache[k] = (Date(), body)
            if cache.count > 160 { cache.removeAll() }
            lock.unlock()
        }
        return body
    }

    static func text(_ urlStr: String,
                     headers: [String: String] = [:],
                     useCache: Bool = true) async throws -> String {
        let d = try await data(urlStr, headers: headers, useCache: useCache)
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    /// 神秘站 /so.html 只认 POST 表单：GET 会返回空列表。
    /// 搜索结果不缓存（关键词组合太多，塞满缓存反而把列表页挤掉）。
    static func form(_ urlStr: String,
                     params: [String: String],
                     headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue(urlStr, forHTTPHeaderField: "Referer")
        for (hk, hv) in headers { req.setValue(hv, forHTTPHeaderField: hk) }
        req.timeoutInterval = 25

        let (body, _) = try await URLSession.shared.data(for: req)
        return String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
