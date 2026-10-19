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
                        Image("icon_titlebar_whiteback")
                            .resizable().scaledToFit()
                            .frame(width: 20, height: 20)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

    // MARK: - 头部（参数取自官方 UserInfoHeader）

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头像 90pt + 右侧操作按钮
            HStack(alignment: .center, spacing: 0) {
                UserAvatar(name: author?.displayName ?? "?", size: 90)

                Spacer(minLength: 8)

                // 关注按钮：80x40 圆角2 官方红
                if state.isFollowing(authorId) {
                    Button { state.toggleFollow(authorId) } label: {
                        Text("已关注")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 80, height: 40)
                            .background(RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { state.toggleFollow(authorId) } label: {
                        HStack(spacing: 2) {
                            Image("icon_personal_add_little")
                                .resizable().scaledToFit()
                                .frame(width: 12, height: 12)
                            Text("关注")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 40)
                        .background(RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.primary))
                    }
                    .buttonStyle(.plain)
                }

                // 更多按钮：40x40 白0.2
                Button { } label: {
                    Image("icon_titlebar_whitemore")
                        .resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 5)
            }
            .padding(.top, 8)

            // 昵称 26pt Bold，距头像下 20
            Text(author?.displayName ?? "未知作者")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 20)

            // 抖音号 + 箭头（官方：距昵称下 3）
            HStack(spacing: 4) {
                Text("抖音号：\(authorId)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                Image("icon_arrow")
                    .resizable().scaledToFit()
                    .frame(width: 8, height: 8)
            }
            .padding(.top, 3)

            // 分割线（官方：距抖音号下 10）
            Divider()
                .background(Color.white.opacity(0.2))
                .padding(.top, 10)

            // 简介（官方：距分割线下 10）
            if let sig = author?.signature, !sig.isEmpty {
                Text(sig)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.top, 10)
            }

            // 统计：16pt Bold，间距 30（官方：距上方 15）
            HStack(spacing: 30) {
                stat("获赞", 0)
                stat("关注", 0)
                stat("粉丝", author?.followerCount ?? 0)
            }
            .padding(.top, 15)

            // 排序 tab（官方 SlideTabBarFooter：14pt，选中白/未选白0.6）
            HStack(spacing: 22) {
                sortTab(0, "点赞优先")
                sortTab(1, "时间优先")
                Spacer()
                Text("\(total) 个作品")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Divider().background(Color.white.opacity(0.12))
        }
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 3) {
            Text(FeedItem.formatCount(n))
                .font(.system(size: 16, weight: .bold))
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
        .contentShape(Rectangle())
    }

    // MARK: - 九宫格

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 1.5) {
            ForEach(items) { g in
                Button {
                    openPlayer(g)
                } label: {
                    GeometryReader { geo in
                        ZStack(alignment: .bottomLeading) {
                            if let u = g.coverURL {
                                CachedAsyncImage(url: u)
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                            } else {
                                Color(white: 0.12)
                            }

                            // 官方：底部 100pt 渐变（透明 → 黑0.2 → 黑0.6）
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.2), location: 0.5),
                                    .init(color: .black.opacity(0.6), location: 1)
                                ],
                                startPoint: .top, endPoint: .bottom)
                            .frame(height: 100)
                            .frame(maxHeight: .infinity, alignment: .bottom)

                            // 官方：点赞数 12pt + icon_home_likenum，距左10 距底20
                            HStack(spacing: 2) {
                                Image("icon_home_likenum")
                                    .resizable().scaledToFit()
                                    .frame(width: 11, height: 11)
                                Text(FeedItem.formatCount(g.digg))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                            }
                            .padding(.leading, 10)
                            .padding(.bottom, 6)
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
