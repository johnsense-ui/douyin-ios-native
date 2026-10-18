//
//  AppSettings.swift
//  DouyinLocal
//
//  用户偏好，存 UserDefaults。
//

import Foundation
import Combine

enum RecommendAlgo: Int, CaseIterable, Identifiable {
    case mixed = 0      // 点赞 × 时间衰减 × 来源
    case digg = 1       // 纯点赞
    case new = 2        // 最新
    case random = 3     // 纯随机

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mixed: return "智能推荐"
        case .digg: return "高赞优先"
        case .new: return "最新发布"
        case .random: return "随机播放"
        }
    }

    var desc: String {
        switch self {
        case .mixed: return "点赞高、较新的更容易出现"
        case .digg: return "爆款视频出现得更频繁"
        case .new: return "按发布时间倒序"
        case .random: return "完全随机，每次都不同"
        }
    }

    var apiValue: String {
        switch self {
        case .mixed: return "mixed"
        case .digg: return "digg"
        case .new: return "new"
        case .random: return "random"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var autoplay: Bool {
        didSet { d.set(autoplay, forKey: "set.autoplay") }
    }
    /// 单条循环（与自动连播互斥）
    @Published var loopOne: Bool {
        didSet { d.set(loopOne, forKey: "set.loopOne") }
    }
    @Published var algo: RecommendAlgo {
        didSet { d.set(algo.rawValue, forKey: "set.algo") }
    }
    @Published var pageSize: Int {
        didSet { d.set(pageSize, forKey: "set.pageSize") }
    }
    @Published var longPressSpeed: Bool {
        didSet { d.set(longPressSpeed, forKey: "set.longPressSpeed") }
    }

    private let d = UserDefaults.standard

    private init() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            "set.autoplay": false,
            "set.loopOne": true,
            "set.algo": 0,
            "set.pageSize": 12,
            "set.longPressSpeed": true,
        ])
        autoplay = ud.bool(forKey: "set.autoplay")
        loopOne = ud.bool(forKey: "set.loopOne")
        algo = RecommendAlgo(rawValue: ud.integer(forKey: "set.algo")) ?? .mixed
        pageSize = ud.integer(forKey: "set.pageSize")
        longPressSpeed = ud.bool(forKey: "set.longPressSpeed")
    }

    /// 自动连播和单条循环互斥
    func setAutoplay(_ on: Bool) {
        autoplay = on
        if on { loopOne = false }
    }

    func setLoopOne(_ on: Bool) {
        loopOne = on
        if on { autoplay = false }
    }
}
