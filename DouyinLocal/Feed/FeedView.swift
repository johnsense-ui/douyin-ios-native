//
//  FeedView.swift
//  DouyinLocal
//
//  推荐流主界面。
//
//  UI 一致性：所有元素位置固定（不随文案长短漂移），
//  避免「每次打开长得不一样」的观感。
//
//  视频比例：PlayerStage 内部用 resizeAspect，完整显示不拉伸。
//

import SwiftUI
import UIKit

/// 拖动状态。只在跨越阈值时翻转一次，避免每帧重绘拖慢视频。
final class ScrollPhase: ObservableObject {
    @Published var dragging = false
}

struct FeedView: View {
    @StateObject private var store = FeedStore()
    @StateObject private var pool = PlayerPool()
    @StateObject private var hearts = HeartBurstManager()
    @StateObject private var phase = ScrollPhase()
    @ObservedObject private var state = StateStore.shared

    @State private var index = 0
    @State private var paused = false
    @State private var showAuthor: AuthorTarget?
    @State private var showSearch = false
    @State private var showProfile = false

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
                        onProgress: { p in
                            let d = abs(p) > 0.12
                            if phase.dragging != d { phase.dragging = d }
                        })
            .ignoresSafeArea()

            ForEach(hearts.bursts) { $0 }

            if paused && index < store.items.count {
                Image(systemName: "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.5))
                    .allowsHitTesting(false)
            }

            // 叠加 UI（跟随滚动淡出，切页时不打架）
            FeedOverlayUI(phase: phase,
                          item: index < store.items.count ? store.items[index] : nil,
                          paused: $paused,
                          onAuthor: {
                              if index < store.items.count {
                                  showAuthor = AuthorTarget(id: store.items[index].authorId)
                              }
                          },
                          onLike: {
                              if index < store.items.count {
                                  state.toggleLike(store.items[index].vid)
                              }
                          },
                          onSave: {
                              if index < store.items.count {
                                  state.toggleSave(store.items[index].vid)
                              }
                          },
                          onSearch: { showSearch = true },
                          onProfile: { showProfile = true })
        }
        .statusBarHidden(true)
        .onAppear {
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
}

// MARK: - 叠加 UI（位置全部固定）

struct FeedOverlayUI: View {
    @ObservedObject var phase: ScrollPhase
    let item: FeedItem?
    @Binding var paused: Bool
    let onAuthor: () -> Void
    let onLike: () -> Void
    let onSave: () -> Void
    let onSearch: () -> Void
    let onProfile: () -> Void

    @ObservedObject private var state = StateStore.shared
    @State private var expanded = false

    /// 拖动中隐藏 UI，落位后回来（只有两次状态切换，不影响帧率）
    private var fade: Double { phase.dragging ? 0 : 1 }

    var body: some View {
        ZStack {
            // 顶部搜索
            VStack {
                HStack {
                    Button(action: onSearch) {
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
            .opacity(0.3 + 0.7 * fade)

            // 右侧操作栏：固定宽度 + 固定底距
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let item {
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
                    .opacity(fade)
                }
            }

            // 左下文案：固定高度区块，底对齐
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if let item {
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
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.trailing, 96)
                .padding(.bottom, 58)
                .opacity(fade)
            }

            // 底部 tab：固定位置
            VStack {
                Spacer()
                HStack(spacing: 52) {
                    tabItem("推荐", selected: true) {}
                    tabItem("我的", selected: false) { onProfile() }
                }
                .padding(.bottom, 8)
            }
        }
        .animation(.easeOut(duration: 0.12), value: fade)
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
