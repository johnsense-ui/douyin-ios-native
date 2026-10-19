//
//  PlayerTargetView.swift
//  DouyinLocal
//
//  通用竖滑播放页（作者主页九宫格、搜索结果、我的喜欢/收藏）。
//
//  注意：文案 / 右栏 / 进度条 由 PageVideoView 用 UIKit 绘制，
//  这里**只放**关闭按钮和双击爱心。不要再画一套 SwiftUI 的 UI，
//  否则会出现两层 UI 重叠（双爱心、双文案）。
//

import SwiftUI

struct PlayerTargetView: View {
    let targets: [FeedItem]
    let startVid: String
    let authorName: String

    @Environment(\.dismiss) private var dismiss

    @StateObject private var pool = PlayerPool()
    @StateObject private var hearts = HeartBurstManager()
    @ObservedObject private var state = StateStore.shared

    /// 起始页（不可变，作为 PlayerStage 的明确起点）
    private let startIndex: Int
    @State private var index: Int
    @State private var paused = false
    @State private var authorTarget: AuthorTarget?

    private var items: [FeedItem] { targets }

    init(targets: [FeedItem], startVid: String, authorName: String) {
        self.targets = targets
        self.startVid = startVid
        self.authorName = authorName
        let i = targets.firstIndex(where: { $0.vid == startVid }) ?? 0
        self.startIndex = i
        _index = State(initialValue: i)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if items.isEmpty {
                Text("没有可播放的视频")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                PlayerStage(items: items,
                            pool: pool,
                            index: $index,
                            paused: paused,
                            startAt: startIndex,
                            onTap: handleTap,
                            onDoubleTap: handleDoubleTap,
                            onLike: { state.toggleLike($0) },
                            onSave: { state.toggleSave($0) },
                            onAuthor: { authorTarget = AuthorTarget(id: $0) })
                .ignoresSafeArea()

                ForEach(hearts.bursts) { $0 }

                if paused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(.white.opacity(0.5))
                        .allowsHitTesting(false)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 54)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            // 播放/激活统一由 StageView.configure 负责（起始页已在 init 中确定），
            // 这里不再重复 focus，避免两处同时触发导致画面被静图盖住
        }
        .onChange(of: index) { _, new in
            guard new < items.count else { return }
            pool.focus(on: items, index: new)
            paused = false
        }
        .fullScreenCover(item: $authorTarget) { t in
            AuthorView(authorId: t.id)
        }
    }

    private func handleTap() {
        paused.toggle()
        if paused {
            pool.pause()
        } else if index < items.count {
            pool.resume(items[index].vid)
        }
    }

    private func handleDoubleTap(_ loc: CGPoint) {
        guard index < items.count else { return }
        hearts.pop(at: loc)
        let vid = items[index].vid
        if !state.isLiked(vid) { state.toggleLike(vid) }
    }
}
