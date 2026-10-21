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
import AVFoundation

struct PlayerTargetView: View {
    let targets: [FeedItem]
    let startVid: String
    let authorName: String
    /// 可选：从第几秒开始播（找相似跳转用）
    let startTime: Double?

    @Environment(\.dismiss) private var dismiss

    @StateObject private var pool = PlayerPool()
    @StateObject private var hearts = HeartBurstManager()
    @ObservedObject private var state = StateStore.shared

    /// 起始页（不可变，作为 PlayerStage 的明确起点）
    private let startIndex: Int
    @State private var index: Int
    @State private var paused = false
    @State private var authorTarget: AuthorTarget?
    @State private var similarTarget: SimilarTarget?

    private var items: [FeedItem] { targets }

    init(targets: [FeedItem], startVid: String, authorName: String,
         startTime: Double? = nil) {
        self.targets = targets
        self.startVid = startVid
        self.authorName = authorName
        self.startTime = startTime
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
                    VStack(spacing: 22) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 62))
                            .foregroundStyle(.white.opacity(0.5))
                            .allowsHitTesting(false)

                        if index < items.count {
                            let it = items[index]
                            FindSimilarButton(
                                vid: it.vid,
                                t: pool.currentTime(of: it.vid) ?? 0,
                                frameURL: APIClient.frameURL(it.vid),
                                author: it.author,
                                target: $similarTarget)
                        }
                    }
                    .offset(y: 30)
                }
            }

            VStack {
                HStack {
                    // 位置指示：点第几个就应该显示几
                    Text("\(index + 1)/\(items.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.45)))
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
            seekToStartIfNeeded()
        }
        .onChange(of: index) { _, new in
            guard new < items.count else { return }
            pool.focus(on: items, index: new)
            paused = false
        }
        .fullScreenCover(item: $authorTarget) { t in
            AuthorView(authorId: t.id)
        }
        .fullScreenCover(item: $similarTarget) { t in
            SimilarView(queryVid: t.vid,
                        queryTime: t.t,
                        queryFrameURL: t.frameURL,
                        authorName: t.author)
        }
    }

    /// 找相似跳转：等到播放器就绪后 seek 到匹配时间点
    private func seekToStartIfNeeded() {
        guard let t = startTime, t > 0.3 else { return }
        // 播放器准备需要一点时间，延迟执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard index < items.count else { return }
            let it = items[index]
            guard it.vid == startVid else { return }
            guard let p = pool.playerIfAny(for: it.vid) else { return }
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
            dlog(.play, vid: it.vid, "跳转到 \(String(format: "%.2f", t))s")
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
