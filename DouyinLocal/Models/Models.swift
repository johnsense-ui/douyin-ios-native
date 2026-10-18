//
//  Models.swift
//  DouyinLocal
//
//  与 index_service 的 /api2/* 一一对应。
//

import Foundation

// MARK: - 视频条目（feed）

struct FeedItem: Decodable, Identifiable, Hashable {
    let vid: String
    let caption: String
    let authorId: String
    let author: String
    let digg: Int
    let createTime: Int
    let video: String
    let cover: String
    let source: String          // guanzhu / shoucang / both
    let liked: Bool
    let saved: Bool

    var id: String { vid }

    var videoURL: URL? { URL(string: video) }
    var coverURL: URL? { URL(string: cover) }

    /// 从九宫格构造占位（无视频地址）
    static func placeholder(from g: VideoThumb, authorId: String, author: String) -> FeedItem {
        FeedItem(vid: g.vid, caption: g.caption, authorId: authorId, author: author,
                 digg: g.digg, createTime: 0, video: "", cover: g.cover,
                 source: "", liked: false, saved: false)
    }

    /// 12345 → 1.2w
    var diggText: String { Self.formatCount(digg) }

    static func formatCount(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 10_000) }
        return "\(n)"
    }
}

struct FeedPage: Decodable {
    let ok: Bool
    let seed: String
    let total: Int
    let offset: Int
    let limit: Int
    let items: [FeedItem]
}

// MARK: - 作者

struct Author: Decodable, Identifiable, Hashable {
    let authorId: String
    let nickname: String
    let followerCount: Int
    let videoCount: Int
    let signature: String
    let avatar: String?

    var id: String { authorId }

    /// 头像占位：昵称首字
    var initial: String {
        guard let c = nickname.first else { return "?" }
        return String(c)
    }

    /// 没有昵称时兜底
    var displayName: String {
        nickname.isEmpty ? "未知作者" : nickname
    }
}

struct AuthorDetail: Decodable {
    let ok: Bool
    let author: Author
    let total: Int
    let offset: Int
    let limit: Int
    let items: [VideoThumb]
}

/// 作者作品（含视频地址，可直接播放）
struct FeedAuthorPage: Decodable {
    let ok: Bool
    let author: Author
    let total: Int
    let offset: Int
    let limit: Int
    let items: [FeedItem]
}

// MARK: - 九宫格

struct VideoThumb: Decodable, Identifiable, Hashable {
    let vid: String
    let cover: String
    let digg: Int
    let caption: String
    let authorId: String?
    let author: String?

    var id: String { vid }
    var coverURL: URL? { URL(string: cover) }
}

// MARK: - 作者列表

struct AuthorList: Decodable {
    let ok: Bool
    let total: Int
    let offset: Int
    let limit: Int
    let items: [Author]
}

// MARK: - 搜索

struct SearchResult: Decodable {
    let ok: Bool
    let q: String
    let authors: [Author]
    let authorTotal: Int
    let videos: [VideoThumb]
    let videoTotal: Int
    let offset: Int?
    let limit: Int?
    let sort: String?
}

/// 猜你想搜
struct SuggestItem: Decodable, Identifiable, Hashable {
    let type: String
    let text: String
    var id: String { type + "|" + text }
    var isAuthor: Bool { type == "author" }
}

struct SuggestResult: Decodable {
    let ok: Bool
    let items: [SuggestItem]
}

// MARK: - 状态

struct StatePayload: Decodable {
    let ok: Bool
    let liked: [String: Int]
    let saved: [String: Int]
    let following: [String: Int]?

    var likedIDs: [String] { Array(liked.keys) }
    var savedIDs: [String] { Array(saved.keys) }
    var followingIDs: [String] { Array((following ?? [:]).keys) }
}

/// 按 vid 批量取视频的返回（「我的」页面用）
struct FeedItemsPage: Decodable {
    let ok: Bool
    let items: [FeedItem]
}

/// 可 Identifiable 的 authorId，供 .sheet(item:) 使用
struct AuthorTarget: Identifiable, Hashable {
    let id: String
}

/// 播放目标（搜索结果点开时用）
struct PlayerTarget: Identifiable, Hashable {
    let authorId: String
    let vid: String
    let author: String
    var id: String { vid }
}

/// 重新扫描结果
struct RescanResult: Decodable {
    let ok: Bool
    let before: Int
    let after: Int
    let added: Int
    let removed: Int
    let elapsed: Double
}

/// 服务端统计
struct ServerStats: Decodable {
    let ok: Bool
    let videos: Int
    let authors: Int
    let authorsWithVideo: Int
}