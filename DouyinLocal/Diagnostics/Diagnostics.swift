//
//  Diagnostics.swift
//  DouyinLocal
//
//  排障日志系统
//
//  设计原则：
//   1. 平时完全不记录（debugMode == false 时所有调用立刻返回，零开销）
//   2. 开启后记录带时间戳的关键事件，每条都带 vid，便于和服务端数据对照
//   3. 记录内容围绕「我远程定位问题需要什么」：
//      · 播放器状态机（prepare → ready → 首帧 → play 各时刻）
//      · 图层切换（静图撤除 / isReadyForDisplay 变化 / currentTime）
//      · 滑动（落位到第几条）
//      · 网络（URL / 耗时 / 状态码 / 错误）
//      · 缓存（命中 / 未命中）
//   4. 一键上传到电脑（POST /api2/log），断网时保留本地，下次可重发
//

import Foundation
import UIKit

/// 日志通道，便于筛选
enum LogChannel: String {
    case app      = "APP"      // 启动/生命周期
    case play     = "PLAY"     // 播放器状态机
    case layer    = "LAYER"    // 图层/静图切换
    case scroll   = "SCROLL"   // 滑动
    case net      = "NET"      // 网络
    case cache    = "CACHE"    // 缓存
    case ui       = "UI"       // 交互
    case error    = "ERROR"    // 错误
}

final class Diagnostics {
    static let shared = Diagnostics()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 20000          // 上限，防止吃内存
    private let fmt: DateFormatter
    private let startAt = Date()

    /// 排障模式：默认关闭，关闭时所有写日志的调用立刻返回
    private(set) var enabled = false

    private init() {
        fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        installCrashHandler()
    }

    // MARK: - 开关

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if on {
            lines.removeAll(keepingCapacity: true)
            lines.append("[\(fmt.string(from: Date()))] ===== 排障模式开启 =====")
        }
        lock.unlock()
    }

    // MARK: - 写入

    /// 核心写入口。关闭时立即返回，不产生任何开销。
    func log(_ channel: LogChannel, _ msg: @autoclosure () -> String) {
        guard enabled else { return }
        let ts = fmt.string(from: Date())
        let t = String(format: "%.1f", Date().timeIntervalSince(startAt))
        let line = "[\(ts) +\(t)s] \(channel.rawValue) \(msg())"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    /// 带 vid 的便捷方法（大多数播放相关问题都关心是哪条视频）
    func log(_ channel: LogChannel, vid: String, _ msg: @autoclosure () -> String) {
        guard enabled else { return }
        log(channel, "vid=\(vid) \(msg())")
    }

    // MARK: - 读取/导出

    func snapshot() -> String {
        lock.lock()
        let body = lines.joined(separator: "\n")
        lock.unlock()
        return header() + "\n" + body
    }

    func lineCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    func clear() {
        lock.lock(); lines.removeAll(keepingCapacity: true); lock.unlock()
    }

    private func header() -> String {
        let d = UIDevice.current
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return """
        ===== DouyinLocal 排障日志 =====
        build      : \(v) (\(b))
        device     : \(d.model) / \(d.systemName) \(d.systemVersion)
        screen     : \(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height)) @\(Int(UIScreen.main.scale))x
        server     : \(APIClient.baseURL.absoluteString)
        generated  : \(ISO8601DateFormatter().string(from: Date()))
        ================================
        """
    }

    // MARK: - 崩溃捕获

    private func installCrashHandler() {
        NSSetUncaughtExceptionHandler { ex in
            let text = """
            FATAL \(ex.name.rawValue)
            reason: \(ex.reason ?? "-")
            \(ex.callStackSymbols.joined(separator: "\n"))
            """
            // 崩溃时直接写文件，避免依赖内存缓冲
            Diagnostics.appendCrashFile(text)
        }
        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS] {
            signal(sig) { s in
                Diagnostics.appendCrashFile("FATAL signal \(s)\n" +
                                            Thread.callStackSymbols.joined(separator: "\n"))
                exit(s)
            }
        }
    }

    static func appendCrashFile(_ text: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("crash.log")
        let data = (text + "\n\n").data(using: .utf8) ?? Data()
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func crashLog() -> String {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return "" }
        let url = dir.appendingPathComponent("crash.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - 上传

    /// 一键上传到电脑。成功返回 true。断网时保留本地内容不丢。
    func upload() async -> Result<Int, Error> {
        let text = snapshot() + "\n\n----- crash -----\n" + Diagnostics.crashLog()
        guard let url = URL(string: APIClient.baseURL.absoluteString + "/api2/log") else {
            return .failure(APIError.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = text.data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                let bytes = data.count
                log(.app, "日志上传成功 \(bytes) 字节")
                return .success(text.count)
            }
            return .failure(APIError.http(code))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - 便捷函数

@inline(__always)
func dlog(_ ch: LogChannel, _ msg: @autoclosure () -> String) {
    Diagnostics.shared.log(ch, msg())
}

@inline(__always)
func dlog(_ ch: LogChannel, vid: String, _ msg: @autoclosure () -> String) {
    Diagnostics.shared.log(ch, vid: vid, msg())
}
