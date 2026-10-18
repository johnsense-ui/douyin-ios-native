//
//  PageVideoView.swift
//  DouyinLocal
//
//  单页：视频画面 + 文案 + 右栏 + 进度条，全部 UIKit。
//
//  关键点：
//   · 时间观察者要记住「属于哪个 player」，换 player 时必须从旧的移除
//     —— 否则 removeTimeObserver 传错对象会直接抛异常闪退
//   · 非当前页用零容差 seek 停在第一帧（0.05s 处，确保有真实画面）
//   · 进度条放最底部，文案和右栏都往上让，避免重叠
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - 可点击容器

final class TapRow: UIControl {
    var onTap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onTap?() }
}

// MARK: - 圆形头像

final class AvatarDot: UIView {
    private let grad = CAGradientLayer()
    private let label = UILabel()

    init(size: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        grad.colors = [UIColor(Theme.primary).cgColor,
                       UIColor(red: 0.36, green: 0.22, blue: 0.62, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        grad.cornerRadius = size / 2
        layer.addSublayer(grad)

        label.textColor = .white
        label.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
        label.textAlignment = .center
        addSubview(label)

        layer.cornerRadius = size / 2
        layer.borderWidth = 1.2
        layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        grad.frame = bounds
        label.frame = bounds
    }

    func set(name: String) {
        label.text = name.first.map(String.init) ?? "?"
    }
}

// MARK: - 侧栏条目

final class RailItem: UIView {
    let button = UIButton(type: .custom)
    private let label = UILabel()
    private let iconSize: CGFloat

    init(systemName: String, iconSize: CGFloat = 30) {
        self.iconSize = iconSize
        super.init(frame: .zero)

        button.tintColor = .white
        button.setImage(UIImage(systemName: systemName,
                                withConfiguration: UIImage.SymbolConfiguration(
                                    pointSize: iconSize, weight: .regular)), for: .normal)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.4
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(button)

        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.45
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String) { label.text = text }
    func setTint(_ c: UIColor) { button.tintColor = c }

    override var intrinsicContentSize: CGSize {
        CGSize(width: max(52, iconSize + 22), height: iconSize + 20)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, icon = iconSize
        button.frame = CGRect(x: (w - icon) / 2, y: 0, width: icon, height: icon)
        label.frame = CGRect(x: 0, y: icon + 3, width: w, height: 15)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }
}

// MARK: - 单页

final class PageVideoView: UIView {
    let playerLayer = AVPlayerLayer()
    private let coverView = UIImageView()

    private let barBg = UIView()
    private let barFill = UIView()

    private let avatarBtn = TapRow()
    private let avatarDot = AvatarDot(size: 46)
    private let followBadge = UIView()
    private let heart = RailItem(systemName: "heart.fill")
    private let save = RailItem(systemName: "bookmark.fill")

    private let authorRow = TapRow()
    private let authorDot = AvatarDot(size: 38)
    private let authorName = UILabel()
    private let captionLabel = UILabel()

    private var displayObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?
    /// 时间观察者所属的 player（换 player 时必须从它身上移除）
    private weak var obsPlayer: AVPlayer?
    private var timeObs: Any?

    var pageIndex: Int = -1
    private(set) var vid: String = ""
    private var item: FeedItem?
    private(set) var isActivePage = false

    var onLike: ((String) -> Void)?
    var onSave: ((String) -> Void)?
    var onAuthor: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)

        coverView.contentMode = .scaleAspectFit
        coverView.backgroundColor = .clear
        addSubview(coverView)

        barBg.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        barFill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        addSubview(barBg)
        addSubview(barFill)

        avatarBtn.addSubview(avatarDot)
        followBadge.backgroundColor = UIColor(Theme.primary)
        followBadge.layer.cornerRadius = 9.5
        let plus = UIImageView(image: UIImage(systemName: "plus",
                                              withConfiguration: UIImage.SymbolConfiguration(
                                                pointSize: 9, weight: .bold)))
        plus.tintColor = .white
        plus.contentMode = .center
        plus.frame = CGRect(x: 0, y: 0, width: 19, height: 19)
        followBadge.addSubview(plus)
        avatarBtn.addSubview(followBadge)
        avatarBtn.onTap = { [weak self] in
            guard let a = self?.item?.authorId else { return }
            self?.onAuthor?(a)
        }
        addSubview(avatarBtn)

        heart.button.addTarget(self, action: #selector(tapLike), for: .touchUpInside)
        save.button.addTarget(self, action: #selector(tapSave), for: .touchUpInside)
        addSubview(heart)
        addSubview(save)

        authorRow.addSubview(authorDot)
        authorName.textColor = .white
        authorName.font = .systemFont(ofSize: 15.5, weight: .semibold)
        addShadow(authorName)
        authorRow.addSubview(authorName)
        authorRow.onTap = { [weak self] in
            guard let a = self?.item?.authorId else { return }
            self?.onAuthor?(a)
        }
        addSubview(authorRow)

        captionLabel.textColor = .white
        captionLabel.font = .systemFont(ofSize: 14.5)
        captionLabel.numberOfLines = 2
        addShadow(captionLabel)
        addSubview(captionLabel)

        displayObs = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] l, _ in
            guard l.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.revealVideo() }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .douyinStateChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addShadow(_ v: UIView) {
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.5
        v.layer.shadowRadius = 3
        v.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    // MARK: 绑定 / 解绑

    func bind(index: Int, item: FeedItem, player: AVPlayer, ready: Bool) {
        pageIndex = index
        self.item = item

        if obsPlayer !== player {
            detachObservers()
            playerLayer.player = player
            attachObservers(to: player)
        }

        if vid != item.vid {
            vid = item.vid
            coverView.alpha = 1
            loadCover(item.coverURL)
        }

        authorDot.set(name: item.author)
        authorName.text = "@\(item.author)"
        captionLabel.text = item.caption.isEmpty ? nil : item.caption
        heart.set(text: item.diggText)
        refreshState()

        if playerLayer.isReadyForDisplay && isActivePage {
            coverView.alpha = 0
        }
        setNeedsLayout()
    }

    func unbind() {
        detachObservers()
        playerLayer.player = nil
        vid = ""
        item = nil
        isActivePage = false
        coverView.alpha = 1
    }

    private func attachObservers(to player: AVPlayer) {
        obsPlayer = player

        let iv = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObs = player.addPeriodicTimeObserver(forInterval: iv, queue: .main) { [weak self] t in
            self?.tick(t)
        }

        if let ci = player.currentItem {
            statusObs = ci.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
                guard it.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isActivePage {
                        self.playerLayer.player?.play()
                    } else {
                        self.seekToFirstFrame()
                    }
                }
            }
        }
    }

    private func detachObservers() {
        if let o = timeObs, let p = obsPlayer {
            p.removeTimeObserver(o)
        }
        timeObs = nil
        obsPlayer = nil
        statusObs?.invalidate()
        statusObs = nil
    }

    // MARK: 播放状态

    func setActive(_ active: Bool) {
        isActivePage = active
        guard let p = playerLayer.player else { return }
        if active {
            p.play()
            if playerLayer.isReadyForDisplay { revealVideo() }
        } else {
            p.pause()
            seekToFirstFrame()
        }
    }

    /// 零容差 seek 到 0.05s，强制解出一帧真实画面
    private func seekToFirstFrame() {
        guard let p = playerLayer.player else { return }
        let t = CMTime(seconds: 0.05, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.async {
                guard let self, !self.isActivePage else { return }
                self.revealVideo()
            }
        }
    }

    func markReady() { revealVideo() }

    private func revealVideo() {
        guard coverView.alpha != 0 else { return }
        UIView.animate(withDuration: 0.1) { self.coverView.alpha = 0 }
    }

    private func tick(_ t: CMTime) {
        let dur = playerLayer.player?.currentItem?.duration.seconds ?? 0
        guard dur.isFinite, dur > 0 else { return }
        let p = max(0, min(1, t.seconds / dur))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barFill.frame = CGRect(x: 0, y: barBg.frame.minY,
                               width: bounds.width * CGFloat(p), height: 1.5)
        CATransaction.commit()
    }

    // MARK: 交互

    @objc private func stateChanged() {
        DispatchQueue.main.async { self.refreshState() }
    }

    func refreshState() {
        guard let item else { return }
        let s = StateStore.shared
        heart.setTint(s.isLiked(item.vid)
                      ? UIColor(red: 0xFE / 255.0, green: 0x2C / 255.0, blue: 0x55 / 255.0, alpha: 1)
                      : .white)
        save.setTint(s.isSaved(item.vid) ? .systemYellow : .white)
        followBadge.isHidden = s.isFollowing(item.authorId)
    }

    @objc private func tapLike() {
        guard let v = item?.vid else { return }
        onLike?(v)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refreshState() }
    }

    @objc private func tapSave() {
        guard let v = item?.vid else { return }
        onSave?(v)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refreshState() }
    }

    private func loadCover(_ url: URL?) {
        coverView.image = nil
        guard let url else { return }
        if let cached = ImageCache.shared.get(url) {
            coverView.image = cached
            return
        }
        let targetVid = vid
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            ImageCache.shared.set(url, img)
            DispatchQueue.main.async {
                if self.vid == targetVid, self.coverView.alpha > 0 {
                    self.coverView.image = img
                }
            }
        }.resume()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        detachObservers()
        displayObs?.invalidate()
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        coverView.frame = bounds
        barBg.frame = CGRect(x: 0, y: h - 80, width: w, height: 1.5)
        barFill.frame = CGRect(x: 0, y: h - 80, width: barFill.frame.width, height: 1.5)
        CATransaction.commit()

        let railW: CGFloat = 64
        let items: [UIView] = [avatarBtn, heart, save]
        let heights: [CGFloat] = [46 + 8,
                                  heart.intrinsicContentSize.height,
                                  save.intrinsicContentSize.height]
        let spacing: CGFloat = 14
        let total = heights.reduce(0, +) + spacing * CGFloat(items.count - 1)
        var y = h - 96 - total
        for (i, v) in items.enumerated() {
            v.frame = CGRect(x: w - railW - 4, y: y, width: railW, height: heights[i])
            y += heights[i] + spacing
        }
        avatarDot.frame = CGRect(x: (railW - 46) / 2, y: 0, width: 46, height: 46)
        // 小加号：水平居中在头像下沿
        let avatarX = (railW - 46) / 2
        followBadge.frame = CGRect(x: avatarX + (46 - 19) / 2, y: 46 - 12, width: 19, height: 19)

        let textW = w - 96 - 14
        authorDot.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
        authorName.frame = CGRect(x: 47, y: 9, width: textW - 47, height: 20)
        authorRow.frame = CGRect(x: 14, y: h - 172, width: textW, height: 38)
        captionLabel.frame = CGRect(x: 14, y: h - 126, width: textW, height: 40)
    }
}
