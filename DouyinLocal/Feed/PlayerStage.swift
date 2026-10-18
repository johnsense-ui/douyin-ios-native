//
//  PlayerStage.swift
//  DouyinLocal
//
//  原生分页滚动 + 每页一个视频画面。
//
//  关键点（这决定了「慢速上滑能看到下一条第一帧」）：
//   · 视频画面是 UIScrollView 的**子视图**，跟着手指 1:1 移动
//   · 三页（当前 ±1）各自持有一个 AVPlayerLayer，下一頁已停在第一帧
//   · 视频按原始比例显示（resizeAspect），不拉伸不裁切
//
//  手势：单击 / 双击挂在 scrollView 上，双击优先。
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - 单页视频视图

final class PageVideoView: UIView {
    let playerLayer = AVPlayerLayer()
    private let coverView = UIImageView()

    private(set) var pageIndex: Int = -1
    private(set) var vid: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        playerLayer.videoGravity = .resizeAspect      // 保持比例，完整显示
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)

        coverView.contentMode = .scaleAspectFit
        coverView.backgroundColor = .black
        coverView.clipsToBounds = true
        addSubview(coverView)
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
            loadCover(item.coverURL)
        } else if playerLayer.player !== player {
            playerLayer.player = player
        }
        coverView.alpha = ready ? 0 : 1
    }

    func markReady() {
        guard coverView.alpha != 0 else { return }
        UIView.animate(withDuration: 0.16) { self.coverView.alpha = 0 }
    }

    private func loadCover(_ url: URL?) {
        coverView.image = nil
        coverView.alpha = 1
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
                // 期间可能已经换成别的视频
                if self.vid == targetVid { self.coverView.image = img }
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
    /// 滚动进度：-1…1，用于让叠加 UI 跟随
    var onProgress: (CGFloat) -> Void = { _ in }

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
        } else if v.currentPage != index {
            v.scrollTo(index, animated: false)
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
        v.onProgress = { p in DispatchQueue.main.async { onProgress(p) } }
        v.pool = pool
    }
}

// MARK: - 滚动容器

final class StageView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private var pages: [PageVideoView] = (0..<3).map { _ in PageVideoView() }

    var pool: PlayerPool? {
        didSet {
            pool?.onReady = { [weak self] vid in
                self?.pages.first(where: { $0.vid == vid })?.markReady()
            }
        }
    }

    var items: [FeedItem] = []
    private(set) var itemsCount = 0
    private(set) var currentPage = 0

    var onIndexChange: ((Int) -> Void)?
    var onProgress: ((CGFloat) -> Void)?
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?

    private var lastProgress: CGFloat = 99
    private var pausedNow = false

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
        true
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
        currentPage = min(currentPage, max(itemsCount - 1, 0))
        // 全部重置，避免残留旧绑定
        for p in pages {
            p.pageIndex = -1
            p.isHidden = true
        }
        setNeedsLayout()
        layoutIfNeeded()
        scrollView.setContentOffset(CGPoint(x: 0,
                                            y: CGFloat(currentPage) * bounds.height),
                                    animated: false)
        syncPages()
        pool?.focus(on: items, index: currentPage)
    }

    func scrollTo(_ i: Int, animated: Bool) {
        guard i >= 0, i < max(itemsCount, 1), bounds.height > 0 else { return }
        currentPage = i
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(i) * bounds.height),
                                    animated: animated)
        syncPages()
    }

    func applyPaused(_ p: Bool) {
        guard p != pausedNow else { return }
        pausedNow = p
        if p {
            pool?.pause()
        } else if currentPage < items.count {
            pool?.resume(items[currentPage].vid)
        }
    }

    /// 让三页视图分别落在 current-1 / current / current+1
    private func syncPages() {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let h = bounds.height, w = bounds.width

        var needed = Set<Int>()
        for d in -1...1 {
            let i = currentPage + d
            if i >= 0 && i < itemsCount { needed.insert(i) }
        }

        // 已经在正确位置的保留
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
        }

        for p in free {
            p.isHidden = true
            p.pageIndex = -1
            p.playerLayer.player = nil
        }

        // 尺寸变化时矫正
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

        // 进度（-0.5…0.5），让叠加 UI 跟随
        let frac = raw - raw.rounded()
        if abs(frac - lastProgress) > 0.02 {
            lastProgress = frac
            onProgress?(frac)
        }

        let page = Int(raw.rounded())
        let clamped = max(0, min(page, itemsCount - 1))
        if clamped != currentPage {
            currentPage = clamped
            syncPages()
            if !pausedNow {
                pool?.focus(on: items, index: clamped)
            }
            onIndexChange?(clamped)
        }
    }

    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle(sv) }
    }

    func scrollViewDidEndDecelerating(_ sv: UIScrollView) {
        settle(sv)
    }

    private func settle(_ sv: UIScrollView) {
        guard bounds.height > 0, itemsCount > 0 else { return }
        let page = Int((sv.contentOffset.y / bounds.height).rounded())
        let clamped = max(0, min(page, itemsCount - 1))
        if clamped != currentPage {
            currentPage = clamped
            syncPages()
            onIndexChange?(clamped)
        }
        if let p = pages.first(where: { $0.pageIndex == clamped }) {
            if pool?.isReady(items[clamped].vid) == true { p.markReady() }
        }
        if !pausedNow {
            pool?.focus(on: items, index: clamped)
        }
        if abs(lastProgress) > 0.001 {
            lastProgress = 0
            onProgress?(0)
        }
    }
}
