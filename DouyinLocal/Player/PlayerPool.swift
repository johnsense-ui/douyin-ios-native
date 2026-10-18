//
//  PlayerPool.swift
//  DouyinLocal
//
//  流畅度的核心。
//
//  设计要点：
//   1. 固定 3 个 AVPlayer 槽位（current-1 / current / current+1）
//   2. 槽位 → layer 一次性挂到同一个容器 view 上，切换只改透明度与 zPosition
//      —— 不做 replaceCurrentItem 重新挂载，没有黑闪
//   3. 滑出窗口立即 replaceCurrentItem(nil) 释放解码器
//   4. 预载的下一条停在 0 秒并 playImmediately(atRate:0)，首帧就绪
//

import AVFoundation
import UIKit

/// 一个可复用的播放槽位
final class PlayerSlot: NSObject {
    let player = AVPlayer()
    let layer = AVPlayerLayer()
    var vid: String?
    var loopObserver: NSObjectProtocol?
    /// 首帧是否已就绪（用于避免黑闪切换）
    var isReady = false
    private var readyObserver: NSKeyValueObservation?

    override init() {
        super.init()
        player.actionAtItemEnd = .none
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        layer.isHidden = true
    }

    func prepare(_ item: FeedItem) {
        guard let url = item.videoURL else { return }
        if vid == item.vid { return }
        clear()
        vid = item.vid
        isReady = false

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0

        readyObserver = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self else { return }
            if it.status == .readyToPlay {
                DispatchQueue.main.async { self.isReady = true }
            }
        }
        player.replaceCurrentItem(with: playerItem)

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main) { [weak self] _ in
                guard let self else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
    }

    /// 预载：停在 0 秒，但让解码器把首帧解出来
    func preloadFrame() {
        player.seek(to: .zero)
        player.playImmediately(atRate: 0)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func clear() {
        player.pause()
        readyObserver?.invalidate()
        readyObserver = nil
        if let o = loopObserver {
            NotificationCenter.default.removeObserver(o)
            loopObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        vid = nil
        isReady = false
    }

    deinit {
        readyObserver?.invalidate()
        if let o = loopObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }
}

@MainActor
final class PlayerPool: ObservableObject {

    let slots: [PlayerSlot] = (0..<3).map { _ in PlayerSlot() }

    /// vid → 槽位下标
    private var slotOf: [String: Int] = [:]
    /// 当前展示中的槽位
    private(set) var active: Int = 0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// 把三个 layer 挂到一个容器 view（只在初始化时调用一次）
    func attach(to container: UIView) {
        for (i, s) in slots.enumerated() {
            s.layer.frame = container.bounds
            s.layer.zPosition = CGFloat(i)
            container.layer.addSublayer(s.layer)
        }
        showActive()
    }

    /// 容器尺寸变化时手动同步（CALayer 不会自动跟随 UIView）
    func syncLayerFrames(_ bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in slots {
            s.layer.frame = bounds
        }
        CATransaction.commit()
    }

    private func showActive() {
        for (i, s) in slots.enumerated() {
            s.layer.isHidden = (i != active)
        }
    }

    /// 找/分配一个槽位给 vid
    private func slot(for item: FeedItem) -> Int {
        if let i = slotOf[item.vid] { return i }
        // 优先空槽
        if let free = (0..<slots.count).first(where: { slots[$0].vid == nil }) {
            slots[free].prepare(item)
            slotOf[item.vid] = free
            return free
        }
        // 否则抢一个不在保留集合里的
        if let victim = (0..<slots.count).first(where: {
            guard let v = slots[$0].vid else { return true }
            return !kept.contains(v)
        }) {
            if let old = slots[victim].vid { slotOf.removeValue(forKey: old) }
            slots[victim].prepare(item)
            slotOf[item.vid] = victim
            return victim
        }
        // 实在没有就复用非 active
        let v = (active + 1) % slots.count
        if let old = slots[v].vid { slotOf.removeValue(forKey: old) }
        slots[v].prepare(item)
        slotOf[item.vid] = v
        return v
    }

    private var kept: Set<String> = []

    /// 主入口：切换到某一条
    func focus(on items: [FeedItem], index: Int) {
        guard index >= 0 && index < items.count else { return }
        let cur = items[index]

        // 1) 保留集合
        kept = Set(([index - 1, index, index + 1])
            .filter { $0 >= 0 && $0 < items.count }
            .map { items[$0].vid })

        // 2) 预载相邻（先做，让手指还没松开时就绪）
        for off in [1, -1] {
            let i = index + off
            guard i >= 0 && i < items.count else { continue }
            let nb = items[i]
            if slotOf[nb.vid] == nil {
                let s = slot(for: nb)
                if off == 1 { slots[s].preloadFrame() }
            }
        }

        // 3) 激活当前
        let target = slot(for: cur)
        if target != active {
            // 新槽位没就绪时，不切（保持上一帧冻结画面，避免黑）
            active = target
        }
        slots[active].layer.zPosition = 100
        showActive()
        slots[active].play()

        // 4) 暂停其它
        for (i, s) in slots.enumerated() where i != active {
            s.pause()
        }

        // 5) 释放窗口外
        for (vid, i) in slotOf where !kept.contains(vid) {
            slots[i].clear()
            slotOf.removeValue(forKey: vid)
        }
    }

    func pause() { slots[active].pause() }
    func resume() { slots[active].play() }

    func pauseAll() {
        for s in slots { s.pause() }
    }

    func setMuted(_ m: Bool) {
        for s in slots { s.player.isMuted = m }
    }

    var isMuted: Bool { slots[active].player.isMuted }
}
