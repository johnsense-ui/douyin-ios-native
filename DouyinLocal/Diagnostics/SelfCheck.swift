//
//  SelfCheck.swift
//  DouyinLocal
//
//  上机前自检：一键跑一遍关键路径，输出可复制的报告
//
//  设计目的：以后你说「有点卡」，点一下体检，
//  报告会告诉我具体哪条视频、慢在哪一步、多少毫秒。
//

import Foundation
import AVFoundation

struct CheckResult: Identifiable {
    let id = UUID()
    let name: String
    let ok: Bool
    let detail: String
    let ms: Int?
}

final class SelfCheck {
    static let shared = SelfCheck()

    private(set) var results: [CheckResult] = []
    private(set) var running = false

    private func add(_ name: String, ok: Bool, _ detail: String, ms: Int? = nil) {
        let r = CheckResult(name: name, ok: ok, detail: detail, ms: ms)
        results.append(r)
        dlog(.app, "自检 \(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    func run() async {
        if running { return }
        running = true
        results.removeAll()
        defer { running = false }

        // 1) 服务端连通
        var t0 = Date()
        do {
            let st = try await APIClient.shared.stats()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            add("服务端连通", ok: true, "\(st.videos) 条视频", ms: ms)
        } catch {
            add("服务端连通", ok: false, "失败：\(error.localizedDescription)")
            return
        }

        // 2) 推荐流
        t0 = Date()
        guard let feed = try? await APIClient.shared.feed(offset: 0, limit: 8),
              !feed.items.isEmpty else {
            add("推荐流", ok: false, "拉取失败或为空")
            return
        }
        let ms2 = Int(Date().timeIntervalSince(t0) * 1000)
        add("推荐流", ok: true, "\(feed.items.count) 条", ms: ms2)

        // 3) 首帧图片覆盖（抽查前 8 条）
        var missing = 0
        for it in feed.items {
            guard let u = APIClient.frameURL(it.vid) else { missing += 1; continue }
            var req = URLRequest(url: u)
            req.httpMethod = "HEAD"
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let h = resp as? HTTPURLResponse, h.statusCode == 200 {
                continue
            }
            missing += 1
        }
        add("首帧图片", ok: missing == 0,
            missing == 0 ? "抽查 8 条全部命中" : "缺失 \(missing)/8")

        // 4) 视频文件可达（抽查 3 条）
        var bad = 0
        for it in feed.items.prefix(3) {
            guard let u = it.videoURL else { bad += 1; continue }
            var req = URLRequest(url: u)
            req.httpMethod = "HEAD"
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let h = resp as? HTTPURLResponse,
               (200..<300).contains(h.statusCode) {
                continue
            }
            bad += 1
        }
        add("视频文件", ok: bad == 0,
            bad == 0 ? "抽查 3 条可达" : "异常 \(bad)/3")

        // 5) 播放器就绪耗时（抽查 2 条）
        var times: [Int] = []
        for it in feed.items.prefix(2) {
            guard let u = it.videoURL else { continue }
            let item = AVPlayerItem(url: u)
            let player = AVPlayer(playerItem: item)
            let t = Date()
            var waited = 0
            while item.status != .readyToPlay && waited < 60 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 50
            }
            if item.status == .readyToPlay {
                times.append(Int(Date().timeIntervalSince(t) * 1000))
            }
            player.pause()
        }
        if times.isEmpty {
            add("播放器就绪", ok: false, "2 条都没能在 6 秒内就绪")
        } else {
            let avg = times.reduce(0, +) / times.count
            add("播放器就绪", ok: avg < 3000, "平均 \(avg)ms", ms: avg)
        }

        // 6) 本地缓存
        let used = VideoCache.shared.usedBytes()
        add("本地缓存", ok: true,
            "已用 \(Int(Double(used) / 1024 / 1024)) MB / 上限 \(AppSettings.shared.videoCacheMB) MB")

        // 7) 日志
        add("排障日志", ok: true,
            Diagnostics.shared.enabled
            ? "已开启，\(Diagnostics.shared.lineCount()) 行"
            : "未开启（需要定位问题时再开）")
    }

    /// 生成可复制的报告
    func report() -> String {
        var out = "===== 自检报告 =====\n"
        out += ISO8601DateFormatter().string(from: Date()) + "\n\n"
        let pass = results.filter { $0.ok }.count
        out += "通过 \(pass)/\(results.count)\n"
        out += "--------------------------------\n"
        for r in results {
            let ms = r.ms.map { " (\($0)ms)" } ?? ""
            out += "\(r.ok ? "✓" : "✗") \(r.name)  \(r.detail)\(ms)\n"
        }
        return out
    }
}
