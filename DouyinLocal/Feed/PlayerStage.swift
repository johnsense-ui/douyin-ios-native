//
//  PlayerStage.swift
//  DouyinLocal
//
//  原生分页滚动 + AVPlayerLayer 挂载。
//
//  为什么不用 SwiftUI ScrollView：
//   · 抖音的手感依赖 UIScrollView 原生减速曲线和 rubber-band
//   · 需要在手指拖动过程中就知道目标页，提前切换播放器
//
//  layer 挂载策略：
//   videoHost 是 self 的直接子视图（不放进 scrollView），铺满整屏。
//   所以视频画面永远居中显示，不会被滚动带偏。
//

import SwiftUI
import UIKit

struct PlayerStage: UIViewRepresentable {
    let items: [FeedItem]
    let pool: PlayerPool
    @Binding var index: Int
    let paused: Bool

    func makeUIView(context: Context) -> StageView {
        let v = StageView()
        v.onIndexChange = { newIndex in
            DispatchQueue.main.async {
                if index != newIndex { index = newIndex }
            }
        }
        v.attachPool(pool)
        v.configure(items: items)
        return v
    }

    func updateUIView(_ v: StageView, context: Context) {
        // 回调闭包每次都刷新，确保拿到最新的 Binding
        v.onIndexChange = { newIndex in
            DispatchQueue.main.async {
                if index != newIndex { index = newIndex }
            }
        }
        v.attachPool(pool)
        v.applyPaused(paused)
        if v.itemsCount != items.count {
            v.configure(items: items)
        }
        if v.currentPage != index {
            v.scrollTo(index, animated: false)
        }
    }
}

// MARK: -

final class StageView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    /// 视频画面宿主：直接挂在 self 上，不受滚动影响
    private let videoHost = UIView()

    private var pool: PlayerPool?
    private var attached = false

    /// 页变化回调（由 SwiftUI 层设置）
    var onIndexChange: ((Int) -> Void)?

    /// 当前页（只由滚动驱动，不反向绑定 Binding）
    private(set) var currentPage: Int = 0

    private(set) var itemsCount = 0
    private var pausedNow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        videoHost.backgroundColor = .clear
        videoHost.isUserInteractionEnabled = false
        addSubview(videoHost)

        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = true
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attachPool(_ p: PlayerPool) {
        pool = p
        if !attached {
            p.attach(to: videoHost)
            attached = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoHost.frame = bounds
        scrollView.frame = bounds
        let h = bounds.height * CGFloat(max(itemsCount, 1))
        scrollView.contentSize = CGSize(width: bounds.width, height: h)
    }

    func configure(items: [FeedItem]) {
        itemsCount = items.count
        setNeedsLayout()
        layoutIfNeeded()
        scrollTo(currentPage < items.count ? currentPage : 0, animated: false)
    }

    func scrollTo(_ i: Int, animated: Bool) {
        guard i >= 0, i < max(itemsCount, 1), bounds.height > 0 else { return }
        let y = CGFloat(i) * bounds.height
        scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        currentPage = i
    }

    func applyPaused(_ p: Bool) {
        guard p != pausedNow else { return }
        pausedNow = p
        if p { pool?.pause() } else { pool?.resume() }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let page = Int((sv.contentOffset.y / bounds.height).rounded())
        let clamped = max(0, min(page, itemsCount - 1))
        if clamped != currentPage {
            currentPage = clamped
            onIndexChange?(clamped)
        }
    }

    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { snap(sv) }
    }

    func scrollViewDidEndDecelerating(_ sv: UIScrollView) {
        snap(sv)
    }

    private func snap(_ sv: UIScrollView) {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let page = Int((sv.contentOffset.y / bounds.height).rounded())
        let clamped = max(0, min(page, itemsCount - 1))
        if clamped != currentPage { currentPage = clamped; onIndexChange?(clamped) }
    }
}
