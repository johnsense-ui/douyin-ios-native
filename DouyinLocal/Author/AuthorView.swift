//
//  AuthorView.swift
//  DouyinLocal
//
//  作者主页：头部（头像/昵称/粉丝/作品数）+ 三列九宫格。
//  滚动时头部吸顶。
//

import SwiftUI

struct AuthorView: View {
    let authorId: String
    /// 嵌入使用时（左滑进入）用这个关闭，而不是 dismiss
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var author: Author?
    @State private var items: [VideoThumb] = []
    @State private var total = 0
    @State private var loading = true
    @State private var offset = 0
    @State private var playing: PlayStart?
    @State private var playItems: [FeedItem] = []
    @State private var preparing = false
    @State private var sort = 0            // 0 = 点赞优先, 1 = 时间优先
    @ObservedObject private var state = StateStore.shared

    private var limit = 30

    // @State private 会让编译器生成的成员初始化器变成 private，这里显式给一个
    init(authorId: String, onClose: (() -> Void)? = nil) {
        self.authorId = authorId
        self.onClose = onClose
    }
    private let columns = [
        GridItem(.flexible(), spacing: 1.5),
        GridItem(.flexible(), spacing: 1.5),
        GridItem(.flexible(), spacing: 1.5)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            grid
                        } header: {
                            header
                        }
                    }
                }
                .scrollIndicators(.hidden)

                if loading && items.isEmpty {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(author?.displayName ?? "作者主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { closeSelf() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await load(reset: true) }
        .overlay {
            if preparing {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("载入作品…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { s in
            PlayerTargetView(targets: playItems,
                             startVid: s.id,
                             authorName: author?.displayName ?? "未知作者")
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                UserAvatar(name: author?.displayName ?? "?", size: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(author?.displayName ?? "未知作者")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 16) {
                        stat("关注", 0)
                        stat("粉丝", author?.followerCount ?? 0)
                        stat("作品", total)
                    }
                }
                Spacer(minLength: 0)
            }

            if let sig = author?.signature, !sig.isEmpty {
                Text(sig)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    state.toggleFollow(authorId)
                } label: {
                    Text(state.isFollowing(authorId) ? "已关注" : "关注")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(state.isFollowing(authorId) ? .white.opacity(0.85) : .white)
                        .frame(width: 104)
                        .frame(height: 35)
                        .background(
                            Group {
                                if state.isFollowing(authorId) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(.white.opacity(0.3))
                                } else {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Theme.primary)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                Button {} label: {
                    Text("私信")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 104)
                        .frame(height: 35)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.28)))
                }
            }
            .buttonStyle(.plain)

            // 排序：点赞优先 / 时间优先
            HStack(spacing: 18) {
                sortTab(0, "点赞优先")
                sortTab(1, "时间优先")
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            ZStack {
                if let u = items.first?.coverURL {
                    CachedAsyncImage(url: u)
                        .scaledToFill()
                        .blur(radius: 26)
                        .overlay(
                            LinearGradient(
                                colors: [Color.black.opacity(0.45),
                                         Color.black.opacity(0.86),
                                         Color.black],
                                startPoint: .top, endPoint: .bottom)
                        )
                } else {
                    Color.black
                }
            }
        )
        .clipped()
        .overlay(alignment: .bottom) {
            Divider().background(Color.white.opacity(0.07))
        }
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 3) {
            Text(FeedItem.formatCount(n))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func sortTab(_ i: Int, _ title: String) -> some View {
        Button {
            guard sort != i else { return }
            sort = i
            Task { await load(reset: true) }
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: sort == i ? 14.5 : 14,
                                  weight: sort == i ? .semibold : .regular))
                    .foregroundStyle(sort == i ? .white : Theme.textTertiary)
                Capsule()
                    .fill(sort == i ? Color.white : .clear)
                    .frame(width: 18, height: 2.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 九宫格

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 1.5) {
            ForEach(items) { g in
                Button {
                    openPlayer(g)
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
                            // 播放量
                            VStack {
                                Spacer()
                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9))
                                    Text(FeedItem.formatCount(g.digg))
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 2)
                                .padding(.leading, 5)
                                .padding(.bottom, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if g.id == items.last?.id { Task { await load(reset: false) } }
                }
            }
        }
    }

    /// 点九宫格 → 拉全量作品（含视频地址）→ 进入播放
    private func openPlayer(_ g: VideoThumb) {
        guard !preparing else { return }
        preparing = true
        Task {
            var all: [FeedItem] = []
            var off = 0
            let lim = 60
            do {
                while true {
                    let d = try await APIClient.shared.authorItems(authorId, offset: off, limit: lim,
                                                          sort: sort == 0 ? "digg" : "new")
                    if d.items.isEmpty { break }
                    all.append(contentsOf: d.items)
                    off += d.items.count
                    if off >= d.total { break }
                }
            } catch {
                print("openPlayer:", error)
            }
            await MainActor.run {
                preparing = false
                guard !all.isEmpty else { return }
                playItems = all
                playing = PlayStart(id: g.vid)
            }
        }
    }

    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }
    // MARK: - 数据

    private func load(reset: Bool) async {
        if reset {
            offset = 0
            items = []
            loading = true
        } else {
            guard items.count < total, !loading else { return }
        }
        loading = true
        defer { loading = false }
        do {
            let d = try await APIClient.shared.author(authorId, offset: offset, limit: limit,
                                                         sort: sort == 0 ? "digg" : "new")
            author = d.author
            total = d.total
            if reset { items = d.items } else { items.append(contentsOf: d.items) }
            offset += d.items.count
        } catch {
            print("author load error:", error)
        }
    }
}

// MARK: - 播放起点（可 Identifiable）
struct PlayStart: Identifiable, Hashable {
    let id: String
}
