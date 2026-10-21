//
//  SimilarView.swift
//  DouyinLocal
//
//  找相似结果页：查询帧预览 + 筛选面板 + 结果网格
//  点结果 → 进入播放页，从匹配时间点开始，可继续上下滑
//

import SwiftUI

struct SimilarView: View {
    let queryVid: String
    let queryTime: Double
    let queryFrameURL: URL?
    let authorName: String

    @Environment(\.dismiss) private var dismiss

    @State private var items: [SimilarItem] = []
    @State private var rawItems: [SimilarItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var elapsedMs = 0
    @State private var showFilter = false
    @State private var serviceState: SimilarAPI.Status?
    @State private var retrying = false

    // 播放跳转
    @State private var playRoute: SimilarPlayRoute?

    // ---- 筛选状态 ----
    @State private var excludeSameAuthor = true
    @State private var sameAuthorLimit = 2
    @State private var minDigg = 0
    @State private var source: String? = nil
    @State private var minScore = 0.85
    @State private var sortMode = "score"
    @State private var timeRange = 0            // 0全部 1近1月 2近3月 3近1年
    @State private var blockedAuthors: [String] = []
    @State private var blockInput = ""

    private let diggOptions: [(String, Int)] = [
        ("不限", 0), ("1千+", 1_000), ("1万+", 10_000),
        ("5万+", 50_000), ("10万+", 100_000)
    ]

    private let sortOptions: [(String, String)] = [
        ("相似度", "score"), ("多帧一致", "hits"),
        ("点赞", "digg"), ("最新", "new")
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                header
                content
            }

            if showFilter {
                filterSheet
            }
        }
        .preferredColorScheme(.dark)
        .task {
            loadSavedFilters()
            await runQuery()
        }
        .fullScreenCover(item: $playRoute) { r in
            PlayerTargetView(targets: r.items,
                             startVid: r.startVid,
                             authorName: authorOf(r.startVid),
                             startTime: r.startTime)
        }
    }

    private func authorOf(_ vid: String) -> String {
        playRoute?.items.first(where: { $0.vid == vid })?.author ?? ""
    }

    // MARK: - 顶栏

    private var navBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image("icon_titlebar_whiteback")
                    .resizable().scaledToFit()
                    .frame(width: 20, height: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
            Text("找相似")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()

            Button { withAnimation(.easeOut(duration: 0.2)) { showFilter = true } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                    Text("筛选").font(.system(size: 14))
                }
                .foregroundStyle(.white)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
    }

    // MARK: - 查询帧信息

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14))
                if let u = queryFrameURL {
                    CachedAsyncImage(url: u)
                        .scaledToFill()
                        .frame(width: 58, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 58, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                if loading {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.7)
                        Text("正在分析画面…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else if let e = errorText {
                    Text(e)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)
                } else {
                    Text("找到 \(items.count) 个相似视频")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(String(format: "%.1f", queryTime))s 处 · 用时 \(elapsedMs)ms")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - 结果

    private var content: some View {
        Group {
            if loading {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            } else if items.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: serviceState?.reachable == false
                          ? "wifi.exclamationmark" : "magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.textTertiary.opacity(0.6))

                    Text(errorText ?? "没有找到相似的视频")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    if serviceState?.reachable == false {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("请在电脑上双击运行：")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                            Text("启动找相似.bat")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                            Text("当前地址：\(SimilarAPI.currentBaseText)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary.opacity(0.7))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.13)))
                        .padding(.horizontal, 24)
                    }

                    if serviceState?.reachable == true {
                        Text("试试放宽筛选条件（相似度下限调低）")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary.opacity(0.7))
                    }

                    Button {
                        Task {
                            retrying = true
                            await runQuery()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if retrying {
                                ProgressView().tint(.white).scaleEffect(0.65)
                            }
                            Text(retrying ? "重试中…" : "重试")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 38)
                        .background(Capsule().fill(Color(white: 0.16)))
                    }
                    .buttonStyle(.plain)
                    .disabled(retrying)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 2),
                                        GridItem(.flexible(), spacing: 2),
                                        GridItem(.flexible(), spacing: 2)],
                              spacing: 2) {
                        ForEach(items) { it in
                            cell(it)
                        }
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func cell(_ it: SimilarItem) -> some View {
        Button { openPlayer(it) } label: {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    let u = APIClient.frameURL(it.vid)
                    if let u {
                        CachedAsyncImage(url: u)
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        Color(white: 0.12)
                    }

                    LinearGradient(
                        stops: [.init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.2), location: 0.5),
                                .init(color: .black.opacity(0.7), location: 1)],
                        startPoint: .top, endPoint: .bottom)
                    .frame(height: 80)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                    // 相似度标签
                    VStack {
                        HStack {
                            Text(it.scoreText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(scoreColor(it)))
                            if it.nHits >= 4 {
                                Text("\(it.nHits)帧")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.45)))
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(5)

                    HStack(spacing: 2) {
                        Image("icon_home_likenum")
                            .resizable().scaledToFit()
                            .frame(width: 9, height: 9)
                        Text(FeedItem.formatCount(it.digg))
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 6)
                    .padding(.bottom, 5)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .opacity(it.tier == 0 ? 0.62 : 1)     // <0.85 弱化
        }
        .buttonStyle(.plain)
    }

    private func scoreColor(_ it: SimilarItem) -> Color {
        switch it.tier {
        case 2: return Color(red: 0.16, green: 0.72, blue: 0.36)
        case 1: return Color(red: 0.92, green: 0.66, blue: 0.13)
        default: return Color(white: 0.38)
        }
    }

    // MARK: - 筛选面板

    private var filterSheet: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showFilter = false } }

            VStack(spacing: 0) {
                // 把手
                Capsule().fill(Color(white: 0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)

                HStack {
                    Text("筛选")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { showFilter = false }
                    } label: {
                        Text("完成")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // 1. 排除同作者
                        filterRow("排除同一作者",
                                  sub: "默认开启，避免结果被同一个作者占满") {
                            Toggle("", isOn: Binding(
                                get: { excludeSameAuthor },
                                set: { v in
                                    excludeSameAuthor = v
                                    applyFilters()
                                }))
                            .labelsHidden().tint(Theme.primary)
                        }

                        // 2. 同作者上限
                        if !excludeSameAuthor {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("同一作者最多保留")
                                    .font(.system(size: 14)).foregroundStyle(.white)
                                Picker("", selection: Binding(
                                    get: { sameAuthorLimit },
                                    set: { v in
                                        sameAuthorLimit = v
                                        applyFilters()
                                    })) {
                                    Text("不限").tag(0)
                                    Text("1 条").tag(1)
                                    Text("2 条").tag(2)
                                    Text("3 条").tag(3)
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        // 3. 点赞门槛
                        VStack(alignment: .leading, spacing: 8) {
                            Text("点赞门槛")
                                .font(.system(size: 14)).foregroundStyle(.white)
                            HStack(spacing: 8) {
                                ForEach(Array(diggOptions.enumerated()), id: \.offset) { _, opt in
                                    let label = opt.0
                                    let val = opt.1
                                    chipBtn(label, selected: minDigg == val) {
                                        minDigg = val
                                        applyFilters()
                                    }
                                }
                            }
                        }

                        // 4. 来源
                        VStack(alignment: .leading, spacing: 8) {
                            Text("来源")
                                .font(.system(size: 14)).foregroundStyle(.white)
                            HStack(spacing: 8) {
                                chipBtn("全部", selected: source == nil) {
                                    source = nil; applyFilters()
                                }
                                chipBtn("关注", selected: source == "guanzhu") {
                                    source = "guanzhu"; applyFilters()
                                }
                                chipBtn("收藏", selected: source == "shoucang") {
                                    source = "shoucang"; applyFilters()
                                }
                                chipBtn("两者", selected: source == "both") {
                                    source = "both"; applyFilters()
                                }
                            }
                        }

                        // 5. 相似度阈值
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("相似度下限")
                                    .font(.system(size: 14)).foregroundStyle(.white)
                                Spacer()
                                Text(String(format: "%.2f", minScore))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.primary)
                            }
                            Slider(value: $minScore, in: 0.75...0.95, step: 0.01,
                                   onEditingChanged: { editing in
                                if !editing { applyFilters() }
                            })
                            .tint(Theme.primary)
                        }

                        // 6. 排序
                        VStack(alignment: .leading, spacing: 8) {
                            Text("排序")
                                .font(.system(size: 14)).foregroundStyle(.white)
                            HStack(spacing: 8) {
                                ForEach(Array(sortOptions.enumerated()), id: \.offset) { _, opt in
                                    let label = opt.0
                                    let val = opt.1
                                    chipBtn(label, selected: sortMode == val) {
                                        sortMode = val
                                        applyFilters()
                                    }
                                }
                            }
                        }

                        // 7. 时间范围
                        VStack(alignment: .leading, spacing: 8) {
                            Text("发布时间")
                                .font(.system(size: 14)).foregroundStyle(.white)
                            HStack(spacing: 8) {
                                chipBtn("全部", selected: timeRange == 0) {
                                    timeRange = 0; applyFilters()
                                }
                                chipBtn("近1月", selected: timeRange == 1) {
                                    timeRange = 1; applyFilters()
                                }
                                chipBtn("近3月", selected: timeRange == 2) {
                                    timeRange = 2; applyFilters()
                                }
                                chipBtn("近1年", selected: timeRange == 3) {
                                    timeRange = 3; applyFilters()
                                }
                            }
                        }

                        // 8. 屏蔽作者
                        VStack(alignment: .leading, spacing: 8) {
                            Text("屏蔽作者")
                                .font(.system(size: 14)).foregroundStyle(.white)
                            HStack(spacing: 8) {
                                TextField("", text: $blockInput,
                                          prompt: Text("输入作者名，回车添加")
                                            .foregroundColor(Theme.textTertiary))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(.horizontal, 10)
                                    .frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(white: 0.14)))
                                    .onSubmit { addBlock() }
                                Button { addBlock() } label: {
                                    Text("添加")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white)
                                        .frame(width: 56, height: 36)
                                        .background(RoundedRectangle(cornerRadius: 8)
                                            .fill(Theme.primary))
                                }
                                .buttonStyle(.plain)
                            }
                            if !blockedAuthors.isEmpty {
                                FlowRows(items: blockedAuthors, spacing: 6) { a in
                                    HStack(spacing: 5) {
                                        Text(a).font(.system(size: 12))
                                            .foregroundStyle(.white)
                                        Button {
                                            blockedAuthors.removeAll { $0 == a }
                                            applyFilters()
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color(white: 0.16)))
                                }
                            }
                        }

                        Button {
                            resetFilters()
                        } label: {
                            Text("恢复默认")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
                }
            }
            .frame(maxHeight: 560)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(white: 0.09))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .transition(.opacity)
    }

    private func filterRow<T: View>(_ title: String, sub: String,
                                    @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14)).foregroundStyle(.white)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            trailing()
        }
    }

    private func chipBtn(_ label: String, selected: Bool,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : Theme.textTertiary)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Theme.primary : Color(white: 0.16))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 逻辑

    /// 载入上次的筛选条件
    private func loadSavedFilters() {
        let d = SimilarFilterStore.load()
        guard !d.isEmpty else { return }
        if let v = d["exAuthor"] as? Bool { excludeSameAuthor = v }
        if let v = d["authorLimit"] as? Int { sameAuthorLimit = v }
        if let v = d["minDigg"] as? Int { minDigg = v }
        if let v = d["source"] as? String, !v.isEmpty { source = v }
        if let v = d["minScore"] as? Double { minScore = v }
        if let v = d["sort"] as? String { sortMode = v }
        if let v = d["timeRange"] as? Int { timeRange = v }
        if let v = d["blocked"] as? [String] { blockedAuthors = v }
    }

    /// 保存当前筛选条件
    private func saveFilters() {
        SimilarFilterStore.save([
            "exAuthor": excludeSameAuthor,
            "authorLimit": sameAuthorLimit,
            "minDigg": minDigg,
            "source": source ?? "",
            "minScore": minScore,
            "sort": sortMode,
            "timeRange": timeRange,
            "blocked": blockedAuthors,
        ])
    }

    private func addBlock() {
        let t = blockInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !blockedAuthors.contains(t) else { return }
        blockedAuthors.append(t)
        blockInput = ""
        applyFilters()
    }

    private func resetFilters() {
        SimilarFilterStore.clear()
        excludeSameAuthor = true
        sameAuthorLimit = 2
        minDigg = 0
        source = nil
        minScore = 0.85
        sortMode = "score"
        timeRange = 0
        blockedAuthors = []
        applyFilters()
    }

    private func runQuery() async {
        loading = true
        errorText = nil

        // 先确认后端活着
        let st = await SimilarAPI.checkStatus()
        serviceState = st
        if !st.reachable {
            loading = false
            errorText = "连不上找相似服务"
            return
        }
        if !st.ready {
            loading = false
            errorText = st.error.isEmpty
                ? "服务正在加载模型，请稍等几秒后重试"
                : "服务出错：\(st.error)"
            return
        }
        if retrying { retrying = false }

        var q = SimilarQuery(vid: queryVid, t: queryTime)
        q.top = 100                       // 多取一些，客户端再筛
        q.excludeSameAuthor = false       // 同作者逻辑在客户端做（支持 N 条）
        q.minDigg = minDigg
        q.source = source
        q.minScore = 0                     // 阈值也在客户端做，便于实时调整

        let t0 = Date()
        do {
            let r = try await SimilarAPI.search(q)
            elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
            rawItems = r.results
            if let e = r.error {
                errorText = e
                items = []
            } else {
                applyFilters()
            }
        } catch {
            elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
            errorText = "查询失败：\(error.localizedDescription)"
            if case APIError.http(let code) = error, code == 404 {
                errorText = "找不到这个视频（可能文件已移动）"
            }
            items = []
        }
        loading = false
    }

    /// 客户端筛选：同作者 / 时间 / 屏蔽 / 排序
    private func applyFilters() {
        var list = rawItems

        // 排除同一作者
        if excludeSameAuthor, let first = rawItems.first {
            let qAuthor = first.author
            list = list.filter { $0.author != qAuthor }
        }

        // 同作者限 N 条
        if !excludeSameAuthor, sameAuthorLimit > 0 {
            var count: [String: Int] = [:]
            var kept: [SimilarItem] = []
            for it in list {
                let c = count[it.authorId, default: 0]
                if c < sameAuthorLimit {
                    kept.append(it)
                    count[it.authorId] = c + 1
                }
            }
            list = kept
        }

        // 点赞 / 来源 / 相似度
        if minDigg > 0 { list = list.filter { $0.digg >= minDigg } }
        if let s = source, !s.isEmpty { list = list.filter { $0.source == s } }
        list = list.filter { $0.score >= minScore }

        // 屏蔽作者
        if !blockedAuthors.isEmpty {
            list = list.filter { it in
                !blockedAuthors.contains { it.author.contains($0) }
            }
        }

        // 时间范围
        if timeRange > 0 {
            let now = Date().timeIntervalSince1970
            let days: Double = timeRange == 1 ? 30 : (timeRange == 2 ? 90 : 365)
            let cutoff = now - days * 86400
            list = list.filter { Double($0.createTime) >= cutoff }
        }

        // 排序
        switch sortMode {
        case "hits": list.sort { ($0.nHits, $0.score) > ($1.nHits, $1.score) }
        case "digg": list.sort { $0.digg > $1.digg }
        case "new":  list.sort { $0.createTime > $1.createTime }
        default:     list.sort { $0.score > $1.score }
        }

        items = list
        saveFilters()
    }

    /// 点结果 → 拉全量条目 → 从匹配时间点开始播放
    private func openPlayer(_ it: SimilarItem) {
        Task {
            let ids = items.map { $0.vid }
            if let r = try? await APIClient.shared.videos(byIDs: ids), !r.items.isEmpty {
                await MainActor.run {
                    playRoute = SimilarPlayRoute(items: r.items,
                                                 startVid: it.vid,
                                                 startTime: it.t)
                }
            } else {
                await MainActor.run {
                    errorText = "无法加载该视频"
                }
            }
        }
    }
}

// MARK: - 播放路由

struct SimilarPlayRoute: Identifiable {
    let items: [FeedItem]
    let startVid: String
    let startTime: Double
    var id: String { startVid }
}

// MARK: - 筛选条件持久化

struct SimilarFilterStore {
    static let key = "similar.filters"

    static func save(_ d: [String: Any]) {
        UserDefaults.standard.set(d, forKey: key)
    }

    static func load() -> [String: Any] {
        (UserDefaults.standard.dictionary(forKey: key)) ?? [:]
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
