//
//  Similar.swift
//  DouyinLocal
//
//  找相似：数据模型 + 网络层
//
//  后端：index_service/serve_similar.py（独立服务，默认 8800）
//  算法：Chinese-CLIP 视觉向量 + 余弦相似度，按视频聚合去重
//

import Foundation

// MARK: - 结果条目

struct SimilarItem: Decodable, Identifiable, Hashable {
    let vid: String
    let score: Double
    let t: Double            // 该视频里匹配上的时间点（秒）
    let nHits: Int
    let author: String
    let authorId: String
    let caption: String
    let digg: Int
    let createTime: Int
    let source: String

    var id: String { vid }

    enum CodingKeys: String, CodingKey {
        case vid, score, t, nHits = "n_hits", author, authorId
        case caption, digg, createTime, source
    }

    /// 分数分级：绿 ≥0.90 / 黄 0.85-0.90 / 灰 <0.85
    var tier: Int {
        if score >= 0.90 { return 2 }
        if score >= 0.85 { return 1 }
        return 0
    }

    var scoreText: String { String(format: "%.3f", score) }
}

struct SimilarFilterStats: Decodable {
    let sameVideo: Int?
    let sameAuthor: Int?
    let digg: Int?
    let source: Int?
    let blocked: Int?
    let time: Int?
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case sameVideo = "same_video", sameAuthor = "same_author"
        case digg, source, blocked, time, score
    }
}

struct SimilarResult: Decodable {
    let ok: Bool?
    let results: [SimilarItem]
    let stats: SimilarFilterStats?
    let candidates: Int?
    let scanned: Int?
    let error: String?
}

// MARK: - 查询参数

struct SimilarQuery {
    var vid: String
    var t: Double = 3.0
    var top: Int = 30
    /// 排除同一作者（默认开）
    var excludeSameAuthor: Bool = true
    /// 同一作者最多保留几条（0 = 不限；配合 excludeSameAuthor=false 使用）
    var sameAuthorLimit: Int = 2
    var minDigg: Int = 0
    var source: String? = nil          // guanzhu / shoucang / both
    var minScore: Double = 0.0
    /// 排序：score / hits / digg / new
    var sort: String = "score"

    func queryItems() -> [URLQueryItem] {
        var q: [URLQueryItem] = [
            .init(name: "vid", value: vid),
            .init(name: "t", value: String(format: "%.2f", t)),
            .init(name: "top", value: "\(min(max(top, 1), 100))"),
            .init(name: "ex_author", value: excludeSameAuthor ? "1" : "0"),
            .init(name: "min_digg", value: "\(minDigg)"),
            .init(name: "min_score", value: String(format: "%.3f", minScore)),
        ]
        if let source, !source.isEmpty {
            q.append(.init(name: "source", value: source))
        }
        return q
    }
}

// MARK: - 客户端

enum SimilarAPI {
    /// 默认地址：走 Tailscale 8447（和主服务同一个域名，只换端口）
    static let defaultBase = "https://locvid-pc.tail83739b.ts.net:8447"

    /// 找相似服务的基地址，可在设置里修改
    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "similar.base"),
           let u = URL(string: s), !s.isEmpty {
            return u
        }
        return URL(string: defaultBase)!
    }

    /// 保存地址（空字符串 = 恢复默认）
    static func setBase(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            UserDefaults.standard.removeObject(forKey: "similar.base")
        } else {
            UserDefaults.standard.set(t, forKey: "similar.base")
        }
    }

    static var currentBaseText: String {
        UserDefaults.standard.string(forKey: "similar.base") ?? defaultBase
    }

    static func search(_ q: SimilarQuery) async throws -> SimilarResult {
        var c = URLComponents(url: baseURL.appendingPathComponent("api2/similar"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = q.queryItems()
        guard let url = c.url else { throw APIError.badURL }

        let t0 = Date()
        dlog(.net, "找相似 vid=\(q.vid) t=\(q.t)")
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        if http.statusCode != 200 {
            dlog(.net, "找相似 HTTP \(http.statusCode) \(ms)ms")
            throw APIError.http(http.statusCode)
        }
        let r = try JSONDecoder().decode(SimilarResult.self, from: data)
        dlog(.net, "找相似 OK \(ms)ms 结果 \(r.results.count) 条")
        return r
    }

    struct Status {
        var reachable: Bool = false
        var ready: Bool = false
        var loadSeconds: Double = 0
        var error: String = ""
    }

    static func checkStatus() async -> Status {
        var st = Status()
        guard let u = URL(string: baseURL.absoluteString + "/api2/similar/status") else {
            return st
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return st
        }
        st.reachable = true
        st.ready = (d["ready"] as? Bool) ?? false
        st.loadSeconds = (d["loadSeconds"] as? Double) ?? 0
        st.error = (d["error"] as? String) ?? ""
        return st
    }

    static func status() async -> Bool {
        await checkStatus().ready
    }
}
