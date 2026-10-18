//
//  PlayerStage.swift
//  DouyinLocal
//
//  分页滚动容器。
//
//  关键顺序（这是之前黑屏的根因）：
//    先 pool.keep() 扩大保留窗口，再 syncPages() 重排页面
//    —— 反过来的话播放器池会在窗口还没更新时判定「无可用槽」，
//       从而抢占正在播放的那个播放器，导致第 4 个视频起黑屏。
//

import SwiftUI
import UIKit
import AVFoundation

struct PlayerStage: UIViewRepresentable {
    let items: [FeedItem]
    let pool: PlayerPool
    @Binding var index: Int
    let paused: Bool
    var onTap: () -> Void = {}
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    var onLike: (String) -> Void = { _ in }
    var onSave: (String) -> Void = { _ in }
    var onAuthor: (String) -> Void = { _ in }
    var onSwipeLeft: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> StageView {
        let v = StageView()
        bind(v)
        v.configure(items: items)
        return v
    }

    func updateUIView(_ v: StageView, context: Context) {
        bind(v)
        v.applyPaused(paused)
        if v.itemsCount != items.count {
            v.configure(items: items)
        } else if v.settledPage != index {
            v.jumpTo(index)
        }
    }

    private func bind(_ v: StageView) {
        v.onIndexChange = { newIndex in
            DispatchQueue.main.async {
                if index != newIndex { index = newIndex }
            }
        }
        v.onTap = { DispatchQueue.main.async { onTap() } }
        v.onDoubleTap = { p in DispatchQueue.main.async { onDoubleTap(p) } }
        v.onLike = { vid in DispatchQueue.main.async { onLike(vid) } }
        v.onSave = { vid in DispatchQueue.main.async { onSave(vid) } }
        v.onAuthor = { aid in DispatchQueue.main.async { onAuthor(aid) } }
        v.onSwipeLeft = { i in DispatchQueue.main.async { onSwipeLeft(i) } }
        v.pool = pool
    }
}

// MARK: - 容器

final class StageView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private var pages: [PageVideoView] = (0..<3).map { _ in PageVideoView() }

    var pool: PlayerPool? {
        didSet {
            guard let pool else { return }
            pool.onReady = { [weak self] vid in
                self?.pages.first(where: { $0.vid == vid })?.markReady()
            }
            pool.onEnd = { [weak self] vid in
                self?.handlePlaybackEnd(vid)
            }
        }
    }

    private(set) var items: [FeedItem] = []
    private(set) var itemsCount = 0
    private(set) var settledPage = 0
    private var centerPage = 0

    var onIndexChange: ((Int) -> Void)?
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onLike: ((String) -> Void)?
    var onSave: ((String) -> Void)?
    var onAuthor: ((String) -> Void)?
    var onSwipeLeft: ((Int) -> Void)?

    private var pausedNow = false
    private var adjustingRate = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)

        for p in pages {
            p.isHidden = true
            p.onLike = { [weak self] v in self?.onLike?(v) }
            p.onSave = { [weak self] v in self?.onSave?(v) }
            p.onAuthor = { [weak self] a in self?.onAuthor?(a) }
            scrollView.addSubview(p)
        }

        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingle))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDouble(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
        long.minimumPressDuration = 0.28

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        swipe.direction = .left

        for g in [single, double, long, swipe] as [UIGestureRecognizer] {
            g.delegate = self
            g.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 手势

    @objc private func handleSingle() { onTap?() }

    @objc private func handleDouble(_ g: UITapGestureRecognizer) {
        onDoubleTap?(g.location(in: self))
    }

    @objc private func handleSwipeLeft() {
        onSwipeLeft?(settledPage)
    }

    @objc private func handleLong(_ g: UILongPressGestureRecognizer) {
        guard AppSettings.shared.longPressSpeed else { return }
        guard settledPage < items.count else { return }
        let vid = items[settledPage].vid
        switch g.state {
        case .began:
            adjustingRate = true
            pool?.setRate(2.0, vid: vid)
        case .ended, .cancelled, .failed:
            if adjustingRate {
                adjustingRate = false
                pool?.setRate(1.0, vid: vid)
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// 点在按钮/可点行上时，不要让单击手势触发暂停
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let cur = v {
            if cur is UIControl { return false }
            v = cur.superview
        }
        return true
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let h = bounds.height * CGFloat(max(itemsCount, 1))
        let size = CGSize(width: bounds.width, height: h)
        if scrollView.contentSize != size {
            scrollView.contentSize = size
        }
        syncPages()
    }

    func configure(items: [FeedItem]) {
        self.items = items
        itemsCount = items.count
        settledPage = min(settledPage, max(itemsCount - 1, 0))
        centerPage = settledPage

        for p in pages {
            p.pageIndex = -1
            p.isHidden = true
            p.playerLayer.player = nil
        }
        setNeedsLayout()
        layoutIfNeeded()
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(settledPage) * bounds.height),
                                    animated: false)
        pool?.keep(items, around: settledPage)
        syncPages()
        pool?.focus(on: items, index: settledPage)
    }

    func jumpTo(_ i: Int) {
        guard i >= 0, i < max(itemsCount, 1), bounds.height > 0 else { return }
        settledPage = i
        centerPage = i
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(i) * bounds.height),
                                    animated: false)
        pool?.keep(items, around: i)
        syncPages()
    }

    func applyPaused(_ p: Bool) {
        guard p != pausedNow else { return }
        pausedNow = p
        if p {
            pool?.pause()
        } else if settledPage < items.count {
            pool?.resume(items[settledPage].vid)
        }
    }

    /// 外部状态变化后刷新当前页图标
    func refreshCurrentPage() {
        for p in pages where p.pageIndex == settledPage {
            p.refreshState()
        }
    }

    // MARK: 页面分配

    private func syncPages() {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let h = bounds.height, w = bounds.width

        var needed = Set<Int>()
        for d in -1...1 {
            let i = centerPage + d
            if i >= 0 && i < itemsCount { needed.insert(i) }
        }

        var assigned = Set<Int>()
        for p in pages where needed.contains(p.pageIndex) {
            assigned.insert(p.pageIndex)
        }

        let missing = needed.subtracting(assigned).sorted()
        var free = pages.filter { !needed.contains($0.pageIndex) }

        for idx in missing {
            guard !free.isEmpty else { break }
            let p = free.removeFirst()
            p.pageIndex = idx
            p.isHidden = false
            p.frame = CGRect(x: 0, y: CGFloat(idx) * h, width: w, height: h)
            bind(p, idx)
            if idx != settledPage {
                p.preload()
            }
        }

        for p in free {
            p.isHidden = true
            p.pageIndex = -1
            p.playerLayer.player = nil
        }

        for p in pages where p.pageIndex >= 0 {
            let f = CGRect(x: 0, y: CGFloat(p.pageIndex) * h, width: w, height: h)
            if p.frame != f { p.frame = f }
        }
    }

    private func bind(_ p: PageVideoView, _ idx: Int) {
        guard let pool, idx >= 0, idx < items.count else { return }
        let item = items[idx]
        let player = pool.player(for: item)
        p.bind(index: idx, item: item, player: player, ready: pool.isReady(item.vid))
    }

    // MARK: 滚动

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let h = bounds.height
        let raw = sv.contentOffset.y / h
        let nearest = max(0, min(Int(raw.rounded()), itemsCount - 1))
        if nearest != centerPage {
            centerPage = nearest
            // 先扩窗口，再重排（顺序不能反）
            pool?.keep(items, around: nearest)
            syncPages()
        }
    }

    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle(sv) }
    }

    func scrollViewDidEndDecelerating(_ sv: UIScrollView) {
        settle(sv)
    }

    func scrollViewDidEndScrollingAnimation(_ sv: UIScrollView) {
        settle(sv)
    }

    private func settle(_ sv: UIScrollView) {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let page = max(0, min(Int((sv.contentOffset.y / bounds.height).rounded()),
                             itemsCount - 1))
        centerPage = page

        if page != settledPage {
            settledPage = page
            pool?.keep(items, around: page)
            syncPages()
            if !pausedNow { pool?.focus(on: items, index: page) }
            onIndexChange?(page)
        }

        for p in pages where p.pageIndex == page {
            p.markReady()
            p.refreshState()
        }
    }

    // MARK: 播放结束

    private func handlePlaybackEnd(_ vid: String) {
        guard AppSettings.shared.autoplay, !pausedNow else { return }
        guard settledPage + 1 < itemsCount else { return }
        let next = settledPage + 1
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(next) * bounds.height),
                                    animated: true)
    }
}
