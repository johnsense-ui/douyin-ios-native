//
//  FeedView.swift
//  DouyinLocal
//
//  推荐流：竖屏整屏吸附翻页。
//
//  实现方式说明：
//   · 用 UIScrollView + pagingEnabled 做原生分页（比 SwiftUI ScrollView 更能控制减速曲线）
//   · UI 用 SwiftUI 叠在一个透明层上（每页的文案/按钮）
//   · 视频画面由 PlayerPool 的三个 AVPlayerLayer 直接挂在容器 view 上
//     —— 只有当前页有视频画面，其它页显示封面
//

import SwiftUI
import UIKit

struct FeedView: View {
    @StateObject private var store = FeedStore()
    @StateObject private var pool = PlayerPool()
    @StateObject private var hearts = HeartBurstManager()
    @ObservedObject private var state = StateStore.shared

    @State private var index = 0
    @State private var muted = true
    @State private var paused = false
    @State private var tab = 0
    @State private var showAuthor: Author?
    @State private var showSearch = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 封面垫底：视频未就绪时露出来，避免黑屏
                if index < store.items.count {
                    CoverLayer(item: store.items[index])
                        .ignoresSafeArea()
                }

                // 原生滚动容器 + 播放器（视频 layer 在最上层）
                PlayerStage(
                    items: store.items,
                    pool: pool,
                    index: $index,
                    paused: paused
                )
                .ignoresSafeArea()

                // 交互层（在视频之上、UI 之下）
                GeometryReader { _ in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { loc in
                            guard index < store.items.count else { return }
                            let item = store.items[index]
                            hearts.pop(at: loc)
                            if !state.isLiked(item.vid) {
                                state.toggleLike(item.vid)
                            }
                        }
                        .onTapGesture(count: 1) {
                            paused.toggle()
                            paused ? pool.pause() : pool.resume()
                        }
                }
                .ignoresSafeArea()

                // 爱心
                ForEach(hearts.bursts) { h in
                    h
                }

                // 当前页的 UI
                if index < store.items.count {
                    FeedOverlay(
                        item: store.items[index],
                        muted: muted,
                        paused: paused,
                        onOpenAuthor: { aid in openAuthor(aid) },
                        onToggleMute: {
                            muted.toggle()
                            pool.setMuted(muted)
                        },
                        onLike: { state.toggleLike(store.items[index].vid) },
                        onSave: { state.toggleSave(store.items[index].vid) }
                    )
                }

                // 顶部
                VStack {
                    HStack {
                        Button { showSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 3)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)

                    Spacer()

                    TopTabs(selected: $tab, titles: ["关注", "推荐"])
                        .padding(.bottom, 12)
                }
                .allowsHitTesting(true)
            }
            .onAppear {
                pool.setMuted(muted)
                Task { await store.reload() }
            }
            .onChange(of: store.items.count) { _, _ in
                if index < store.items.count {
                    pool.focus(on: store.items, index: index)
                }
            }
            .onChange(of: index) { _, new in
                guard new < store.items.count else { return }
                pool.focus(on: store.items, index: new)
                store.ensureMore(currentIndex: new)
                paused = false
            }
            .sheet(item: $showAuthor) { a in
                AuthorView(authorId: a.authorId)
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    private func openAuthor(_ aid: String) {
        showAuthor = Author(authorId: aid, nickname: "", followerCount: 0,
                            videoCount: 0, signature: "", avatar: nil)
    }
}

// MARK: - 封面兜底层

private struct CoverLayer: View {
    let item: FeedItem
    var body: some View {
        ZStack {
            Color.black
            if let u = item.coverURL {
                CachedAsyncImage(url: u)
                    .scaledToFill()
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 当前页 UI（文案 / 操作栏 / 作者）

private struct FeedOverlay: View {
    let item: FeedItem
    let muted: Bool
    let paused: Bool
    let onOpenAuthor: (String) -> Void
    let onToggleMute: () -> Void
    let onLike: () -> Void
    let onSave: () -> Void

    @ObservedObject private var state = StateStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 底部渐变，保证文字可读
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                    .frame(height: geo.size.height * 0.42)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 12) {
                    // 左：作者 + 文案
                    VStack(alignment: .leading, spacing: 8) {
                        Button { onOpenAuthor(item.authorId) } label: {
                            HStack(spacing: 9) {
                                UserAvatar(name: item.author, size: 40)
                                Text("@\(item.author)")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)

                        if !item.caption.isEmpty {
                            Text(item.caption)
                                .font(.system(size: 14.5))
                                .foregroundStyle(.white)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: geo.size.width * 0.72, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.hPadding)
                .padding(.bottom, 96)

                // 右侧操作栏
                VStack(spacing: Theme.actionSpacing) {
                    Spacer()

                    Button { onOpenAuthor(item.authorId) } label: {
                        UserAvatar(name: item.author, size: 46)
                            .overlay(alignment: .bottom) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.primary)
                                    .background(Circle().fill(.white).padding(1.5))
                                    .offset(y: 9)
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)

                    ActionButton(
                        systemImage: state.isLiked(item.vid) ? "heart.fill" : "heart.fill",
                        label: item.diggText,
                        tint: state.isLiked(item.vid) ? Theme.likeRed : .white,
                        filled: state.isLiked(item.vid),
                        action: onLike
                    )
                    .scaleEffect(state.isLiked(item.vid) ? 1.06 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6),
                               value: state.isLiked(item.vid))

                    // 评论：无数据，隐藏
                    // ActionButton(systemImage: "ellipsis.bubble.fill", label: "评论") {}

                    ActionButton(systemImage: "arrowshape.turn.up.right.fill",
                                 label: "分享") {}

                    ActionButton(
                        systemImage: "bookmark.fill",
                        label: "收藏",
                        tint: state.isSaved(item.vid) ? .yellow : .white,
                        filled: state.isSaved(item.vid),
                        action: onSave
                    )

                    Button(action: onToggleMute) {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12)
                .padding(.bottom, 100)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 圆形头像（昵称首字）

struct UserAvatar: View {
    let name: String
    var size: CGFloat = 44

    private var initial: String {
        guard let c = name.first else { return "?" }
        return String(c)
    }

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Theme.primary.opacity(0.92),
                                        Color(red: 0.36, green: 0.22, blue: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.3))
    }
}
