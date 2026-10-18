//
//  APIClient.swift
//  DouyinLocal
//
//  服务端：index_service（127.0.0.1:8792）
//  手机访问：Tailscale Serve → https://locvid-pc.tail83739b.ts.net:8446
//

import Foundation

final class APIClient {
    static let shared = APIClient()

    /// 手机端唯一入口。首次启动可从 UserDefaults 读取用户填写的地址。
    static var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "serverBase"), let u = URL(string: s) {
            return u
        }
        return URL(string: "https://locvid-pc.tail83739b.ts.net:8446")!
    }

    static func setBaseURL(_ s: String) {
        UserDefaults.standard.set(s, forKey: "serverBase")
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    private let decoder = JSONDecoder()

    // MARK: - 核心请求

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var c = URLComponents(url: Self.baseURL.appendingPathComponent(path),
                              resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = c.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decode(error.localizedDescription)
        }
    }

    // MARK: - 接口

    /// 推荐流。seed 为空时服务端生成并返回，后续翻页带上同一个 seed。
    func feed(seed: String? = nil, offset: Int, limit: Int = 12,
              tab: String = "recommend", algo: String = "mixed") async throws -> FeedPage {
        var q = ["offset": "\(offset)", "limit": "\(limit)", "tab": tab, "algo": algo]
        if let seed, !seed.isEmpty { q["seed"] = seed }
        return try await get("api2/feed", q)
    }

    /// 作者作品，full=true 返回含视频地址的完整条目（可直接播放）
    func authorItems(_ authorId: String, offset: Int = 0,
                     limit: Int = 30) async throws -> FeedAuthorPage {
        try await get("api2/author/\(authorId)",
                      ["offset": "\(offset)", "limit": "\(limit)", "full": "1"])
    }

    func author(_ authorId: String, offset: Int = 0, limit: Int = 30,
                full: Bool = false) async throws -> AuthorDetail {
        try await get("api2/author/\(authorId)",
                      ["offset": "\(offset)", "limit": "\(limit)",
                       "full": full ? "1" : "0"])
    }

    func authors(offset: Int = 0, limit: Int = 50, q: String? = nil) async throws -> AuthorList {
        var d = ["offset": "\(offset)", "limit": "\(limit)"]
        if let q, !q.isEmpty { d["q"] = q }
        return try await get("api2/authors", d)
    }

    func search(_ q: String, offset: Int = 0) async throws -> SearchResult {
        try await get("api2/search", ["q": q, "offset": "\(offset)"])
    }

    // MARK: - 状态

    func pushState(liked: [String: Bool] = [:],
                   saved: [String: Bool] = [:],
                   following: [String: Bool] = [:]) async {
        var body: [String: [String: Int]] = [:]
        if !liked.isEmpty { body["liked"] = liked.mapValues { $0 ? 1 : 0 } }
        if !saved.isEmpty { body["saved"] = saved.mapValues { $0 ? 1 : 0 } }
        if !following.isEmpty { body["following"] = following.mapValues { $0 ? 1 : 0 } }
        guard !body.isEmpty else { return }
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api2/state"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
    }

    /// 拉取服务端保存的状态
    func pullState() async -> StatePayload? {
        try? await get("api2/state", [:])
    }

    /// 按 vid 批量取视频（「我的」页面用）
    func videos(byIDs ids: [String]) async throws -> FeedItemsPage {
        try await get("api2/videos", ["ids": ids.joined(separator: ",")])
    }

    /// 按 authorId 批量取作者（「我的关注」用）
    func authorsByIDs(_ ids: [String]) async throws -> AuthorList {
        try await get("api2/authors", ["ids": ids.joined(separator: ",")])
    }
}

enum APIError: LocalizedError {
    case badURL
    case http(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .http(let c): return "服务器返回 \(c)"
        case .decode(let s): return "解析失败：\(s)"
        }
    }
}
