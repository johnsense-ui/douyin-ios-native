//
//  FeedStore.swift
//  DouyinLocal
//
//  推荐流数据源：分页拉取 + 无限加载。
//  条数与推荐算法从 AppSettings 读取。
//

import Foundation
import Combine

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var total = 0

    private var seed: String = ""
    private var offset = 0
    private var endReached = false

    private var limit: Int {
        max(4, min(30, AppSettings.shared.pageSize))
    }

    func reload() async {
        seed = ""
        offset = 0
        endReached = false
        items = []
        errorText = nil
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !endReached else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await APIClient.shared.feed(
                seed: seed.isEmpty ? nil : seed,
                offset: offset,
                limit: limit,
                algo: AppSettings.shared.algo.apiValue)
            if seed.isEmpty { seed = page.seed }
            total = page.total
            if page.items.isEmpty {
                endReached = true
            } else {
                items.append(contentsOf: page.items)
                offset += page.items.count
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    /// 距离末尾少于 N 条时预加载
    func ensureMore(currentIndex: Int) {
        guard currentIndex >= items.count - 4 else { return }
        Task { await loadMore() }
    }
}
