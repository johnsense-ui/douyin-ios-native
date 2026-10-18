//
//  FeedView.swift
//  DouyinLocal
//
//  推荐流主界面。
//
//  对齐抖音：
//   · 拖动时视频与叠加 UI 一起 1:1 移动（下一頁的第一帧从下方进来）
//   · 旧视频在拖动期间继续播放，落位后才切换
//   · 右栏/文案属于「页」，跟着滚；底部 tab 与搜索按钮固定
//   · 二级页（作者/搜索/我的/设置）全屏，进入时暂停推荐流，返回恢复原视频
//

import SwiftUI

/// 拖动偏移（单位：页）
final class ScrollPhase: ObservableObject {
    @Published var delta: CGFloat = 0
}

/// 二级页路由
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
    /// 用 @State 而非 @StateObject：拖动时只让叠加 UI 重绘，不重绘整页
    @State private var phase = ScrollPhase()
    @ObservedObject private var state = StateStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var index = 0
    @State private var paused = false
    @State private var route: FeedRoute?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerStage(items: store.items,
                        pool: pool,
                        index: $index,
                        paused: paused,
                        onTap: {
                            paused.toggle()
                            if paused {
                                pool.pause()
                            } else if index < store.items.count {
                                pool.resume(store.items[index].vid)
                            }
                        },
                        onDoubleTap: { loc in
                            guard index < store.items.count else { return }
                            hearts.pop(at: loc)
                            let vid = store.items[index].vid
                            if !state.isLiked(vid) { state.toggleLike(vid) }
                        },
                        onDelta: { d in
                            phase.delta = d
                        })
            .ignoresSafeArea()

            ForEach(hearts.bursts) { $0 }

            if paused && index < store.items.count {
                Image(systemName: "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }

            FeedOverlayUI(phase: phase,
                          items: store.items,
                          settled: index,
                          onAuthor: { aid in route = .author(aid) },
                          onLike: { vid in state.toggleLike(vid) },
                          onSave: { vid in state.toggleSave(vid) },
                          onSearch: { route = .search },
                          onProfile: { route = .profile },
                          onSettings: { route = .settings })
        }
        .statusBarHidden(true)
        .onAppear { Task { await store.reload() } }
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
            // 进二级页：停声；回来：原视频继续
            if r != nil {
                pool.pause()
            } else if !paused, index < store.items.count {
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
}

// MARK: - 叠加 UI

struct FeedOverlayUI: View {
    @ObservedObject var phase: ScrollPhase
    let items: [FeedItem]
    let settled: Int
    let onAuthor: (String) -> Void
    let onLike: (String) -> Void
    let onSave: (String) -> Void
    let onSearch: () -> Void
    let onProfile: () -> Void
    let onSettings: () -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                // 页面级 UI：跟着滚动位移
                ForEach([-1, 0, 1], id: \.self) { d in
                    let idx = settled + d
                    if idx >= 0 && idx < items.count {
                        FeedPageUI(item: items[idx],
                                   onAuthor: { onAuthor(items[idx].authorId) },
                                   onLike: { onLike(items[idx].vid) },
                                   onSave: { onSave(items[idx].vid) })
                            .frame(width: geo.size.width, height: h)
                            .offset(y: (CGFloat(d) - phase.delta) * h)
                    }
                }

                // 顶栏（固定）
                VStack {
                    HStack(spacing: 16) {
                        Button(action: onSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 4)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(action: onSearch) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    Spacer()
                }

                // 底部 tab（固定）
                VStack {
                    Spacer()
                    HStack(spacing: 52) {
                        tabItem("推荐", selected: true) {}
                        tabItem("我的", selected: false) { onProfile() }
                    }
                    .padding(.bottom, 8)
                }
            }
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
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 单页 UI（文案 + 右栏）

private struct FeedPageUI: View {
    let item: FeedItem
    let onAuthor: () -> Void
    let onLike: () -> Void
    let onSave: () -> Void

    @ObservedObject private var state = StateStore.shared
    @State private var expanded = false

    var body: some View {
        ZStack {
            // 右侧操作栏
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

                    Spacer().frame(height: 76)
                }
                .frame(width: 64)
                .padding(.trailing, 4)
            }

            // 左下文案
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Button(action: onAuthor) {
                            HStack(spacing: 9) {
                                UserAvatar(name: item.author, size: 38)
                                Text("@\(item.author)")
                                    .font(.system(size: 15.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)

                        if !item.caption.isEmpty {
                            Text(item.caption)
                                .font(.system(size: 14.5))
                                .foregroundStyle(.white)
                                .lineLimit(expanded ? nil : 2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        expanded.toggle()
                                    }
                                }
                        }
                    }
                    .frame(height: 92, alignment: .bottom)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.trailing, 96)
                .padding(.bottom, 58)
            }
        }
    }
}

// MARK: - 圆形头像

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
