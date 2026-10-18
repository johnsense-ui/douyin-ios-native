//
//  PlayerTargetView.swift
//  DouyinLocal
//
//  通用竖滑播放页。作者主页九宫格、搜索结果、我的（喜欢/收藏）都用它。
//  默认有声，不提供静音开关。
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

    @State private var index = 0
    @State private var paused = false
    @State private var showAuthor = false

    private var items: [FeedItem] { targets }

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
                            onTap: {
                                paused.toggle()
                                if paused {
                                    pool.pause()
                                } else if index < items.count {
                                    pool.resume(items[index].vid)
                                }
                            },
                            onDoubleTap: { loc in
                                guard index < items.count else { return }
                                hearts.pop(at: loc)
                                let vid = items[index].vid
                                if !state.isLiked(vid) { state.toggleLike(vid) }
                            })
                .ignoresSafeArea()

                ForEach(hearts.bursts) { $0 }

                if index < items.count {
                    let item = items[index]
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(alignment: .leading, spacing: 8) {
                                Button { showAuthor = true } label: {
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
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                }
                            }
                            .frame(height: 88, alignment: .bottom)

                            Spacer(minLength: 0)
                            VStack(spacing: 18) {
                                ActionButton(systemImage: "heart.fill",
                                             label: item.diggText,
                                             tint: state.isLiked(item.vid) ? Theme.likeRed : .white,
                                             filled: state.isLiked(item.vid)
                                ) { state.toggleLike(item.vid) }

                                ActionButton(systemImage: "bookmark.fill",
                                             label: "收藏",
                                             tint: state.isSaved(item.vid) ? .yellow : .white,
                                             filled: state.isSaved(item.vid)
                                ) { state.toggleSave(item.vid) }
                            }
                            .frame(width: 58)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 44)
                    }
                    .allowsHitTesting(true)
                }

                if paused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 62))
                        .foregroundStyle(.white.opacity(0.5))
                        .allowsHitTesting(false)
                }
            }

            // 关闭按钮
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
            if let i = items.firstIndex(where: { $0.vid == startVid }) {
                index = i
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard !items.isEmpty else { return }
                pool.focus(on: items, index: min(index, items.count - 1))
            }
        }
        .onChange(of: index) { _, new in
            guard new < items.count else { return }
            pool.focus(on: items, index: new)
            paused = false
        }
        .sheet(isPresented: $showAuthor) {
            if index < items.count {
                AuthorView(authorId: items[index].authorId)
            }
        }
    }
}
