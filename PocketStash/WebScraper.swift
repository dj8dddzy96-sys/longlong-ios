import Foundation
import WebKit
import SwiftUI

/// 有些站（Pornhub / OnlyFans）纯 URLSession 拿不到：风控要 JS 挑战，OnlyFans 还要登录态。
/// 这里用一个隐藏的 WKWebView 真渲染，拿到 outerHTML 后再走同一套解析。
@MainActor
final class WebLoader: NSObject, WKNavigationDelegate {
    static let shared = WebLoader()

    private var web: WKWebView?
    private var waiter: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var pendingSelector: String?
    private var wantScroll = false

    private func ensure(_ ua: String) -> WKWebView {
        if let web { return web }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        v.navigationDelegate = self
        v.customUserAgent = ua
        v.isHidden = true
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let win = scene.windows.first {
            win.addSubview(v)
        }
        web = v
        return v
    }

    func html(_ urlStr: String,
              headers: [String: String] = [:],
              waitSelector selector: String? = nil,
              scroll: Bool = false,
              timeout: Double = 25) async throws -> String {
        guard waiter == nil else {
            throw NSError(domain: "WebLoader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "上一个页面还在加载，稍后再点"])
        }
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        let view = ensure(headers["User-Agent"] ?? Net.ua)
        pendingSelector = selector
        wantScroll = scroll

        if let cookie = headers["Cookie"] { await inject(cookie, for: url) }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers where k.lowercased() != "cookie" {
            req.setValue(v, forHTTPHeaderField: k)
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            waiter = c
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failure(URLError(.timedOut)))
            }
            view.load(req)
        }
    }

    /// 打开登录页让用户自己登，Cookie 落在 default() 存储里，之后抓取直接复用
    func login(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        ensure(Net.ua).load(URLRequest(url: url))
    }

    func clearCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all = await store.allCookies()
        for c in all { await store.deleteCookie(c) }
    }

    private func inject(_ cookie: String, for url: URL) async {
        guard let host = url.host else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for pair in cookie.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .path: "/", .name: kv[0], .value: kv[1]
            ]
            props[.expires] = Date().addingTimeInterval(3600 * 24 * 30)
            if let c = HTTPCookie(properties: props) { await store.setCookie(c) }
        }
    }

    private func js(_ script: String) async -> Any? {
        guard let view = web else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            view.evaluateJavaScript(script) { value, _ in c.resume(returning: value) }
        }
    }

    private func settle() async {
        guard waiter != nil else { return }
        if let sel = pendingSelector, !sel.isEmpty {
            let lit = sel.replacingOccurrences(of: "\"", with: "")
            for _ in 0..<24 {
                if (await js("document.querySelector(\"\(lit)\") !== null") as? Bool) == true { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if wantScroll {
            for _ in 0..<2 {
                _ = await js("window.scrollTo(0, document.body.scrollHeight); 1")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        let html = (await js("document.documentElement.outerHTML")) as? String ?? ""
        finish(.success(html))
    }

    private func finish(_ result: Result<String, Error>) {
        deadline?.cancel()
        deadline = nil
        guard let c = waiter else { return }
        waiter = nil
        switch result {
        case .success(let s): c.resume(returning: s)
        case .failure(let e): c.resume(throwing: e)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.settle() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.finish(.failure(NSError(domain: "WebLoader", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: "内核被系统回收，重试一次"])))
        }
    }
}

/// 登录页（OnlyFans 这类必须真登录的源）
struct WebLoginView: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WKWeb(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct WKWeb: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = Net.ua
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
