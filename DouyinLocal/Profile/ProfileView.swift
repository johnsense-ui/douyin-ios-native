//
//  ProfileView.swift
//  DouyinLocal
//
//  「我的」个人主页。
//
//  数据全部来自 App 内的操作（StateStore），不与本地原始 db 合并。
//
//  结构：
//    navBar（固定）
//    ScrollView
//      header（头像 + 关注/粉丝/喜欢）
//      content（九宫格 / 关注列表）
//    tabBar（固定在底部，不随内容滚动，避免点错）
//

import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = StateStore.shared

    @State private var tab = 0
    @State private var likedVideos: [FeedItem] = []
    @State private var savedVideos: [FeedItem] = []
    @State private var followingAuthors: [Author] = []

    @State private var route: ProfileRoute?


    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar

                ScrollView {
                    VStack(spacing: 0) {
                        header
                        content
                    }
                }
                .scrollIndicators(.hidden)

                tabBar
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadAll() }
        .onChange(of: state.likedCount) { _, _ in Task { await loadLiked() } }
        .onChange(of: state.savedCount) { _, _ in Task { await loadSaved() } }
        .onChange(of: state.followingCount) { _, _ in Task { await loadFollowing() } }
        .fullScreenCover(item: $route) { r in
            switch r {
            case .play(let list, let item):
                PlayerTargetView(targets: list,
                                 startVid: item.vid,
                                 authorName: item.author)
            case .author(let t):
                AuthorView(authorId: t.id)
            case .settings:
                SettingsView()
            }
        }
    }

    // MARK: - 顶栏

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("我的")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.down").opacity(0)
                .font(.system(size: 18, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 0)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                UserAvatar(name: "我的", size: 80)
                VStack(alignment: .leading, spacing: 7) {
                    Text("我的收藏夹")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 20) {
                        stat(state.followingCount, "关注")
                        stat(0, "粉丝")
                        stat(state.likedCount, "喜欢")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            // 快捷入口
            HStack(spacing: 9) {
                quickButton("设置", "gearshape.fill") { route = .settings }
                quickButton("缓存", "bookmark.fill") { route = .settings }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Color.clear.frame(height: 16)
        }
        .padding(.top, 6)
        .background(
            LinearGradient(colors: [Color(white: 0.10), Color.black],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.primary.opacity(0.20), .clear],
                                             center: .center,
                                             startRadius: 0, endRadius: 120))
                        .frame(width: 250, height: 250)
                        .offset(x: 80, y: -120)
                }
                .clipped()
        )
    }

    private func quickButton(_ title: String, _ icon: String,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func stat(_ n: Int, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text("\(n)")
                .font(.system(size: 17.5, weight: .semibold))
                .foregroundStyle(.white)
            Text(t)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Tab（固定）

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(0, "喜欢", state.likedCount)
            tabItem(1, "收藏", state.savedCount)
            tabItem(2, "关注", state.followingCount)
        }
        .frame(height: 46)
        .background(Color.black)
        .overlay(alignment: .top) {
            Divider().background(Color.white.opacity(0.12))
        }
    }

    private func tabItem(_ i: Int, _ title: String, _ n: Int) -> some View {
        Button {
            guard tab != i else { return }
            withAnimation(.easeOut(duration: 0.14)) { tab = i }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: tab == i ? 15.5 : 15,
                                      weight: tab == i ? .semibold : .regular))
                        .foregroundStyle(tab == i ? .white : Theme.textTertiary)
                    if n > 0 {
                        Text("\(n)")
                            .font(.system(size: 11))
                            .foregroundStyle(tab == i ? Theme.primary : Theme.textTertiary)
                    }
                }
                Capsule()
                    .fill(tab == i ? Color.white : .clear)
                    .frame(width: 20, height: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if tab == 2 {
            if followingAuthors.isEmpty {
                empty("还没有关注任何人")
            } else {
                VStack(spacing: 0) {
                    ForEach(followingAuthors) { a in
                        HStack(spacing: 12) {
                            Button {
                                route = .author(AuthorTarget(id: a.authorId))
                            } label: {
                                HStack(spacing: 12) {
                                    UserAvatar(name: a.displayName, size: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(a.displayName)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text("\(FeedItem.formatCount(a.followerCount)) 粉丝 · \(a.videoCount) 作品")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                state.toggleFollow(a.authorId)
                            } label: {
                                Text("已关注")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 14)
                                    .frame(height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(.white.opacity(0.3))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                }
            }
        } else {
            let list = tab == 0 ? likedVideos : savedVideos
            if list.isEmpty {
                empty(tab == 0 ? "还没有喜欢的视频" : "还没有收藏的视频")
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(list) { item in
                        Button {
                            // 列表随路由一起带走，避免拿不到或拿错
                            route = .play(list, item)
                        } label: {
                            GeometryReader { geo in
                                ZStack {
                                    if let u = item.coverURL {
                                        CachedAsyncImage(url: u)
                                            .scaledToFill()
                                            .frame(width: geo.size.width, height: geo.size.height)
                                            .clipped()
                                    } else {
                                        Color(white: 0.13)
                                    }
                                    VStack {
                                        Spacer()
                                        HStack(spacing: 3) {
                                            Image(systemName: "heart.fill").font(.system(size: 9))
                                            Text(item.diggText)
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
                .padding(.bottom, 20)
            }
        }
    }

    private func empty(_ t: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary.opacity(0.6))
            Text(t)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: - 数据

    private func loadAll() async {
        async let a: () = loadLiked()
        async let b: () = loadSaved()
        async let c: () = loadFollowing()
        _ = await (a, b, c)
    }

    private func loadLiked() async {
        let ids = state.likedIDs
        guard !ids.isEmpty else { likedVideos = []; return }
        if let r = try? await APIClient.shared.videos(byIDs: ids) {
            likedVideos = r.items
        }
    }

    private func loadSaved() async {
        let ids = state.savedIDs
        guard !ids.isEmpty else { savedVideos = []; return }
        if let r = try? await APIClient.shared.videos(byIDs: ids) {
            savedVideos = r.items
        }
    }

    private func loadFollowing() async {
        let ids = state.followingIDs
        guard !ids.isEmpty else { followingAuthors = []; return }
        if let r = try? await APIClient.shared.authorsByIDs(ids) {
            followingAuthors = r.items
        }
    }
}

// MARK: - 二级页路由
enum ProfileRoute: Identifiable {
    case play([FeedItem], FeedItem)
    case author(AuthorTarget)
    case settings

    var id: String {
        switch self {
        case .play(_, let i): return "play-\(i.vid)"
        case .author(let a): return "author-\(a.id)"
        case .settings: return "settings"
        }
    }
}