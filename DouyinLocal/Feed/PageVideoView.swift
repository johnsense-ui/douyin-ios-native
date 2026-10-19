//
//  PageVideoView.swift
//  DouyinLocal
//
//  单页：视频画面 + 文案 + 右栏 + 进度条，全部 UIKit。
//
//  画面显示优先级（任何时刻都不允许「什么都没有」）：
//     ① AVPlayerLayer 真画面（isReadyForDisplay == true）
//     ② FramePrefetcher 解码出来的**真实第 0 帧**（图片，最快）
//     ③ 封面图（仅作最后兜底）
//     ④ 黑
//
//  关键：只有 ① 就绪才隐藏 ②③；绝不在 seek 回调里提前藏图。
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
        grad.colors = [UIColor(white: 0.58, alpha: 1).cgColor,
                       UIColor(white: 0.44, alpha: 1).cgColor]
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

    /// 官方图片资源（有就用，没有则回落到 SF Symbols）
    private let assetName: String?

    init(systemName: String, iconSize: CGFloat = 30) {
        self.iconSize = iconSize
        self.assetName = nil
        super.init(frame: .zero)
        button.tintColor = .white
        button.setImage(UIImage(systemName: systemName,
                                withConfiguration: UIImage.SymbolConfiguration(
                                    pointSize: iconSize, weight: .regular)), for: .normal)
        commonInit()
    }

    /// 用项目内的官方图标（抖音原始素材）
    init(asset: String, iconSize: CGFloat = 26) {
        self.iconSize = iconSize
        self.assetName = asset
        super.init(frame: .zero)
        button.adjustsImageWhenHighlighted = false
        button.setImage(UIImage(named: asset), for: .normal)
        commonInit()
    }

    private func commonInit() {
        addSubview(button)
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)   // 官方 SmallFont = 12
        label.textAlignment = .center
        addSubview(label)
    }

    /// 切换图标（例如点赞前/后）
    func setAsset(_ name: String) {
        guard assetName != nil else { return }
        button.setImage(UIImage(named: name), for: .normal)
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
    /// 封面（最后兜底）
    private let coverView = UIImageView()
    /// 真实第 0 帧（优先于封面）
    private let frameView = UIImageView()
    /// 底衬：同一帧放大填满并压暗，用来消除 letterbox 黑边（不裁切主画面）
    private let backdropView = UIImageView()
    /// 底部渐变：替代文字阴影，一个图层解决可读性（比 5 处阴影便宜得多）
    /// 倍速播放时的底部提示（清屏状态下唯一显示的东西）
    private let speedLabel = UILabel()
    /// 是否处于倍速清屏状态
    private(set) var speedMode = false

    private let bottomFade = CAGradientLayer()

    private let barBg = UIView()
    private let barFill = UIView()

    private let avatarBtn = TapRow()
    private let avatarDot = AvatarDot(size: 50)   // 官方半径 25
    private let followBadge = UIView()
    private let heart = RailItem(asset: "icon_home_like_before", iconSize: 26)
    private let save = RailItem(systemName: "bookmark.fill")

    private let authorRow = TapRow()
    private let authorDot = AvatarDot(size: 38)
    private let authorName = UILabel()
    private let captionLabel = UILabel()

    private var displayObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?
    private weak var obsPlayer: AVPlayer?
    private var timeObs: Any?

    var pageIndex: Int = -1
    private(set) var vid: String = ""
    private var item: FeedItem?
    private(set) var isActivePage = false
    /// 是否真的已经在播放（决定什么时候撤掉静图）
    private var playingStarted = false
    /// 播放器图层是否真的画出了帧（方案 A 的核心判据）
    private var layerHasFrame = false

    var onLike: ((String) -> Void)?
    var onSave: ((String) -> Void)?
    var onAuthor: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        // 底衬先入（最底层），视频层盖在它上面
        backdropView.contentMode = .scaleAspectFill
        backdropView.backgroundColor = .black
        backdropView.alpha = 0
        addSubview(backdropView)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.clear.cgColor   // 黑边透出底衬
        layer.addSublayer(playerLayer)

        coverView.contentMode = .scaleAspectFit
        coverView.backgroundColor = .clear
        addSubview(coverView)

        frameView.contentMode = .scaleAspectFit
        frameView.backgroundColor = .clear
        frameView.alpha = 0
        addSubview(frameView)

        bottomFade.colors = [UIColor.clear.cgColor,
                             UIColor.black.withAlphaComponent(0.55).cgColor]
        bottomFade.locations = [0, 1]
        layer.addSublayer(bottomFade)

        speedLabel.textColor = .white
        speedLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        speedLabel.textAlignment = .center
        speedLabel.text = "2.0x 倍速播放中"
        speedLabel.alpha = 0
        addSubview(speedLabel)

        barBg.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        barFill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        addSubview(barBg)
        addSubview(barFill)

        avatarBtn.addSubview(avatarDot)
        followBadge.backgroundColor = UIColor(Theme.primary)
        followBadge.layer.cornerRadius = 10
        let plus = UIImageView(image: UIImage(named: "icon_personal_add_little"))
        plus.contentMode = .center
        plus.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
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
        authorRow.addSubview(authorName)
        authorRow.onTap = { [weak self] in
            guard let a = self?.item?.authorId else { return }
            self?.onAuthor?(a)
        }
        addSubview(authorRow)

        captionLabel.textColor = .white
        captionLabel.font = .systemFont(ofSize: 14.5)
        captionLabel.numberOfLines = 2
        addSubview(captionLabel)

        displayObs = playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self] l, _ in
            guard l.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // 方案 A：图层真正有帧了，这时才允许撤静图
                if !self.layerHasFrame {
                    self.layerHasFrame = true
                    self.updateStills()
                }
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .douyinStateChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameBecameReady(_:)),
            name: .douyinFrameReady, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(imageCached(_:)),
            name: .douyinImageCached, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

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
            playingStarted = false
            layerHasFrame = false
            isActivePage = false        // 换了视频，激活态重置，允许重新激活
            frameView.alpha = 0
            frameView.image = nil
            backdropView.image = nil
            backdropView.alpha = 0
            loadCover(item.coverURL)
            if let img = serverFrame() ?? FramePrefetcher.shared.cached(item.vid) {
                frameView.image = img
                backdropView.image = img
                backdropView.alpha = 0.38
            }
        }

        authorDot.set(name: item.author)
        authorName.text = "@\(item.author)"
        captionLabel.text = item.caption.isEmpty ? nil : item.caption
        heart.set(text: item.diggText)
        refreshState()
        updateStills()
        setNeedsLayout()
    }

    func unbind() {
        detachObservers()
        playerLayer.player = nil
        vid = ""
        item = nil
        isActivePage = false
        coverView.alpha = 1
        frameView.alpha = 0
        frameView.image = nil
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
                    // 幂等：已经在播就不要重复 play，否则 AVQueuePlayer 会切回队首
                    if self.isActivePage, let p = self.playerLayer.player, p.rate <= 0 {
                        p.play()
                    }
                    // 非当前页什么都不做：不 seek、不播放，靠静图顶着
                    self.updateStills()
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

    // MARK: 画面显示优先级

    /// 唯一规则：只有「当前页 且 真的在播 且 图层真的画出帧」才撤静图
    /// 方案 A：多等 layerHasFrame 这一环，避免播放器还没出画就把静图撤掉导致黑一帧
    private func updateStills() {
        let showStill = !(isActivePage && playingStarted && layerHasFrame)

        if showStill {
            if let img = serverFrame() ?? FramePrefetcher.shared.cached(vid) {
                if frameView.image !== img { frameView.image = img }
                if backdropView.image !== img {
                    backdropView.image = img
                    if backdropView.alpha == 0 { backdropView.alpha = 0.38 }
                }
                if frameView.alpha != 1 { frameView.alpha = 1 }
                if coverView.alpha != 0 { coverView.alpha = 0 }
            } else {
                if frameView.alpha != 0 { frameView.alpha = 0 }
                if coverView.alpha != 1 { coverView.alpha = 1 }
                requestServerFrame()
            }
        } else {
            // 淡出而不是硬切，避免静图→视频那一瞬间「跳」一下
            if frameView.alpha != 0 || coverView.alpha != 0 {
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                    self.frameView.alpha = 0
                    self.coverView.alpha = 0
                }
            }
        }
    }

    private func serverFrame() -> UIImage? {
        guard let u = APIClient.frameURL(vid) else { return nil }
        return ImageCache.shared.get(u)
    }

    /// 没缓存就拉一次（后台）
    private func requestServerFrame() {
        guard let u = APIClient.frameURL(vid) else { return }
        ImageCache.shared.prefetch([u])
    }

    @objc private func imageCached(_ note: Notification) {
        guard let s = note.object as? String,
              let u = APIClient.frameURL(vid),
              s == u.absoluteString else { return }
        updateStills()
    }

    @objc private func frameBecameReady(_ note: Notification) {
        guard let v = note.object as? String, v == vid else { return }
        if let img = FramePrefetcher.shared.cached(vid) {
            frameView.image = img
        }
        updateStills()
    }

    // MARK: 播放状态

    /// 进入/退出倍速清屏：隐藏所有覆盖层，只在底部黑边里留一行「2.0x 倍速播放中」
    func setSpeedMode(_ on: Bool) {
        guard speedMode != on else { return }
        speedMode = on
        let hidden: [UIView] = [avatarBtn, heart, save, authorRow, captionLabel,
                                barBg, barFill]
        UIView.animate(withDuration: on ? 0.18 : 0.22,
                       delay: 0,
                       options: [.curveEaseOut]) {
            for v in hidden { v.alpha = on ? 0 : 1 }
            self.bottomFade.opacity = on ? 0 : 1
            self.speedLabel.alpha = on ? 1 : 0
        }
    }

    func setActive(_ active: Bool) {
        // 幂等：状态没变就不重复触发（重复 play 会让画面跳回第一帧）
        // 注意：取消激活时**不能**清零 layerHasFrame。
        // 因为 isReadyForDisplay 只在值变化时才回调，清零后回到本页时
        // 它一直是 true 不再变化 → 永远不会重新置真 → 画面卡在第一帧。
        if active && isActivePage {
            // 已经是当前页了，不要再触发一次播放
            return
        }
        isActivePage = active
        guard let p = playerLayer.player else {
            updateStills()
            return
        }
        if active {
            // 如果图层当前就有画面（之前播过），立刻认定有帧，避免静图盖死
            if playerLayer.isReadyForDisplay {
                layerHasFrame = true
            }
            if !playingStarted {
                p.play()
                // 兜底：若 350ms 内 tick 没触发（比如 item 切换时时间观察者漏了一次），
                // 也强制揭图，避免「画面停在第一帧、声音在走」
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.isActivePage, !self.playingStarted else { return }
                    self.playingStarted = true
                    // 兜底：400ms 还没收到 isReadyForDisplay 也强制认为有帧，
                    // 否则静图会一直盖着（表现为画面不动）
                    self.layerHasFrame = true
                    self.updateStills()
                }
            }
        } else {
            p.pause()
            // 关键：非当前页绝不 seek —— seek 会清空图层，而静图才是应该被看到的东西
            playingStarted = false
        }
        updateStills()
    }

    func markReady() { updateStills() }

    private func tick(_ t: CMTime) {
        // 真正开始出画面了，才允许撤掉静图
        if isActivePage && !playingStarted && t.seconds > 0.12 {
            playingStarted = true
            updateStills()
        }
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
        heart.setAsset(s.isLiked(item.vid) ? "icon_home_like_after" : "icon_home_like_before")
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
        frameView.frame = bounds
        bottomFade.frame = CGRect(x: 0, y: h - 300, width: w, height: 300)
        let lbForLabel = max(0, (h - w * 16.0 / 9.0) / 2)
        speedLabel.frame = CGRect(x: 0, y: h - lbForLabel / 2 - 9,
                                  width: w, height: 18)
        // 9:16 视频等比铺满宽度后，上下各留 (h - w*16/9)/2 的黑边
        // 进度条正好压在视频画面的底边上（iPhone 14 Pro 上约 76.7pt）
        let letterbox = max(0, (h - w * 16.0 / 9.0) / 2)
        let barY = h - letterbox
        barBg.frame = CGRect(x: 0, y: barY, width: w, height: 1.5)
        barFill.frame = CGRect(x: 0, y: barY, width: barFill.frame.width, height: 1.5)
        CATransaction.commit()

        // ===== 右栏：抖音官方 AwemeListCell 参数 =====
        // right inset 10 / 图标区 50x45 / 间距 25 / 头像 50 / 头像与收藏间距 35
        let railW: CGFloat = 50
        let iconH: CGFloat = 45
        let gap: CGFloat = 25
        let safeBottom = safeAreaInsets.bottom

        // 从下往上：收藏 → 爱心 → 头像
        var y = barY - iconH
        save.frame = CGRect(x: w - railW - 10, y: y, width: railW, height: iconH)
        y -= (iconH + gap)
        heart.frame = CGRect(x: w - railW - 10, y: y, width: railW, height: iconH)
        y -= (50 + 35)
        avatarBtn.frame = CGRect(x: w - railW - 10, y: y, width: railW, height: 50)
        avatarDot.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        followBadge.frame = CGRect(x: (50 - 20) / 2, y: 50 - 10, width: 20, height: 20)

        // ===== 文案区：bottom inset 60（官方） =====
        let textW = w - 80 - 14
        let captionH: CGFloat = 40
        // 文案底部留出进度条 + 8pt 间隙
        let captionBottom = barY - 8
        captionLabel.frame = CGRect(x: 14, y: captionBottom - captionH,
                                    width: textW, height: captionH)
        authorRow.frame = CGRect(x: 14, y: captionLabel.frame.minY - 34 - 5,
                                 width: textW, height: 34)
        authorDot.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        authorName.frame = CGRect(x: 42, y: 7, width: textW - 42, height: 20)
    }
}
