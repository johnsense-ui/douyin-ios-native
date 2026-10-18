//
//  PlayerStage.swift
//  DouyinLocal
//
//  原生分页滚动 + 每页一个视频画面 + 每页自带的 UIKit 叠加 UI。
//
//  为什么叠加 UI 用 UIKit：
//   · 它是 UIScrollView 的子视图，跟着滚动视图原生物理移动 —— 零延迟跟手
//   · SwiftUI 靠回调同步偏移会天然慢半拍
//
//  对齐抖音：
//   · 拖动时整页（画面 + 文案 + 右栏）1:1 上移，下方露出下一条的第一帧
//   · 拖动期间旧视频继续播放，新视频停在第一帧
//   · 吸附完成后才切换播放
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - 可点击的容器（不会被单击手势吞掉）

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

// MARK: - 侧栏图标（图标 + 数字）

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

// MARK: - 单页（视频 + 文案 + 侧栏 + 进度条）

final class PageVideoView: UIView {
    let playerLayer = AVPlayerLayer()
    private let coverView = UIImageView()

    // 进度条
    private let barBg = UIView()
    private let barFill = UIView()

    // 右栏
    private let avatarBtn = TapRow()
    private let avatarDot = AvatarDot(size: 46)
    private let followBadge = UIView()
    private let heart = RailItem(systemName: "heart.fill")
    private let share = RailItem(systemName: "arrowshape.turn.up.right.fill")
    private let save = RailItem(systemName: "bookmark.fill")

    // 底部文案
    private let authorRow = TapRow()
    private let authorDot = AvatarDot(size: 38)
    private let authorName = UILabel()
    private let captionLabel = UILabel()

    private var displayObs: NSKeyValueObservation?
    private var timeObs: Any?

    var pageIndex: Int = -1
    private(set) var vid: String = ""
    private var item: FeedItem?

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

        // 进度条
        barBg.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        barFill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        addSubview(barBg)
        addSubview(barFill)

        // 右栏
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
        share.button.addTarget(self, action: #selector(tapShare), for: .touchUpInside)
        save.button.addTarget(self, action: #selector(tapSave), for: .touchUpInside)
        share.set(text: "分享")
        addSubview(heart)
        addSubview(share)
        addSubview(save)

        // 作者行
        authorRow.addSubview(authorDot)
        authorName.textColor = .white
        authorName.font = .systemFont(ofSize: 15.5, weight: .semibold)
        authorName.layer.shadowColor = UIColor.black.cgColor
        authorName.layer.shadowOpacity = 0.45
        authorName.layer.shadowRadius = 3
        authorRow.addSubview(authorName)
        authorRow.onTap = { [weak self] in
            guard let a = self?.item?.authorId else { return }
            self?.onAuthor?(a)
        }
        addSubview(authorRow)

        captionLabel.textColor = .white
        captionLabel.font = .systemFont(ofSize: 14.5)
        captionLabel.numberOfLines = 2
        captionLabel.layer.shadowColor = UIColor.black.cgColor
        captionLabel.layer.shadowOpacity = 0.45
        captionLabel.layer.shadowRadius = 3
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

    // MARK: 绑定

    func bind(index: Int, item: FeedItem, player: AVPlayer, ready: Bool) {
        pageIndex = index
        self.item = item

        if vid != item.vid {
            vid = item.vid
            playerLayer.player = player
            coverView.alpha = 1
            loadCover(item.coverURL)
            attachTimeObserver(player)
        } else if playerLayer.player !== player {
            playerLayer.player = player
            attachTimeObserver(player)
        }

        authorDot.set(name: item.author)
        authorName.text = "@\(item.author)"
        captionLabel.text = item.caption.isEmpty ? nil : item.caption
        heart.set(text: item.diggText)

        refreshState()

        if playerLayer.isReadyForDisplay {
            coverView.alpha = 0
        } else if !ready {
            coverView.alpha = 1
        }
        setNeedsLayout()
    }

    /// 同步点赞/收藏/关注状态
    func refreshState() {
        guard let item else { return }
        let s = StateStore.shared
        let liked = s.isLiked(item.vid)
        let saved = s.isSaved(item.vid)
        let following = s.isFollowing(item.authorId)
        heart.setTint(liked ? UIColor(red: 0xFE / 255.0, green: 0x2C / 255.0, blue: 0x55 / 255.0, alpha: 1) : .white)
        save.setTint(saved ? .systemYellow : .white)
        followBadge.isHidden = following
    }

    /// 预载第一帧（用零容差 seek 强制解码出一帧）
    func preload() {
        guard let pl = playerLayer.player else { return }
        pl.pause()
        let t = CMTime(value: 1, timescale: 600)
        pl.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.async { self?.revealVideo() }
        }
    }

    func markReady() { revealVideo() }

    private func revealVideo() {
        guard coverView.alpha != 0 else { return }
        UIView.animate(withDuration: 0.1) { self.coverView.alpha = 0 }
    }

    private func attachTimeObserver(_ player: AVPlayer) {
        if let o = timeObs { player.removeTimeObserver(o) }
        timeObs = nil
        let iv = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObs = player.addPeriodicTimeObserver(forInterval: iv, queue: .main) { [weak self] t in
            self?.updateProgress(t, player: player)
        }
    }

    private func updateProgress(_ t: CMTime, player: AVPlayer) {
        let dur = player.currentItem?.duration.seconds ?? 0
        guard dur.isFinite, dur > 0 else { return }
        let p = max(0, min(1, t.seconds / dur))
        setBar(p)
    }

    private func setBar(_ p: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width * CGFloat(p)
        barFill.frame = CGRect(x: 0, y: bounds.height - 88, width: w, height: 1.5)
        CATransaction.commit()
    }

    @objc private func stateChanged() {
        DispatchQueue.main.async { self.refreshState() }
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

    @objc private func tapShare() {
        guard let item else { return }
        let text = "\(item.author)：\(item.caption)"
        let ac = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = self
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController?
            .present(ac, animated: true)
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
        if let o = timeObs { playerLayer.player?.removeTimeObserver(o) }
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
        barBg.frame = CGRect(x: 0, y: h - 88, width: w, height: 1.5)
        CATransaction.commit()

        // 右栏
        let railW: CGFloat = 64
        let items: [UIView] = [avatarBtn, heart, share, save]
        var heights: [CGFloat] = [46 + 8, heart.intrinsicContentSize.height,
                                  share.intrinsicContentSize.height,
                                  save.intrinsicContentSize.height]
        let spacing: CGFloat = 14
        let total = heights.reduce(0, +) + spacing * CGFloat(items.count - 1)
        var y = h - 78 - total
        for (i, v) in items.enumerated() {
            let hh = heights[i]
            v.frame = CGRect(x: w - railW - 4, y: y, width: railW, height: hh)
            y += hh + spacing
        }
        avatarDot.frame = CGRect(x: (railW - 46) / 2, y: 0, width: 46, height: 46)
        followBadge.frame = CGRect(x: (railW - 19) / 2 + 8, y: 46 - 10, width: 19, height: 19)

        // 文案
        let textW = w - 96 - 14
        authorDot.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
        authorName.frame = CGRect(x: 47, y: 9, width: textW - 47, height: 20)
        authorRow.frame = CGRect(x: 14, y: h - 148, width: textW, height: 38)

        captionLabel.frame = CGRect(x: 14, y: h - 100, width: textW, height: 40)
    }
}
