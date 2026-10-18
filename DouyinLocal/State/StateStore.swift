//
//  StateStore.swift
//  DouyinLocal
//
//  本地点赞 / 收藏 / 关注。
//  初始全空 —— 不读取任何原有 db，也不与原始数据合并。
//  本地即时生效，后台异步同步到服务端 state.json。
//

import Foundation
import Combine

@MainActor
final class StateStore: ObservableObject {
    static let shared = StateStore()

    @Published private(set) var liked: Set<String> = []
    @Published private(set) var saved: Set<String> = []
    /// 关注的作者 authorId
    @Published private(set) var following: Set<String> = []

    private let likedKey = "state.liked"
    private let savedKey = "state.saved"
    private let followKey = "state.following"

    private var pendingLiked: [String: Bool] = [:]
    private var pendingSaved: [String: Bool] = [:]
    private var pendingFollow: [String: Bool] = [:]
    private var flushTask: Task<Void, Never>?

    init() { load() }

    // MARK: - 持久化

    private func load() {
        let d = UserDefaults.standard
        liked = Set(d.stringArray(forKey: likedKey) ?? [])
        saved = Set(d.stringArray(forKey: savedKey) ?? [])
        following = Set(d.stringArray(forKey: followKey) ?? [])
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Array(liked), forKey: likedKey)
        d.set(Array(saved), forKey: savedKey)
        d.set(Array(following), forKey: followKey)
    }

    // MARK: - 查询

    func isLiked(_ vid: String) -> Bool { liked.contains(vid) }
    func isSaved(_ vid: String) -> Bool { saved.contains(vid) }
    func isFollowing(_ authorId: String) -> Bool { following.contains(authorId) }

    var likedCount: Int { liked.count }
    var savedCount: Int { saved.count }
    var followingCount: Int { following.count }

    var likedIDs: [String] { Array(liked) }
    var savedIDs: [String] { Array(saved) }
    var followingIDs: [String] { Array(following) }

    // MARK: - 写入

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

    @discardableResult
    func toggleFollow(_ authorId: String) -> Bool {
        let now: Bool
        if following.contains(authorId) {
            following.remove(authorId); now = false
        } else {
            following.insert(authorId); now = true
        }
        pendingFollow[authorId] = now
        persist()
        scheduleFlush()
        return now
    }

    /// 合并服务端返回的状态（首次启动时拉取）
    func merge(liked l: [String], saved s: [String], following f: [String]) {
        liked.formUnion(l)
        saved.formUnion(s)
        following.formUnion(f)
        persist()
    }

    // MARK: - 同步

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.flush()
        }
    }

    private func flush() async {
        guard !pendingLiked.isEmpty || !pendingSaved.isEmpty || !pendingFollow.isEmpty else {
            return
        }
        let l = pendingLiked, s = pendingSaved, f = pendingFollow
        pendingLiked.removeAll()
        pendingSaved.removeAll()
        pendingFollow.removeAll()
        await APIClient.shared.pushState(liked: l, saved: s, following: f)
    }
}
