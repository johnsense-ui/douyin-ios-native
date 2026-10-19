//
//  FeedView.swift
//  DouyinLocal
//
//  推荐流主界面。
//
//  叠加 UI 分两类：
//   · 页级（文案 / 右栏 / 进度条）→ 在 PageVideoView 里用 UIKit 画，跟着滚动零延迟
//   · 全局（设置/搜索按钮、底部 tab）→ SwiftUI 固定层
//

import SwiftUI

enum FeedRoute: Identifiable, Equatable {
    case author(String)
    case search
    case profile
    case settings

    var id: String {
        switch self {
        case .author(let a): return "author-\(a)"
        case .search: return "search"
        case .profile: return "profile"
        case .settings: return "settings"
        }
    }
}

struct FeedView: View {
    @StateObject private var store = FeedStore()
    @StateObject private var pool = PlayerPool()
    @StateObject private var hearts = HeartBurstManager()
    @ObservedObject private var state = StateStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var index = 0
    @State private var paused = false
    @State private var route: FeedRoute?
    /// 左滑进主页（用滑动转场，不用 fullScreenCover）
    @State private var slideAuthor: String?
    @State private var speedMode = false      // 倍速清屏

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            stageView
                .ignoresSafeArea()

            ForEach(hearts.bursts) { $0 }

            if paused && index < store.items.count {
                Image(systemName: "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }

            // 顶栏（固定）
            VStack {
                HStack(spacing: 16) {
                    Button { route = .settings } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .frame(width: 52, height: 52)      // 触摸区
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { route = .search } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .frame(width: 52, height: 52)      // 触摸区
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 3)
                .padding(.top, -8)
                Spacer()
            }
            .opacity(speedMode ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: speedMode)

            // 底部 tab（固定）
            VStack {
                Spacer()
                HStack(spacing: 52) {
                    tabItem("推荐", selected: true) {}
                    tabItem("我的", selected: false) { route = .profile }
                }
                .padding(.bottom, -6)     // 再往下压一点
            }
            .opacity(speedMode ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: speedMode)

            // 左滑进作者主页
            if let aid = slideAuthor {
                AuthorView(authorId: aid, onClose: closeSlide)
                    .background(Color.black)
                    .transition(.move(edge: .trailing))
                    .zIndex(20)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { v in
                                // 右滑返回
                                if v.translation.width > 90,
                                   abs(v.translation.height) < 80 {
                                    closeSlide()
                                }
                            }
                    )
            }
        }
        .statusBarHidden(true)
        .onAppear {
            Task {
                // 启动时先把电脑上新增的视频并进索引，再拉推荐流
                if settings.autoScan {
                    _ = try? await APIClient.shared.rescan()
                }
                await store.reload()
            }
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
        .onChange(of: settings.pageSize) { _, _ in Task { await store.reload() } }
        .onChange(of: settings.algo) { _, _ in Task { await store.reload() } }
        .onChange(of: route) { _, r in
            if r != nil { pool.pause() }
            else if !paused, index < store.items.count {
                pool.resume(store.items[index].vid)
            }
        }
        .onChange(of: slideAuthor) { _, s in
            if s != nil { pool.pause() }
            else if route == nil, !paused, index < store.items.count {
                pool.resume(store.items[index].vid)
            }
        }
        .fullScreenCover(item: $route) { r in
            switch r {
            case .author(let aid):
                AuthorView(authorId: aid)
            case .search:
                SearchView()
            case .profile:
                ProfileView()
            case .settings:
                SettingsView()
            }
        }
    }

    private var stageView: some View {
        PlayerStage(items: store.items,
                    pool: pool,
                    index: $index,
                    paused: paused,
                    onTap: handleTap,
                    onDoubleTap: handleDoubleTap,
                    onLike: { state.toggleLike($0) },
                    onSave: { state.toggleSave($0) },
                    onAuthor: { route = .author($0) },
                    onSwipeLeft: handleSwipeLeft,
                    onSpeedMode: { on in speedMode = on })
    }

    private func handleTap() {
        paused.toggle()
        if paused {
            pool.pause()
        } else if index < store.items.count {
            pool.resume(store.items[index].vid)
        }
    }

    private func handleDoubleTap(_ loc: CGPoint) {
        guard index < store.items.count else { return }
        hearts.pop(at: loc)
        let vid = store.items[index].vid
        if !state.isLiked(vid) { state.toggleLike(vid) }
    }

    private func handleSwipeLeft(_ i: Int) {
        guard i < store.items.count else { return }
        openSlideAuthor(store.items[i].authorId)
    }
    private func openSlideAuthor(_ aid: String) {
        withAnimation(.easeOut(duration: 0.22)) {
            slideAuthor = aid
        }
    }

    private func closeSlide() {
        withAnimation(.easeOut(duration: 0.2)) {
            slideAuthor = nil
        }
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
            .frame(minWidth: 88, minHeight: 52)     // 整块可点
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 圆形头像（其它页面共用）

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
                LinearGradient(colors: [Color(white: 0.58), Color(white: 0.44)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.3))
            .shadow(color: .black.opacity(0.28), radius: 2)
    }
}
