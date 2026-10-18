//
//  PlayerStage.swift
//  DouyinLocal
//
//  原生分页滚动 + AVPlayerLayer 挂载 + 手势。
//
//  为什么不用 SwiftUI ScrollView：
//   · 抖音的手感依赖 UIScrollView 原生减速曲线和 rubber-band
//   · 需要在手指拖动过程中就知道目标页，提前切换播放器
//
//  手势设计（关键）：
//   · 滚动由 UIScrollView 自己处理（不再被透明层拦截）
//   · 单击 / 双击用 UITapGestureRecognizer 挂在 UIScrollView 上
//   · 双击优先于单击：singleTap 设置 require(toFail: doubleTap)
//
//  layer 挂载：
//   videoHost 是 self 的直接子视图（不放进 scrollView），铺满整屏，
//   所以视频画面永远居中，不会被滚动带偏。
//

import SwiftUI
import UIKit

struct PlayerStage: UIViewRepresentable {
    let items: [FeedItem]
    let pool: PlayerPool
    @Binding var index: Int
    let paused: Bool
    var onTap: () -> Void = {}
    var onDoubleTap: (CGPoint) -> Void = { _ in }

    func makeUIView(context: Context) -> StageView {
        let v = StageView()
        bindCallbacks(v)
        v.attachPool(pool)
        v.configure(items: items)
        return v
    }

    func updateUIView(_ v: StageView, context: Context) {
        bindCallbacks(v)
        v.attachPool(pool)
        v.applyPaused(paused)
        if v.itemsCount != items.count {
            v.configure(items: items)
        }
        if v.currentPage != index {
            v.scrollTo(index, animated: false)
        }
    }

    private func bindCallbacks(_ v: StageView) {
        v.onIndexChange = { newIndex in
            DispatchQueue.main.async {
                if index != newIndex { index = newIndex }
            }
        }
        v.onTap = {
            DispatchQueue.main.async { onTap() }
        }
        v.onDoubleTap = { p in
            DispatchQueue.main.async { onDoubleTap(p) }
        }
    }
}

// MARK: -

final class StageView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let videoHost = UIView()

    private var pool: PlayerPool?
    private var attached = false

    var onIndexChange: ((Int) -> Void)?
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?

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
        scrollView.alwaysBounceVertical = true
        scrollView.isScrollEnabled = true
        addSubview(scrollView)

        // 单击 / 双击
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingle))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDouble(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        for g in [single, double] {
            g.delegate = self
            g.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleSingle() { onTap?() }

    @objc private func handleDouble(_ g: UITapGestureRecognizer) {
        onDoubleTap?(g.location(in: self))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 与 UIScrollView 的 pan 同时存在，但抬手后仍能触发点击
        true
    }

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
        pool?.syncLayerFrames(videoHost.bounds)
        let h = bounds.height * CGFloat(max(itemsCount, 1))
        let size = CGSize(width: bounds.width, height: h)
        if scrollView.contentSize != size {
            scrollView.contentSize = size
        }
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
        if clamped != currentPage {
            currentPage = clamped
            onIndexChange?(clamped)
        }
    }
}
