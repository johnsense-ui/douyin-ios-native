//
//  CachedAsyncImage.swift
//  DouyinLocal
//
//  带内存缓存的异步图片。
//  九宫格里会重复出现同一张封面，系统 AsyncImage 每次都会重新请求，很卡。
//

import SwiftUI
import UIKit

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 240
        cache.totalCostLimit = 120 * 1024 * 1024   // 120 MB
    }

    func get(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 正在下载的 url（避免同一张图重复请求）
    private var inflight = Set<String>()
    private let inflightLock = NSLock()

    /// 预取一批图片（后台下载并缓存，不保证顺序；同一 url 只请求一次）
    func prefetch(_ urls: [URL]) {
        for url in urls {
            if cache.object(forKey: url as NSURL) != nil { continue }

            let key = url.absoluteString
            inflightLock.lock()
            if inflight.contains(key) {
                inflightLock.unlock()
                continue
            }
            inflight.insert(key)
            inflightLock.unlock()

            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self else { return }
                defer {
                    self.inflightLock.lock()
                    self.inflight.remove(key)
                    self.inflightLock.unlock()
                }
                guard let data, let img = UIImage(data: data) else { return }
                self.set(url, img)
            }.resume()
        }
    }

    func set(_ url: URL, _ img: UIImage) {
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: url as NSURL, cost: cost)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .douyinImageCached,
                                            object: url.absoluteString)
        }
    }
}

struct CachedAsyncImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
            } else {
                Rectangle()
                    .fill(Color(white: 0.12))
                    .task(id: url) { await load() }
            }
        }
        .onAppear {
            if image == nil, let c = ImageCache.shared.get(url) {
                image = c
            }
        }
    }

    private func load() async {
        if let c = ImageCache.shared.get(url) {
            await MainActor.run { image = c }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { return }
            ImageCache.shared.set(url, img)
            await MainActor.run { if self.url == url { image = img } }
        } catch {
            // 静默失败，显示灰底
        }
    }
}

extension Notification.Name {
    /// object 是 url.absoluteString
    static let douyinImageCached = Notification.Name("douyin.image.cached")
}