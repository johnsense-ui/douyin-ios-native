//
//  VideoCache.swift
//  DouyinLocal
//
//  视频本地缓存（有容量上限，LRU 淘汰）。
//
//  为什么必须做：
//   · 网络流播放时，循环回到 0 秒要重新去服务器拉文件头，那几百毫秒图层是空的 → 黑一下
//   · 本地文件 seek 是磁盘操作，毫秒级，循环/切条都不会黑
//
//  策略：
//   · 只缓存「即将要看」的几条（默认后 2 条）
//   · 总量超上限时，按最后访问时间淘汰最旧的
//   · 正在被播放器占用的文件不淘汰
//

import Foundation

final class VideoCache {
    static let shared = VideoCache()

    private let fm = FileManager.default
    private let dir: URL
    private let queue = DispatchQueue(label: "douyin.videocache",
                                      qos: .utility, attributes: .concurrent)
    private var downloading = Set<String>()
    private let lock = NSLock()
    /// 正在播放、不能删的文件
    private var pinned = Set<String>()

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = caches.appendingPathComponent("videos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var maxBytes: Int {
        max(50, AppSettings.shared.videoCacheMB) * 1024 * 1024
    }

    private func fileURL(_ vid: String) -> URL {
        dir.appendingPathComponent(vid + ".mp4")
    }

    /// 已缓存则返回本地文件地址
    func localURL(_ vid: String) -> URL? {
        let u = fileURL(vid)
        guard fm.fileExists(atPath: u.path) else { return nil }
        // 更新访问时间（LRU 用）
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return u
    }

    func isCached(_ vid: String) -> Bool {
        fm.fileExists(atPath: fileURL(vid).path)
    }

    /// 播放时把某条钉住，避免被淘汰
    func pin(_ vid: String) {
        lock.lock(); pinned.insert(vid); lock.unlock()
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.lock.lock(); self?.pinned.remove(vid); self?.lock.unlock()
        }
    }

    // MARK: - 预取

    /// 预取若干条（只下载还没缓存的）
    func prefetch(_ items: [FeedItem], limit: Int = 2) {
        var started = 0
        for it in items {
            if started >= limit { break }
            guard let remote = it.videoURL else { continue }
            if isCached(it.vid) { continue }

            lock.lock()
            if downloading.contains(it.vid) {
                lock.unlock()
                continue
            }
            downloading.insert(it.vid)
            lock.unlock()

            started += 1
            let vid = it.vid
            queue.async { [weak self] in
                self?.download(vid: vid, from: remote)
            }
        }
    }

    private func download(vid: String, from remote: URL) {
        defer {
            lock.lock(); downloading.remove(vid); lock.unlock()
        }
        // 已经超上限就不下了
        if usedBytes() > maxBytes { return }

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: remote) { [weak self] data, _, _ in
            defer { sem.signal() }
            guard let self, let data, !data.isEmpty else { return }
            let tmp = self.dir.appendingPathComponent(vid + ".part")
            do {
                try data.write(to: tmp)
                let dst = self.fileURL(vid)
                if self.fm.fileExists(atPath: dst.path) {
                    try? self.fm.removeItem(at: dst)
                }
                try self.fm.moveItem(at: tmp, to: dst)
                ok = true
            } catch {
                try? self.fm.removeItem(at: tmp)
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 60)

        if ok {
            evictIfNeeded()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .douyinVideoCached,
                                                object: vid)
            }
        }
    }

    // MARK: - 容量

    func usedBytes() -> Int {
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for f in files {
            if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += sz
            }
        }
        return total
    }

    func clearAll() {
        lock.lock()
        downloading.removeAll()
        lock.unlock()
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    /// 超上限时按访问时间从旧到新删
    private func evictIfNeeded() {
        lock.lock()
        let keep = pinned
        lock.unlock()

        func snapshot() -> [(URL, Int, Date)] {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return [] }
            return files.compactMap { f in
                guard let v = try? f.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let sz = v.fileSize else { return nil }
                return (f, sz, v.contentModificationDate ?? .distantPast)
            }
        }

        var items = snapshot()
        var total = items.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }

        items.sort { $0.2 < $1.2 }        // 最旧的先删
        for (url, size, _) in items {
            if total <= maxBytes { break }
            let vid = url.deletingPathExtension().lastPathComponent
            if keep.contains(vid) { continue }
            // 不删正在下载的
            lock.lock()
            let busy = downloading.contains(vid)
            lock.unlock()
            if busy { continue }

            try? fm.removeItem(at: url)
            total -= size
        }
    }
}

extension Notification.Name {
    /// object 是 vid
    static let douyinVideoCached = Notification.Name("douyin.video.cached")
}
