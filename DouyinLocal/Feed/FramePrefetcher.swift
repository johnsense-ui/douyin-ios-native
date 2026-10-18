//
//  FramePrefetcher.swift
//  DouyinLocal
//
//  负责提前把「视频的第 0 帧」解码成图片并缓存。
//
//  为什么不用封面图：
//   · 很多视频的第一帧和封面不是同一张画面，用户要的是真实第一帧
//
//  为什么用 AVAssetImageGenerator：
//   · 它走的是图片解码路径，比 AVPlayer 起播快得多，且不占用播放器槽位
//   · 拖动时下一条已经有真画面，不会黑
//

import UIKit
import AVFoundation

extension Notification.Name {
    /// object 是 vid（String）
    static let douyinFrameReady = Notification.Name("douyin.frame.ready")
}

final class FramePrefetcher {
    static let shared = FramePrefetcher()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "douyin.frame.prefetch",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    private var inFlight = Set<String>()
    private let lock = NSLock()

    private init() {
        cache.countLimit = 48
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    private func key(_ vid: String) -> NSString { ("frame:" + vid) as NSString }

    /// 同步取已缓存的帧（没有就返回 nil）
    func cached(_ vid: String) -> UIImage? {
        cache.object(forKey: key(vid))
    }

    /// 预取若干条的首帧
    func prefetch(_ items: [FeedItem]) {
        for it in items {
            guard let url = it.videoURL else { continue }
            if cache.object(forKey: key(it.vid)) != nil { continue }

            lock.lock()
            if inFlight.contains(it.vid) {
                lock.unlock()
                continue
            }
            inFlight.insert(it.vid)
            lock.unlock()

            let vid = it.vid
            queue.async { [weak self] in
                self?.generate(vid: vid, url: url)
            }
        }
    }

    private func generate(vid: String, url: URL) {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 720, height: 1280)

        let t = CMTime(seconds: 0.05, preferredTimescale: 600)
        let sem = DispatchSemaphore(value: 0)
        var image: UIImage?

        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, cg, _, result, _ in
            if result == .succeeded, let cg {
                image = UIImage(cgImage: cg)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)

        defer {
            lock.lock()
            inFlight.remove(vid)
            lock.unlock()
        }

        guard let image else { return }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key(vid), cost: cost)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .douyinFrameReady, object: vid)
        }
    }
}
