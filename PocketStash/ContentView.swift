import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            FetchView()
                .tabItem { Label("抓取", systemImage: "arrow.down.circle.fill") }
            LibraryView()
                .tabItem { Label("历史", systemImage: "clock.fill") }
        }
        .tint(.pink)
    }
}

private struct Playing: Identifiable {
    let id: String
    let url: URL
    let referer: String?
}

private struct LoginTarget: Identifiable {
    let id: String
    let title: String
    let url: URL
}

// MARK: - 抓取页

struct FetchView: View {
    @State private var sites = SiteCatalog.load()
    @State private var siteIdx = 0
    @State private var page = 1
    @State private var keyword = ""
    @State private var items: [VideoItem] = []
    @State private var errText: String?
    @State private var loading = false
    @State private var resolvingId: String?
    @State private var playing: Playing?
    @State private var loginTarget: LoginTarget?

    private var cfg: SiteConfig? {
        (siteIdx >= 0 && siteIdx < sites.count) ? sites[siteIdx] : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sites.isEmpty {
                        Text("Sites.json 没有可用源").foregroundStyle(.red)
                    } else {
                        Picker("分类", selection: $siteIdx) {
                            ForEach(Array(sites.enumerated()), id: \.offset) { i, s in
                                Text(s.name).tag(i)
                            }
                        }
                    }

                    HStack {
                        TextField("关键词搜索", text: $keyword)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { Task { await load(search: true) } }
                        Button("搜") { Task { await load(search: true) } }
                            .buttonStyle(.borderedProminent)
                    }

                    HStack {
                        Button("第 \(page) 页") { Task { await load() } }
                        Spacer()
                        Button {
                            if page > 1 { page -= 1; Task { await load() } }
                        } label: { Image(systemName: "chevron.left") }
                        .disabled(page <= 1)
                        Button {
                            page += 1; Task { await load() }
                        } label: { Image(systemName: "chevron.right") }
                    }
                    .buttonStyle(.bordered)
                }

                Section {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    if let e = errText {
                        Text(e)
                            .font(.footnote)
                            .foregroundStyle(e.hasPrefix("已切") || e.hasPrefix("正在") ? .secondary : .red)
                    }
                    ForEach(items) { item in
                        Button {
                            Task { await play(item) }
                        } label: {
                            row(item)
                        }
                        .buttonStyle(.plain)
                    }
                    if !items.isEmpty {
                        Text("共 \(items.count) 条")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("抓取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let c = cfg, c.isWeb {
                            Button("登录网页源") {
                                let raw = c.headers?["Referer"] ?? c.listURL ?? ""
                                if let u = URL(string: raw) {
                                    loginTarget = LoginTarget(id: c.name, title: c.name, url: u)
                                }
                            }
                        }
                        Button("刷新域名") { Task { await refreshHost() } }
                        Button("重载 Sites.json") {
                            sites = SiteCatalog.reload()
                            siteIdx = 0
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task(id: siteIdx) {
                page = 1
                keyword = ""
                await load()
            }
            .fullScreenCover(item: $playing) { p in
                PlayerView(url: p.url, referer: p.referer)
            }
            .sheet(item: $loginTarget) { t in
                WebLoginView(title: t.title, url: t.url)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: VideoItem) -> some View {
        HStack(spacing: 12) {
            Thumb(url: item.thumbURL, referer: item.referer)
                .frame(width: 104, height: 60)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.footnote)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    ForEach(item.tags.prefix(2), id: \.self) { t in
                        Text(t)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.pink.opacity(0.15), in: Capsule())
                    }
                    if item.mediaURL == nil && resolvingId != item.id {
                        Text("点开解析").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if resolvingId == item.id {
                ProgressView()
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
            }
        }
        .padding(.vertical, 2)
    }

    private func load(search: Bool = false) async {
        guard let c = cfg else { return }
        if c.isWeb && (c.creator ?? "").isEmpty && (c.listURL ?? "").contains("{creator}") {
            items = []
            errText = "这个源要在 Sites.json 里补 creator（博主名）"
            return
        }
        loading = true
        errText = nil
        defer { loading = false }
        do {
            let s = Scraper(cfg: c)
            let result = search ? try await s.search(keyword, page: page)
                                : try await s.list(page: page)
            items = result
            if result.isEmpty { errText = "这一页是空的，换个分类或页码" }
        } catch {
            items = []
            errText = "抓取失败: " + error.localizedDescription
        }
    }

    private func play(_ item: VideoItem) async {
        if let u = item.mediaURL {
            HistoryStore.shared.remember(item)
            playing = Playing(id: item.id, url: u, referer: item.referer)
            return
        }
        guard let c = cfg else { return }
        resolvingId = item.id
        defer { resolvingId = nil }
        do {
            let full = try await Scraper(cfg: c).resolve(item)
            guard let u = full.mediaURL else { throw URLError(.badURL) }
            HistoryStore.shared.remember(full)
            playing = Playing(id: full.id, url: u, referer: full.referer)
        } catch {
            errText = "直链解析失败: " + error.localizedDescription
        }
    }

    private func refreshHost() async {
        errText = "正在扫站群域名…"
        let alive = await SmPool.scan()
        if let h = alive.first {
            SmPool.setHost(h)
            errText = "已切到 " + h + "（" + String(alive.count) + " 条活线路）"
        } else {
            errText = "没扫到活域名，用当前 " + SmPool.currentHost
        }
    }
}
