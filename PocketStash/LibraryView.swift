import SwiftUI
import SwiftData

private struct PlayTarget: Identifiable {
    let id: String
    let url: URL
    var referer: String?
}

struct LibraryView: View {
    @Query(sort: \VideoScene.addedAt, order: .reverse)
    private var scenes: [VideoScene]

    @State private var bucket = "全部"
    @State private var playing: PlayTarget?

    private var buckets: [String] {
        ["全部"] + Array(Set(scenes.map(\.bucket))).sorted()
    }

    private var filtered: [VideoScene] {
        bucket == "全部" ? scenes : scenes.filter { $0.bucket == bucket }
    }

    var body: some View {
        NavigationStack {
            List {
                if !scenes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(buckets, id: \.self) { b in
                                Button(b) { bucket = b }
                                    .buttonStyle(.bordered)
                                    .tint(bucket == b ? .pink : .gray)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                ForEach(filtered) { s in
                    Button {
                        if let u = URL(string: s.mediaURL) {
                            playing = PlayTarget(id: s.key, url: u, referer: s.referer)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).lineLimit(1).font(.subheadline)
                            HStack(spacing: 6) {
                                Text(s.bucket)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.pink.opacity(0.15), in: Capsule())
                                Text(s.site)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.12), in: Capsule())
                                Text(s.addedAt, style: .date)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !scenes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空") { HistoryStore.shared.clearAll() }
                            .tint(.red)
                    }
                }
            }
            .overlay {
                if scenes.isEmpty {
                    ContentUnavailableView("还没有记录",
                                           systemImage: "clock",
                                           description: Text("去「抓取」页点一条播放就会记在这里"))
                }
            }
            .fullScreenCover(item: $playing) { t in
                PlayerView(url: t.url, referer: t.referer)
            }
        }
    }
}
