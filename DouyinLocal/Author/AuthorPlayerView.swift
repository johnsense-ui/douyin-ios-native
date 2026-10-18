//
//  AuthorPlayerView.swift
//  DouyinLocal
//
//  从作者主页九宫格进入的播放页：
//  拉取该作者全部作品（full=1，含视频地址），从点击的那一条开始竖滑播放。
//

import SwiftUI

struct AuthorPlayerView: View {
    let authorId: String
    let startVid: String
    let authorName: String

    @Environment(\.dismiss) private var dismiss

    @State private var items: [FeedItem] = []
    @StateObject private var pool = PlayerPool()
    @StateObject private var hearts = HeartBurstManager()
    @ObservedObject private var state = StateStore.shared

    @State private var index = 0
    @State private var muted = true
    @State private var paused = false
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loading && items.isEmpty {
                ProgressView().tint(.white)
            } else if items.isEmpty {
                Text(errorText ?? "没有可播放的作品")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                content
            }

            // 关闭
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    Spacer()
                    Text("\(index + 1)/\(items.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear { pool.setMuted(muted) }
        .task { await load() }
        .onChange(of: index) { _, new in
            guard new < items.count else { return }
            pool.focus(on: items, index: new)
            paused = false
        }
    }

    @ViewBuilder
    private var content: some View {
        PlayerStage(items: items, pool: pool, index: $index, paused: paused)
            .ignoresSafeArea()

        if index < items.count, let u = items[index].coverURL {
            CachedAsyncImage(url: u)
                .scaledToFill()
                .ignoresSafeArea()
        }

        GeometryReader { _ in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { loc in
                    guard index < items.count else { return }
                    hearts.pop(at: loc)
                    let vid = items[index].vid
                    if !state.isLiked(vid) { state.toggleLike(vid) }
                }
                .onTapGesture {
                    paused.toggle()
                    paused ? pool.pause() : pool.resume()
                }
        }
        .ignoresSafeArea()

        ForEach(hearts.bursts) { $0 }

        if index < items.count {
            let item = items[index]
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 9) {
                            UserAvatar(name: authorName, size: 38)
                            Text("@\(authorName)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        if !item.caption.isEmpty {
                            Text(item.caption)
                                .font(.system(size: 14.5))
                                .foregroundStyle(.white)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 20) {
                        ActionButton(
                            systemImage: "heart.fill",
                            label: item.diggText,
                            tint: state.isLiked(item.vid) ? Theme.likeRed : .white,
                            filled: state.isLiked(item.vid)
                        ) { state.toggleLike(item.vid) }

                        ActionButton(
                            systemImage: "bookmark.fill",
                            label: "收藏",
                            tint: state.isSaved(item.vid) ? .yellow : .white,
                            filled: state.isSaved(item.vid)
                        ) { state.toggleSave(item.vid) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 44)
            }
            .allowsHitTesting(true)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
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
            items = all
            if let i = items.firstIndex(where: { $0.vid == startVid }) {
                index = i
            }
            if !items.isEmpty {
                pool.focus(on: items, index: index)
                paused = false
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
