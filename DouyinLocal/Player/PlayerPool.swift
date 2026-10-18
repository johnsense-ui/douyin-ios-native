//
//  PlayerPool.swift
//  DouyinLocal
//
//  3 个 AVPlayer 的池子（当前 ±1）。
//
//  设计：
//   · 槽位只持有 AVPlayer，不再持有 layer
//     画面交给 PageVideoView 里的 AVPlayerLayer，这样视频能跟着 UIScrollView 一起滚动，
//     拖动时就能看到下一条的第一帧。
//   · 默认有声，不做静音。
//   · 滑出窗口立即 replaceCurrentItem(nil) 释放解码器。
//

import AVFoundation
import Combine
import UIKit

/// 一个播放槽
final class PlayerSlot: NSObject {
    let player = AVQueuePlayer()
    private(set) var vid: String?
    private(set) var ready = false

    /// 首帧就绪回调（在主线程）
    var onReady: ((String) -> Void)?
    /// 播放结束回调（未开启循环时）
    var onEnd: ((String) -> Void)?
    /// 是否单条循环
    var loopEnabled = true

    private var statusObs: NSKeyValueObservation?
    private var looper: AVPlayerLooper?
    private var loopEndObs: NSObjectProtocol?

    override init() {
        super.init()
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = false          // 默认有声
    }

    func prepare(_ item: FeedItem) {
        guard let remote = item.videoURL else { return }
        if vid == item.vid { return }
        clear()
        vid = item.vid

        // 有本地缓存就播本地（seek/循环都不会黑），否则先播网络流
        let url = VideoCache.shared.localURL(item.vid) ?? remote
        if url.isFileURL { VideoCache.shared.pin(item.vid) }

        let pi = AVPlayerItem(url: url)
        pi.preferredForwardBufferDuration = 2.0

        statusObs = pi.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            guard let self else { return }
            let ok = (it.status == .readyToPlay)
            DispatchQueue.main.async {
                guard self.ready != ok else { return }
                self.ready = ok
                if ok, let v = self.vid { self.onReady?(v) }
            }
        }

        player.removeAllItems()
        // AVPlayerLooper 内部维护队列，循环不需要 seek，真正无缝
        looper = AVPlayerLooper(player: player, templateItem: pi)

        if !loopEnabled {
            looper?.disableLooping()
            loopEndObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: pi, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.player.pause()
                    if let v = self.vid { self.onEnd?(v) }
                }
        }
    }

    /// 预载：让解码器把首帧解出来。
    /// 注意：AVPlayerLooper 下不能 seek，也不要在已就绪时反复调用，
    /// 否则会让视频轨重置回队首（表现为画面跳回第一帧）。
    func preloadFrame() {
        guard player.rate <= 0 else { return }
        guard !ready else { return }
        player.playImmediately(atRate: 0)
    }

    /// 幂等播放：已经在播就不重复调用。
    /// AVQueuePlayer + AVPlayerLooper 下重复 playImmediately 会把视频轨切回队首，
    /// 表现为「画面跳回第一帧、声音继续」。
    func play() {
        if player.rate > 0 { return }
        player.playImmediately(atRate: 1.0)
    }
    func pause() { player.pause() }

    func clear() {
        player.pause()
        statusObs?.invalidate()
        statusObs = nil
        if let o = loopEndObs {
            NotificationCenter.default.removeObserver(o)
            loopEndObs = nil
        }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        vid = nil
        ready = false
    }

    deinit {
        statusObs?.invalidate()
        if let o = loopEndObs { NotificationCenter.default.removeObserver(o) }
        looper?.disableLooping()
    }
}

@MainActor
final class PlayerPool: ObservableObject {

    let slots: [PlayerSlot] = (0..<3).map { _ in PlayerSlot() }

    /// vid → 槽位下标
    private var slotOf: [String: Int] = [:]
    /// 当前窗口内要保留的 vid
    private var kept: Set<String> = []
    /// 正在播放的 vid —— 任何情况下都不允许被抢占
    private var playingVid: String?

    /// 任意槽位首帧就绪时回调
    var onReady: ((String) -> Void)?
    /// 任意槽位播放结束时回调（未开启循环时）
    var onEnd: ((String) -> Void)?

    init() {
        for s in slots {
            s.onReady = { [weak self] vid in
                self?.onReady?(vid)
            }
            s.onEnd = { [weak self] vid in
                self?.onEnd?(vid)
            }
        }
        // 静音开关拨到静音也要出声
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func applyLoopSetting() {
        let loop = AppSettings.shared.loopOne
        for s in slots { s.loopEnabled = loop }
    }

    // MARK: - 槽位分配

    private func assign(_ item: FeedItem) -> Int {
        if let i = slotOf[item.vid] { return i }
        // 空槽优先
        if let free = (0..<slots.count).first(where: { slots[$0].vid == nil }) {
            slots[free].prepare(item)
            slotOf[item.vid] = free
            return free
        }
        // 抢一个「既不在保留窗口、也不是正在播放」的槽
        if let victim = (0..<slots.count).first(where: { s in
            guard let v = slots[s].vid else { return true }
            if v == playingVid { return false }     // 正在播的绝不动
            return !kept.contains(v)
        }) {
            if let old = slots[victim].vid { slotOf.removeValue(forKey: old) }
            slots[victim].prepare(item)
            slotOf[item.vid] = victim
            return victim
        }
        // 还是找不到：扩大范围，挑一个不是当前播放的
        if let victim = (0..<slots.count).first(where: { slots[$0].vid != playingVid }) {
            if let old = slots[victim].vid { slotOf.removeValue(forKey: old) }
            slots[victim].prepare(item)
            slotOf[item.vid] = victim
            return victim
        }
        // 极端兜底（只有一个槽且正在播）
        if let old = slots[0].vid { slotOf.removeValue(forKey: old) }
        slots[0].prepare(item)
        slotOf[item.vid] = 0
        return 0
    }

    /// 取某条视频的播放器（必要时准备）
    func player(for item: FeedItem) -> AVPlayer {
        slots[assign(item)].player
    }

    func isReady(_ vid: String) -> Bool {
        guard let i = slotOf[vid] else { return false }
        return slots[i].ready
    }

    /// 预载某条视频并停在第一帧（拖动时就能看到画面）
    func preloadFrame(_ item: FeedItem) {
        let i = assign(item)
        slots[i].preloadFrame()
    }

    /// 长按倍速
    func setRate(_ rate: Float, vid: String) {
        if let i = slotOf[vid] {
            slots[i].player.rate = rate
        }
    }

    // MARK: - 主入口

    /// 只更新「保留窗口」，不改变播放状态（拖动过程中用）
    func keep(_ items: [FeedItem], around index: Int) {
        guard !items.isEmpty, index >= 0, index < items.count else { return }
        let lo = max(0, index - 1)
        let hi = min(items.count - 1, index + 1)
        kept = Set(items[lo...hi].map { $0.vid })
    }

    func focus(on items: [FeedItem], index: Int) {
        guard !items.isEmpty, index >= 0, index < items.count else { return }
        applyLoopSetting()
        let lo = max(0, index - 1)
        let hi = min(items.count - 1, index + 1)
        kept = Set(items[lo...hi].map { $0.vid })

        // 确保窗口内都有播放器
        for i in lo...hi { _ = assign(items[i]) }

        // 当前条播放，其它暂停
        let curVid = items[index].vid
        playingVid = curVid
        let cur = slots[assign(items[index])]
        cur.play()
        for s in slots where s.vid != nil && s.vid != curVid {
            s.pause()
        }

        // 预载下一条的第一帧（拖动时能看到画面）
        if index + 1 < items.count {
            let n = assign(items[index + 1])
            slots[n].preloadFrame()
        }

        // 释放窗口外
        for (vid, i) in slotOf where !kept.contains(vid) {
            slots[i].clear()
            slotOf.removeValue(forKey: vid)
        }
    }

    func pause() { for s in slots { s.pause() } }

    func resume(_ vid: String) {
        if let i = slotOf[vid] { slots[i].play() }
    }

    func pauseAll() { for s in slots { s.pause() } }
}
