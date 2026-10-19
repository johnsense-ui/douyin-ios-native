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
    /// 首次创建时的起始页（不依赖 @State 是否已生效）
    var startAt: Int? = nil
    var onTap: () -> Void = {}
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    var onLike: (String) -> Void = { _ in }
    var onSave: (String) -> Void = { _ in }
    var onAuthor: (String) -> Void = { _ in }
    var onSwipeLeft: (Int) -> Void = { _ in }
    var onSpeedMode: ((Bool) -> Void)?

    func makeUIView(context: Context) -> StageView {
        let v = StageView()
        bind(v)
        // 起始页优先用显式传入的 startAt，其次才用 index
        // （@State 在 init 里赋值后可能还没同步到首帧，不能只依赖它）
        v.configure(items: items, startAt: startAt ?? index)
        return v
    }

    func updateUIView(_ v: StageView, context: Context) {
        bind(v)
        v.applyPaused(paused)
        if v.itemsCount != items.count {
            v.configure(items: items, startAt: startAt ?? index)
        } else if v.currentIndex != index {
            // 用 currentPage 而不是 settledPage 判断，且只有在用户真的滑动过之后才跟随
            v.followExternalIndex(index)
        }
    }

    private func bind(_ v: StageView) {
        v.onSpeedMode = { on in
            DispatchQueue.main.async { onSpeedMode?(on) }
        }
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
    /// SwiftUI 明确指定的起始页（一旦设定，后续 configure 都以它为准直到被跳转）
    private var explicitStart: Int?
    /// configure 时 bounds 还没准备好，标记延迟重做
    private var needsReconfigure = false

    var onIndexChange: ((Int) -> Void)?
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onLike: ((String) -> Void)?
    var onSave: ((String) -> Void)?
    var onAuthor: ((String) -> Void)?
    var onSwipeLeft: ((Int) -> Void)?
    /// 倍速清屏开关
    var onSpeedMode: ((Bool) -> Void)?

    private var pausedNow = false
    private var adjustingRate = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        // 稍微放慢一点（.fast=0.99，.normal=0.998）
        scrollView.decelerationRate = UIScrollView.DecelerationRate(rawValue: 0.995)
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
            // 锁定：倍速期间禁止上下滑动切页
            scrollView.isScrollEnabled = false
            pool?.setRate(2.0, vid: vid)
            // 清屏：隐藏右栏/文案/进度条，底部显示倍速提示
            for p in pages where p.pageIndex == settledPage {
                p.setSpeedMode(true)
            }
            onSpeedMode?(true)
        case .ended, .cancelled, .failed:
            // 松手恢复滑动
            scrollView.isScrollEnabled = true
            if adjustingRate {
                adjustingRate = false
                pool?.setRate(1.0, vid: vid)
                for p in pages where p.pageIndex >= 0 {
                    p.setSpeedMode(false)
                }
                onSpeedMode?(false)
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

        // configure 时高度还是 0 的情况，这里补做一次
        if needsReconfigure, bounds.height > 0, itemsCount > 0 {
            needsReconfigure = false
            let target = explicitStart ?? settledPage
            settledPage = max(0, min(target, itemsCount - 1))
            centerPage = settledPage
            scrollView.setContentOffset(
                CGPoint(x: 0, y: CGFloat(settledPage) * bounds.height), animated: false)
            pool?.keep(items, around: settledPage)
            syncPages()
            pool?.focus(on: items, index: settledPage)
            activate(page: settledPage)
            prefetchAhead(from: settledPage)
            return
        }

        syncPages()
    }

    func configure(items: [FeedItem], startAt page: Int? = nil) {
        self.items = items
        itemsCount = items.count
        if let page {
            explicitStart = page
            settledPage = max(0, min(page, max(itemsCount - 1, 0)))
        } else if let e = explicitStart {
            // 再次 configure（比如列表条数变化）时保持原定起点
            settledPage = max(0, min(e, max(itemsCount - 1, 0)))
        } else {
            settledPage = min(settledPage, max(itemsCount - 1, 0))
        }
        centerPage = settledPage

        // 关键：此时 bounds 可能还是 0（尚未布局），偏移量设置会失效，
        // 标记一下，等 layoutSubviews 里再做一次
        if bounds.height <= 0 {
            needsReconfigure = true
            return
        }

        for p in pages {
            p.pageIndex = -1
            p.isHidden = true
            p.unbind()
        }
        setNeedsLayout()
        layoutIfNeeded()
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(settledPage) * bounds.height),
                                    animated: false)
        pool?.keep(items, around: settledPage)
        syncPages()
        pool?.focus(on: items, index: settledPage)
        // 绑定会把 isActivePage 重置为 false，这里必须显式激活，
        // 否则静图永不撤 → 黑屏但有声音
        activate(page: settledPage)
        prefetchAhead(from: settledPage)
    }

    /// 激活某一页，其余页取消激活
    func activate(page: Int) {
        for p in pages where p.pageIndex >= 0 {
            p.setActive(p.pageIndex == page)
            if p.pageIndex == page { p.refreshState() }
        }
    }

    /// 预取窗口：前 1 条 + 后 5 条
    ///  · 第一帧图片（服务端预生成，最快）
    ///  · 封面（最后兜底）
    ///  · 设备现场解帧（服务端还没生成时的补充）
    private func prefetchAhead(from page: Int) {
        guard !items.isEmpty else { return }
        let lo = max(0, page - 1)
        let hi = min(items.count - 1, page + 5)
        guard lo <= hi else { return }
        let slice = Array(items[lo...hi])

        let frameURLs = slice.compactMap { APIClient.frameURL($0.vid) }
        ImageCache.shared.prefetch(frameURLs)
        ImageCache.shared.prefetch(slice.compactMap { $0.coverURL })

        // 服务端还没有这张第一帧时，才让设备去解
        let missing = slice.filter { it in
            guard let u = APIClient.frameURL(it.vid) else { return false }
            return ImageCache.shared.get(u) == nil
        }
        if !missing.isEmpty {
            FramePrefetcher.shared.prefetch(Array(missing.prefix(2)))
        }

        // 预热下一条解码器（不播放，只建管线）——落位后 play 时几乎零延迟
        if page + 1 < items.count {
            let next = items[page + 1]
            pool?.prerollFirstFrame(next)
            // 先确保它有播放器，再预热
            _ = pool?.player(for: next)
            pool?.preroll(next)
        }

        // 把后面 3 条整段下载到本地缓存（循环/切条就不会再黑）
        if AppSettings.shared.videoCacheMB > 0 {
            let lo = min(items.count - 1, page + 1)
            let hi = min(items.count - 1, page + 3)
            if lo <= hi {
                VideoCache.shared.prefetch(Array(items[lo...hi]), limit: 3)
            }
        }
    }

    /// 当前滚动位置对应的页（不受 settledPage 影响）
    var currentIndex: Int {
        guard bounds.height > 0 else { return settledPage }
        return max(0, min(Int((scrollView.contentOffset.y / bounds.height).rounded()),
                          max(itemsCount - 1, 0)))
    }

    /// 外部 index 变化时跟随（例如 SwiftUI 重建后）
    func followExternalIndex(_ i: Int) {
        guard i >= 0, i < itemsCount else { return }
        guard i != settledPage, bounds.height > 0 else { return }
        jumpTo(i)
    }

    func jumpTo(_ i: Int) {
        guard i >= 0, i < max(itemsCount, 1), bounds.height > 0 else { return }
        settledPage = i
        centerPage = i
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(i) * bounds.height),
                                    animated: false)
        pool?.keep(items, around: i)
        syncPages()
        // 跳页后同样需要播放 + 激活，否则静图不撤（黑屏但有声音）
        if !pausedNow { pool?.focus(on: items, index: i) }
        activate(page: i)
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
            // 只有当前页需要激活；其它页保持暂停，避免反复 play 把画面打回队首
            if idx == settledPage {
                p.setActive(true)
            } else {
                // 邻页不播放：预热解码器 + 预滚首帧（方案B）
                // 预滚让图层里先有真实画面，切过来时静图淡出即可无缝衔接
                pool?.preroll(items[idx])
                pool?.prerollFirstFrame(items[idx])
            }
        }

        for p in free {
            p.isHidden = true
            p.pageIndex = -1
            p.unbind()
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
        // 兜底解锁：万一长按 cancelled 没触发，这里恢复滑动
        if !sv.isScrollEnabled && !adjustingRate {
            sv.isScrollEnabled = true
        }
        let page = max(0, min(Int((sv.contentOffset.y / bounds.height).rounded()),
                             itemsCount - 1))
        centerPage = page

        if page != settledPage {
            settledPage = page
            pool?.keep(items, around: page)
            syncPages()
            // 只在完全落位后播放一次
            if !pausedNow { pool?.focus(on: items, index: page) }
            onIndexChange?(page)
        }

        // 落位后必须激活当前页（同 configure 的原因），setActive 内部已幂等
        activate(page: page)
        prefetchAhead(from: page)
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
