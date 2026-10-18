//
//  StateStore.swift
//  DouyinLocal
//
//  点赞 / 收藏。本地即时生效，后台异步同步到服务端。
//  初始为空 —— 不读取任何原有 db。
//

import Foundation
import Combine

@MainActor
final class StateStore: ObservableObject {
    static let shared = StateStore()

    @Published private(set) var liked: Set<String> = []
    @Published private(set) var saved: Set<String> = []

    private let likedKey = "state.liked"
    private let savedKey = "state.saved"
    private var pendingLiked: [String: Bool] = [:]
    private var pendingSaved: [String: Bool] = [:]
    private var flushTask: Task<Void, Never>?

    init() { load() }

    // MARK: - 本地持久化

    private func load() {
        let d = UserDefaults.standard
        liked = Set(d.stringArray(forKey: likedKey) ?? [])
        saved = Set(d.stringArray(forKey: savedKey) ?? [])
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Array(liked), forKey: likedKey)
        d.set(Array(saved), forKey: savedKey)
    }

    // MARK: - 查询

    func isLiked(_ vid: String) -> Bool { liked.contains(vid) }
    func isSaved(_ vid: String) -> Bool { saved.contains(vid) }

    // MARK: - 写入

    /// 返回最新状态（方便调用方做动画）
    @discardableResult
    func toggleLike(_ vid: String) -> Bool {
        let now: Bool
        if liked.contains(vid) {
            liked.remove(vid); now = false
        } else {
            liked.insert(vid); now = true
        }
        pendingLiked[vid] = now
        persist()
        scheduleFlush()
        return now
    }

    @discardableResult
    func toggleSave(_ vid: String) -> Bool {
        let now: Bool
        if saved.contains(vid) {
            saved.remove(vid); now = false
        } else {
            saved.insert(vid); now = true
        }
        pendingSaved[vid] = now
        persist()
        scheduleFlush()
        return now
    }

    /// 合并服务端返回的状态
    func merge(liked vids: [String], saved svids: [String]) {
        liked.formUnion(vids)
        saved.formUnion(svids)
        persist()
    }

    // MARK: - 同步（合并请求，避免连点刷爆）

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self else { return }
            await self.flush()
        }
    }

    private func flush() async {
        guard !pendingLiked.isEmpty || !pendingSaved.isEmpty else { return }
        let l = pendingLiked
        let s = pendingSaved
        pendingLiked.removeAll()
        pendingSaved.removeAll()
        await APIClient.shared.pushState(liked: l, saved: s)
    }
}
