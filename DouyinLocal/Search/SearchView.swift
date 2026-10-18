//
//  SearchView.swift
//  DouyinLocal
//
//  搜索页：结果分「作者」和「视频」两块。
//

import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var result: SearchResult?
    @State private var loading = false
    @State private var route: SearchRoute?
    @State private var playItems: [FeedItem] = []
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar

                ScrollView {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        hint
                    } else if loading && result == nil {
                        ProgressView().tint(.white).padding(.top, 60)
                    } else if let r = result {
                        results(r)
                    } else if let e = errorText {
                        Text(e).font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 60)
                    } else {
                        Text("没有找到相关内容")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 60)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .fullScreenCover(item: $route) { r in
            switch r {
            case .author(let aid):
                AuthorView(authorId: aid)
            case .play(let t):
                PlayerTargetView(targets: playItems, startVid: t.vid, authorName: t.author)
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
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button { query = ""; result = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 17)
                .fill(Color(white: 0.16)))

            Button("取消") { dismiss() }
                .font(.system(size: 14.5))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Text("搜点什么").font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("可以搜文案，也可以搜作者昵称")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 80)
    }

    // MARK: - 结果

    @ViewBuilder
    private func results(_ r: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !r.authors.isEmpty {
                sectionTitle("作者", r.authorTotal)
                ForEach(r.authors) { a in
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
                    }
                    .buttonStyle(.plain)
                }
            }

            if !r.videos.isEmpty {
                sectionTitle("视频", r.videoTotal)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(r.videos) { g in
                        Button {
                            openVideo(g)
                        } label: {
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
                                            Image(systemName: "play.fill").font(.system(size: 9))
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
                        .buttonStyle(.plain)
                    }
                }
            }

            if r.authors.isEmpty && r.videos.isEmpty {
                Text("没有找到「\(r.q)」相关内容")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            }
        }
        .padding(.bottom, 30)
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
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 请求

    /// 点搜索结果里的视频 → 拉完整信息后播放
    private func openVideo(_ g: VideoThumb) {
        Task {
            if let r = try? await APIClient.shared.videos(byIDs: [g.vid]),
               let item = r.items.first {
                await MainActor.run {
                    playItems = r.items
                    route = .play(PlayerTarget(authorId: item.authorId,
                                                         vid: item.vid,
                                                         author: item.author))
                }
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { result = nil; return }
        loading = true
        errorText = nil
        Task {
            do {
                let r = try await APIClient.shared.search(q)
                await MainActor.run {
                    result = r
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
}

// MARK: - 便于 fullScreenCover 使用的目标

struct PlayerTarget: Identifiable, Hashable {
    let authorId: String
    let vid: String
    let author: String
    var id: String { vid }
}

// MARK: - 二级页路由
enum SearchRoute: Identifiable {
    case author(String)
    case play(PlayerTarget)

    var id: String {
        switch self {
        case .author(let a): return "author-\(a)"
        case .play(let t): return "play-\(t.vid)"
        }
    }
}