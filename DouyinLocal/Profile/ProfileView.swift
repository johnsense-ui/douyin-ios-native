//
//  ProfileView.swift
//  DouyinLocal
//
//  「我的」个人主页。
//
//  数据全部来自 App 内的操作（StateStore），
//  不与本地原始 db 的任何数据合并。
//
//  结构：
//    头部：头像 + 昵称 + 关注/粉丝/获赞 数字
//    Tab：喜欢 / 收藏 / 关注
//

import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = StateStore.shared

    @State private var tab = 0
    @State private var likedVideos: [FeedItem] = []
    @State private var savedVideos: [FeedItem] = []
    @State private var followingAuthors: [Author] = []
    @State private var loading = false
    @State private var playing: FeedItem?
    @State private var authorTarget: AuthorTarget?

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
                        tabBar
                        content
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: state.likedCount) { _, _ in
            Task { await loadLiked() }
        }
        .onChange(of: state.savedCount) { _, _ in
            Task { await loadSaved() }
        }
        .onChange(of: state.followingCount) { _, _ in
            Task { await loadFollowing() }
        }
        .fullScreenCover(item: $playing) { item in
            PlayerTargetView(targets: playbackList, startVid: item.vid,
                             authorName: item.author)
        }
        .sheet(item: $authorTarget) { t in
            AuthorView(authorId: t.id)
        }
    }

    // MARK: - 顶栏

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                UserAvatar(name: "我的", size: 80)
                VStack(alignment: .leading, spacing: 6) {
                    Text("我的收藏夹")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 18) {
                        stat(state.followingCount, "关注")
                        stat(0, "粉丝")
                        stat(state.likedCount, "喜欢")
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func stat(_ n: Int, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text("\(n)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text(t)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Tab

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabItem(0, "喜欢", state.likedCount)
            tabItem(1, "收藏", state.savedCount)
            tabItem(2, "关注", state.followingCount)
        }
        .overlay(alignment: .bottom) {
            Divider().background(Color.white.opacity(0.12))
        }
    }

    private func tabItem(_ i: Int, _ title: String, _ n: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { tab = i }
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
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Capsule()
                    .fill(tab == i ? Color.white : .clear)
                    .frame(width: 20, height: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 8)
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
                        Button {
                            authorTarget = AuthorTarget(id: a.authorId)
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
                                Spacer()
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
                        .buttonStyle(.plain)
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
                        Button { playing = item } label: {
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

    private var playbackList: [FeedItem] {
        tab == 0 ? likedVideos : savedVideos
    }

    // MARK: - 数据

    private func load() async {
        async let a: () = loadLiked()
        async let b: () = loadSaved()
        async let c: () = loadFollowing()
        _ = await (a, b, c)
    }

    private func loadLiked() async {
        let ids = state.likedIDs
        guard !ids.isEmpty else { likedVideos = []; return }
        do {
            likedVideos = try await APIClient.shared.videos(byIDs: ids).items
        } catch {
            print("loadLiked:", error)
        }
    }

    private func loadSaved() async {
        let ids = state.savedIDs
        guard !ids.isEmpty else { savedVideos = []; return }
        do {
            savedVideos = try await APIClient.shared.videos(byIDs: ids).items
        } catch {
            print("loadSaved:", error)
        }
    }

    private func loadFollowing() async {
        let ids = state.followingIDs
        guard !ids.isEmpty else { followingAuthors = []; return }
        do {
            followingAuthors = try await APIClient.shared.authorsByIDs(ids).items
        } catch {
            print("loadFollowing:", error)
        }
    }
}
