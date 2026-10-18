//
//  FeedView.swift
//  DouyinLocal
//
//  推荐流主界面。
//
//  层级（从下到上）：
//    1. 封面（垫底，防黑屏）
//    2. PlayerStage（视频画面 + 滚动手势，全屏）
//    3. 爱心
//    4. 叠加 UI（文案、右栏、顶栏、底部 tab）
//
//  关键修复：
//    · 单击/双击手势交给 PlayerStage 的 UIScrollView 处理，不再用全屏透明层拦截
//    · 右栏 UI 用 HStack{Spacer; VStack} 定位，不再溢出屏幕
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
    @State private var showAuthor: AuthorTarget?
    @State private var showSearch = false
    @State private var showProfile = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if index < store.items.count {
                CoverLayer(item: store.items[index])
            }

            PlayerStage(items: store.items,
                        pool: pool,
                        index: $index,
                        paused: paused,
                        onTap: {
                            paused.toggle()
                            paused ? pool.pause() : pool.resume()
                        },
                        onDoubleTap: { loc in
                            guard index < store.items.count else { return }
                            hearts.pop(at: loc)
                            let vid = store.items[index].vid
                            if !state.isLiked(vid) { state.toggleLike(vid) }
                        })
            .ignoresSafeArea()

            ForEach(hearts.bursts) { $0 }

            // 底部文案（左下）
            if index < store.items.count {
                FeedCaption(item: store.items[index],
                            onAuthor: { showAuthor = AuthorTarget(id: store.items[index].authorId) })
            }

            // 右侧操作栏
            if index < store.items.count {
                FeedActionRail(item: store.items[index],
                               muted: muted,
                               onAuthor: { showAuthor = AuthorTarget(id: store.items[index].authorId) },
                               onLike: { state.toggleLike(store.items[index].vid) },
                               onSave: { state.toggleSave(store.items[index].vid) },
                               onMute: {
                                   muted.toggle()
                                   pool.setMuted(muted)
                               })
            }

            // 顶栏
            VStack {
                HStack {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                Spacer()
            }

            // 底部 tab
            VStack {
                Spacer()
                HStack(spacing: 52) {
                    tabItem("推荐", selected: true) {}
                    tabItem("我的", selected: false) { showProfile = true }
                }
                .padding(.bottom, 10)
            }

            if paused && index < store.items.count {
                Image(systemName: "play.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
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
        .sheet(item: $showAuthor) { t in
            AuthorView(authorId: t.id)
        }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(isPresented: $showProfile) { ProfileView() }
    }

    private func tabItem(_ title: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: selected ? 17.5 : 16,
                                  weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.62))
                Capsule()
                    .fill(selected ? Color.white : .clear)
                    .frame(width: 18, height: 2)
            }
            .shadow(color: .black.opacity(0.45), radius: 3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 封面垫底

private struct CoverLayer: View {
    let item: FeedItem
    var body: some View {
        ZStack {
            Color.black
            if let u = item.coverURL {
                CachedAsyncImage(url: u).scaledToFill()
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 左下文案

private struct FeedCaption: View {
    let item: FeedItem
    let onAuthor: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                Button(action: onAuthor) {
                    HStack(spacing: 9) {
                        UserAvatar(name: item.author, size: 40)
                        Text("@\(item.author)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                if !item.caption.isEmpty {
                    Text(item.caption)
                        .font(.system(size: 14.5))
                        .foregroundStyle(.white)
                        .lineLimit(expanded ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                expanded.toggle()
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 96)
            .padding(.bottom, 62)
        }
    }
}

// MARK: - 右侧操作栏

private struct FeedActionRail: View {
    let item: FeedItem
    let muted: Bool
    let onAuthor: () -> Void
    let onLike: () -> Void
    let onSave: () -> Void
    let onMute: () -> Void

    @ObservedObject private var state = StateStore.shared

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Spacer(minLength: 0)

                Button(action: onAuthor) {
                    UserAvatar(name: item.author, size: 46)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    if !state.isFollowing(item.authorId) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(Theme.primary))
                            .offset(y: 9)
                    }
                }
                .padding(.bottom, 8)

                ActionButton(systemImage: "heart.fill",
                             label: item.diggText,
                             tint: state.isLiked(item.vid) ? Theme.likeRed : .white,
                             filled: state.isLiked(item.vid),
                             action: onLike)

                ActionButton(systemImage: "arrowshape.turn.up.right.fill",
                             label: "分享", action: {})

                ActionButton(systemImage: "bookmark.fill",
                             label: "收藏",
                             tint: state.isSaved(item.vid) ? .yellow : .white,
                             filled: state.isSaved(item.vid),
                             action: onSave)

                Button(action: onMute) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 74)
            }
            .frame(width: 62)
            .padding(.trailing, 6)
        }
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
            .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.3))
            .shadow(color: .black.opacity(0.28), radius: 2)
    }
}
