//
//  PlayerStage.swift
//  DouyinLocal
//
//  原生分页滚动 + 每页一个视频画面。
//
//  对齐抖音的行为：
//   · 手指拖动时，整页（视频画面）跟着 1:1 移动
//   · 拖动过程中**旧视频继续播放**，新视频停在第一帧（不播）
//   · 落位（吸附完成）之后才切换播放：新视频开始播，旧视频暂停
//   · 视频按原始比例完整显示（resizeAspect），不裁切不拉伸
//   · 每页盖一层封面，等 AVPlayerLayer.isReadyForDisplay 变 true 才揭开
//     —— 解决「有声音没画面」的黑屏
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - 单页视频视图

final class PageVideoView: UIView {
    let playerLayer = AVPlayerLayer()
    private let coverView = UIImageView()
    private var displayObs: NSKeyValueObservation?

    var pageIndex: Int = -1
    private(set) var vid: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)

        coverView.contentMode = .scaleAspectFit
        coverView.backgroundColor = .clear
        coverView.clipsToBounds = true
        addSubview(coverView)

        // 画面真正可显示时才揭开封面（这是防黑屏的关键）
        displayObs = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] l, _ in
            guard l.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.revealVideo() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        coverView.frame = bounds
        CATransaction.commit()
    }

    func bind(index: Int, item: FeedItem, player: AVPlayer, ready: Bool) {
        pageIndex = index
        if vid != item.vid {
            vid = item.vid
            playerLayer.player = player
            coverView.alpha = 1
            loadCover(item.coverURL)
        } else if playerLayer.player !== player {
            playerLayer.player = player
        }
        if playerLayer.isReadyForDisplay {
            coverView.alpha = 0
        } else if !ready {
            coverView.alpha = 1
        }
    }

    func markReady() { revealVideo() }

    private func revealVideo() {
        guard coverView.alpha != 0 else { return }
        UIView.animate(withDuration: 0.12) { self.coverView.alpha = 0 }
    }

    private func loadCover(_ url: URL?) {
        coverView.image = nil
        guard let url else { return }
        if let cached = ImageCache.shared.get(url) {
            coverView.image = cached
            return
        }
        let targetVid = vid
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            ImageCache.shared.set(url, img)
            DispatchQueue.main.async {
                if self.vid == targetVid, self.coverView.alpha > 0 {
                    self.coverView.image = img
                }
            }
        }.resume()
    }
}

// MARK: - SwiftUI 包装

struct PlayerStage: UIViewRepresentable {
    let items: [FeedItem]
    let pool: PlayerPool
    @Binding var index: Int
    let paused: Bool
    var onTap: () -> Void = {}
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    /// 拖动偏移（单位：页），0 表示已归位
    var onDelta: (CGFloat) -> Void = { _ in }

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
        v.onDelta = { d in DispatchQueue.main.async { onDelta(d) } }
        v.pool = pool
    }
}

// MARK: - 滚动容器

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
    /// 正在播放的页（只在吸附完成后更新）
    private(set) var settledPage = 0
    /// 当前离屏幕中心最近的一页（拖动中会变，用于分配三页）
    private var centerPage = 0

    var onIndexChange: ((Int) -> Void)?
    var onDelta: ((CGFloat) -> Void)?
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?

    private var lastDelta: CGFloat = 99
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
            scrollView.addSubview(p)
        }

        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingle))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDouble(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
        long.minimumPressDuration = 0.28

        for g in [single, double, long] as [UIGestureRecognizer] {
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

    // MARK: 布局 / 配置

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
        syncPages()
        pool?.keep(items, around: settledPage)
        pool?.focus(on: items, index: settledPage)
    }

    /// 外部要求跳到某一页（不做动画）
    func jumpTo(_ i: Int) {
        guard i >= 0, i < max(itemsCount, 1), bounds.height > 0 else { return }
        settledPage = i
        centerPage = i
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(i) * bounds.height),
                                    animated: false)
        syncPages()
        pool?.keep(items, around: i)
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

    // MARK: 页面分配

    /// 让三页视图覆盖 center-1 / center / center+1
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
            let isNew = (p.pageIndex != idx)
            p.pageIndex = idx
            p.isHidden = false
            p.frame = CGRect(x: 0, y: CGFloat(idx) * h, width: w, height: h)
            bind(p, idx)

            // 不是正在播的那页 → 预载第一帧，拖动时就能看到画面
            if idx != settledPage, isNew {
                pool?.preloadFrame(items[idx])
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

        // 拖动偏移，驱动叠加 UI 跟随
        let delta = raw - CGFloat(settledPage)
        if abs(delta - lastDelta) > 0.006 {
            lastDelta = delta
            onDelta?(delta)
        }

        let nearest = max(0, min(Int(raw.rounded()), itemsCount - 1))
        if nearest != centerPage {
            centerPage = nearest
            syncPages()
            pool?.keep(items, around: nearest)
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
            syncPages()
            pool?.keep(items, around: page)
            if !pausedNow { pool?.focus(on: items, index: page) }
            onIndexChange?(page)
        }

        if let p = pages.first(where: { $0.pageIndex == page }) {
            p.markReady()
        }
        if lastDelta != 0 {
            lastDelta = 0
            onDelta?(0)
        }
    }

    // MARK: 播放结束

    private func handlePlaybackEnd(_ vid: String) {
        guard AppSettings.shared.autoplay else { return }
        guard !pausedNow else { return }
        guard settledPage + 1 < itemsCount else { return }
        let next = settledPage + 1
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(next) * bounds.height),
                                    animated: true)
    }
}
