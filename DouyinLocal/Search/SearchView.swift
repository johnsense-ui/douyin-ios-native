//
//  SearchView.swift
//  DouyinLocal
//
//  搜索页（全屏）。
//   · 未输入时：搜索历史（可单条删除）+ 猜你想搜（可换一批）
//   · 搜索后：作者 / 视频两块，支持「点赞优先 / 时间优先」排序与分页加载
//

import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var submitted = ""

    @State private var authors: [Author] = []
    @State private var videos: [VideoThumb] = []
    @State private var authorTotal = 0
    @State private var videoTotal = 0

    @State private var offset = 0
    @State private var loading = false
    @State private var loadingMore = false
    @State private var noMore = false

    @State private var sort = 0            // 0 点赞优先 / 1 时间优先
    @State private var errorText: String?

    @State private var suggests: [SuggestItem] = []
    @State private var suggestLoading = false
    @State private var history: [String] = []

    @State private var route: SearchRoute?

    @FocusState private var focused: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    private let historyKey = "search.history"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar

                if submitted.isEmpty {
                    discover
                } else {
                    resultsView
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
            loadHistory()
            Task { await loadSuggest() }
        }
        .fullScreenCover(item: $route) { r in
            switch r {
            case .author(let aid):
                AuthorView(authorId: aid)
            case .play(let item):
                PlayerTargetView(targets: [item], startVid: item.vid, authorName: item.author)
            }
        }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("", text: $query, prompt: Text("搜索视频或作者")
                    .foregroundStyle(Theme.textTertiary))
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { runSearch(query) }
                if !query.isEmpty {
                    Button { query = ""; submitted = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 17).fill(Color(white: 0.16)))

            Button("取消") { dismiss() }
                .font(.system(size: 14.5))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 首页（历史 + 猜你想搜）

    private var discover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("搜索历史")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Button { clearHistory() } label: {
                                Text("清空")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        FlowRows(items: history, spacing: 8) { h in
                            historyChip(h)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("猜你想搜")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            Task { await loadSuggest() }
                        } label: {
                            HStack(spacing: 4) {
                                if suggestLoading {
                                    ProgressView().tint(Theme.textTertiary).scaleEffect(0.6)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 12))
                                }
                                Text("换一批")
                                    .font(.system(size: 12.5))
                            }
                            .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    if suggests.isEmpty && suggestLoading {
                        ProgressView().tint(.white).padding(.top, 10)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(suggests.enumerated()), id: \.element.id) { i, s in
                                Button {
                                    runSearch(s.text)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: s.isAuthor ? "person.fill" : "magnifyingglass")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textTertiary)
                                            .frame(width: 16)
                                        Text(s.text)
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.up.left")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textTertiary.opacity(0.6))
                                    }
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if i < suggests.count - 1 {
                                    Divider().background(Color.white.opacity(0.07))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private func historyChip(_ h: String) -> some View {
        HStack(spacing: 6) {
            Button { runSearch(h) } label: {
                Text(h)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button { removeHistory(h) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(white: 0.16)))
    }

    // MARK: - 搜索结果

    private var resultsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                sortTab(0, "点赞优先")
                sortTab(1, "时间优先")
                Spacer()
                Text("共 \(videoTotal) 个视频")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !authors.isEmpty {
                        sectionTitle("作者", authorTotal)
                        ForEach(authors) { a in
                            Button { route = .author(a.authorId) } label: {
                                HStack(spacing: 12) {
                                    UserAvatar(name: a.displayName, size: 46)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(a.displayName)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text("\(FeedItem.formatCount(a.followerCount)) 粉丝 · \(a.videoCount) 作品")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !videos.isEmpty {
                        sectionTitle("视频", videoTotal)
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(videos) { g in
                                Button { openVideo(g) } label: {
                                    videoCell(g)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if g.id == videos.last?.id { Task { await loadMore() } }
                                }
                            }
                        }

                        if loadingMore {
                            ProgressView().tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        } else if noMore && !videos.isEmpty {
                            Text("没有更多了")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }

                    if videos.isEmpty && authors.isEmpty {
                        Text(loading ? "搜索中…" : "没有找到「\(submitted)」相关内容")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func videoCell(_ g: VideoThumb) -> some View {
        GeometryReader { geo in
            ZStack {
                if let u = g.coverURL {
                    CachedAsyncImage(url: u)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Color(white: 0.12)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill").font(.system(size: 9))
                        Text(FeedItem.formatCount(g.digg))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(.leading, 5)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    private func sortTab(_ i: Int, _ title: String) -> some View {
        Button {
            guard sort != i else { return }
            sort = i
            runSearch(submitted)
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: sort == i ? 14.5 : 14,
                                  weight: sort == i ? .semibold : .regular))
                    .foregroundStyle(sort == i ? .white : Theme.textTertiary)
                Capsule()
                    .fill(sort == i ? Color.white : .clear)
                    .frame(width: 16, height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Text(t)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("\(n)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 请求

    private func runSearch(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        query = q
        submitted = q
        addHistory(q)
        authors = []
        videos = []
        offset = 0
        noMore = false
        loading = true
        errorText = nil
        let sortKey = sort == 0 ? "digg" : "new"
        Task {
            do {
                let r = try await APIClient.shared.search(q, offset: 0, sort: sortKey)
                await MainActor.run {
                    authors = r.authors
                    authorTotal = r.authorTotal
                    videos = r.videos
                    videoTotal = r.videoTotal
                    offset = r.videos.count
                    noMore = r.videos.count >= r.videoTotal
                    loading = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func loadMore() async {
        guard !loading, !loadingMore, !noMore, !submitted.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }
        let sortKey = sort == 0 ? "digg" : "new"
        do {
            let r = try await APIClient.shared.search(submitted, offset: offset, sort: sortKey)
            await MainActor.run {
                let existing = Set(videos.map { $0.vid })
                let add = r.videos.filter { !existing.contains($0.vid) }
                videos.append(contentsOf: add)
                offset += r.videos.count
                if r.videos.isEmpty || videos.count >= videoTotal { noMore = true }
            }
        } catch {
            await MainActor.run { noMore = true }
        }
    }

    private func loadSuggest() async {
        suggestLoading = true
        defer { suggestLoading = false }
        if let r = try? await APIClient.shared.suggest() {
            await MainActor.run { suggests = r.items }
        }
    }

    private func openVideo(_ g: VideoThumb) {
        Task {
            if let r = try? await APIClient.shared.videos(byIDs: [g.vid]),
               let item = r.items.first {
                await MainActor.run {
                    route = .play(item)
                }
            }
        }
    }

    // MARK: - 搜索历史

    private func loadHistory() {
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private func addHistory(_ q: String) {
        var h = history.filter { $0 != q }
        h.insert(q, at: 0)
        if h.count > 12 { h = Array(h.prefix(12)) }
        history = h
        UserDefaults.standard.set(h, forKey: historyKey)
    }

    private func removeHistory(_ q: String) {
        history.removeAll { $0 == q }
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    private func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}

// MARK: - 二级页路由

enum SearchRoute: Identifiable {
    case author(String)
    case play(FeedItem)

    var id: String {
        switch self {
        case .author(let a): return "author-\(a)"
        case .play(let i): return "play-\(i.vid)"
        }
    }
}

// MARK: - 流式换行布局（用于历史标签）

struct FlowRows<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows().enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { item in
                        content(item)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func rows() -> [[Item]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0..<min($0 + 3, items.count)])
        }
    }
}
