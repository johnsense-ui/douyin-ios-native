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

    @Environment(\.dismiss) private var dismiss
    @State private var author: Author?
    @State private var items: [VideoThumb] = []
    @State private var total = 0
    @State private var loading = true
    @State private var offset = 0
    @State private var playing: PlayStart?
    @State private var playItems: [FeedItem] = []
    @State private var preparing = false
    @ObservedObject private var state = StateStore.shared

    private let limit = 30
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
                    Button { dismiss() } label: {
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
        VStack(spacing: 12) {
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
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
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
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.35)))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Divider().background(Color.white.opacity(0.12))
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
                    let d = try await APIClient.shared.authorItems(authorId, offset: off, limit: lim)
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
            let d = try await APIClient.shared.author(authorId, offset: offset, limit: limit)
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
