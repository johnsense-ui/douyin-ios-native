//
//  SettingsView.swift
//  DouyinLocal
//
//  设置页（全屏）。
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var s = AppSettings.shared

    @State private var server = APIClient.baseURL.absoluteString
    @State private var stats: ServerStats?
    @State private var scanning = false
    @State private var scanMsg: String?
    @State private var cacheMB: Int = 0
    @State private var testing = false
    @State private var testResult: String?
    @State private var debugOn = Diagnostics.shared.enabled
    @State private var uploading = false
    @State private var uploadMsg: String?
    @State private var logLines = 0
    @State private var checking = false
    @State private var checkResults: [CheckResult] = []
    @State private var checkMsg: String?
    @State private var similarBase = SimilarAPI.currentBaseText
    @State private var similarStatus: SimilarAPI.Status?
    @State private var similarTesting = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {

                        // 播放
                        section("播放") {
                            row("单条循环", subtitle: "一条播完重新开始") {
                                Toggle("", isOn: Binding(
                                    get: { s.loopOne },
                                    set: { s.setLoopOne($0) }))
                                .labelsHidden()
                                .tint(Theme.primary)
                            }
                            divider
                            row("自动连播", subtitle: "一条播完自动滑到下一条") {
                                Toggle("", isOn: Binding(
                                    get: { s.autoplay },
                                    set: { s.setAutoplay($0) }))
                                .labelsHidden()
                                .tint(Theme.primary)
                            }
                            divider
                            row("长按倍速", subtitle: "长按视频以 2 倍速播放") {
                                Toggle("", isOn: Binding(
                                    get: { s.longPressSpeed },
                                    set: { s.longPressSpeed = $0 }))
                                .labelsHidden()
                                .tint(Theme.primary)
                            }
                        }

                        // 推荐
                        section("推荐") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("推荐算法")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                ForEach(RecommendAlgo.allCases) { a in
                                    Button {
                                        s.algo = a
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(a.title)
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(.white)
                                                Text(a.desc)
                                                    .font(.system(size: 11.5))
                                                    .foregroundStyle(Theme.textTertiary)
                                            }
                                            Spacer()
                                            if s.algo == a {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundStyle(Theme.primary)
                                            }
                                        }
                                        .padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            divider
                            VStack(alignment: .leading, spacing: 8) {
                                Text("每次加载数量")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                HStack(spacing: 8) {
                                    ForEach([8, 12, 20], id: \.self) { n in
                                        Button {
                                            s.pageSize = n
                                        } label: {
                                            Text("\(n) 条")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(s.pageSize == n ? .white : Theme.textSecondary)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 34)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 7)
                                                        .fill(s.pageSize == n
                                                              ? Theme.primary
                                                              : Color(white: 0.17))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // 视频库
                        section("视频库") {
                            row("当前视频数",
                                subtitle: stats.map { "作者 \($0.authors) 位 · 有作品 \($0.authorsWithVideo) 位" }
                                          ?? "点下面按钮刷新") {
                                Text(stats.map { "\($0.videos)" } ?? "—")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            divider
                            row("启动时自动扫描", subtitle: "打开 App 时检查电脑上新增的视频") {
                                Toggle("", isOn: Binding(
                                    get: { s.autoScan },
                                    set: { s.autoScan = $0 }))
                                .labelsHidden()
                                .tint(Theme.primary)
                            }
                            divider
                            VStack(alignment: .leading, spacing: 9) {
                                Button {
                                    rescan()
                                } label: {
                                    HStack(spacing: 7) {
                                        if scanning {
                                            ProgressView().tint(.white).scaleEffect(0.7)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        Text(scanning ? "正在扫描…" : "重新扫描视频库")
                                            .font(.system(size: 14.5, weight: .medium))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.primary))
                                }
                                .buttonStyle(.plain)
                                .disabled(scanning)

                                if let m = scanMsg {
                                    Text(m)
                                        .font(.system(size: 12))
                                        .foregroundStyle(m.hasPrefix("✓") ? .green : Theme.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("电脑上新增的视频，重扫一次就能看到")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 9)
                            divider
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("视频缓存上限")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(cacheMB > 0 ? "已用 \(cacheMB) MB" : "")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                HStack(spacing: 8) {
                                    ForEach([0, 100, 300, 500], id: \.self) { mb in
                                        Button {
                                            s.videoCacheMB = mb
                                        } label: {
                                            Text(mb == 0 ? "不缓存" : "\(mb)MB")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(s.videoCacheMB == mb ? .white : Theme.textSecondary)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 32)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 7)
                                                        .fill(s.videoCacheMB == mb
                                                              ? Theme.primary
                                                              : Color(white: 0.17))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                Text("缓存后循环播放、滑动切条都不会再黑一下")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)

                                Button {
                                    VideoCache.shared.clearAll()
                                    refreshCacheSize()
                                } label: {
                                    Text("清除缓存")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.primary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 9)
                        }
                        // 找相似服务
                        section("找相似") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("视频暂停时点「找相似」，用当前画面在全库找视觉相似的视频")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)

                                Text("服务地址")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)

                                TextField("", text: $similarBase)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .padding(.horizontal, 10)
                                    .frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(white: 0.16)))

                                HStack(spacing: 10) {
                                    Button {
                                        SimilarAPI.setBase(similarBase)
                                        simTest()
                                    } label: {
                                        HStack(spacing: 6) {
                                            if similarTesting {
                                                ProgressView().tint(.white).scaleEffect(0.7)
                                            }
                                            Text(similarTesting ? "检测中…" : "保存并检测")
                                                .font(.system(size: 14, weight: .medium))
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 38)
                                        .background(RoundedRectangle(cornerRadius: 8)
                                            .fill(Theme.primary))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(similarTesting)

                                    Button {
                                        similarBase = SimilarAPI.defaultBase
                                        SimilarAPI.setBase("")
                                        simTest()
                                    } label: {
                                        Text("默认")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(width: 64, height: 38)
                                            .background(RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(white: 0.18)))
                                    }
                                    .buttonStyle(.plain)
                                }

                                if let st = similarStatus {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(st.ready ? Color.green
                                                  : (st.reachable ? Color.orange
                                                     : Color(white: 0.4)))
                                            .frame(width: 7, height: 7)
                                        Text(st.ready
                                             ? "已就绪（加载 \(String(format: "%.0f", st.loadSeconds))s）"
                                             : (st.reachable
                                                ? (st.error.isEmpty
                                                   ? "服务在线，模型加载中…"
                                                   : "服务出错：\(st.error)")
                                                : "连不上服务"))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                }

                                Text("没连上时，在电脑上双击运行「启动找相似.bat」")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
                            }
                            .padding(.vertical, 9)
                        }

                        // 自检
                        section("自检") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("跑一遍关键路径，看看哪里有问题")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)

                                Button {
                                    Task {
                                        checking = true
                                        checkMsg = nil
                                        await SelfCheck.shared.run()
                                        checkResults = SelfCheck.shared.results
                                        checking = false
                                        checkMsg = "完成：通过 \(checkResults.filter { $0.ok }.count)/\(checkResults.count)"
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if checking {
                                            ProgressView().tint(.white).scaleEffect(0.7)
                                        }
                                        Text(checking ? "检查中…" : "开始自检")
                                            .font(.system(size: 14, weight: .medium))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(white: 0.18)))
                                }
                                .buttonStyle(.plain)
                                .disabled(checking)

                                if !checkResults.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(checkResults) { r in
                                            HStack(spacing: 6) {
                                                Image(systemName: r.ok
                                                      ? "checkmark.circle.fill"
                                                      : "xmark.circle.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(r.ok
                                                                     ? Color.green
                                                                     : Theme.primary)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(r.name)
                                                        .font(.system(size: 12.5, weight: .medium))
                                                        .foregroundStyle(.white)
                                                    Text(r.detail
                                                         + (r.ms != nil ? " · \(r.ms!)ms" : ""))
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(Theme.textTertiary)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                        }
                                    }
                                    .padding(.top, 2)

                                    Button {
                                        UIPasteboard.general.string = SelfCheck.shared.report()
                                        checkMsg = "报告已复制"
                                    } label: {
                                        Text("复制报告")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Theme.primary)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 34)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if let m = checkMsg {
                                    Text(m)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 9)
                        }

                        // 排障日志
                        section("排障日志") {
                            VStack(alignment: .leading, spacing: 10) {
                                row("排障模式",
                                    subtitle: "平时不记录日志。开启后记录播放/图层/网络细节，用于定位问题") {
                                    Toggle("", isOn: Binding(
                                        get: { debugOn },
                                        set: { on in
                                            debugOn = on
                                            Diagnostics.shared.setEnabled(on)
                                            UserDefaults.standard.set(on, forKey: "debug.logEnabled")
                                            logLines = Diagnostics.shared.lineCount()
                                        }))
                                    .labelsHidden()
                                    .tint(Theme.primary)
                                }

                                if debugOn {
                                    Text("已记录 \(logLines) 行")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)

                                    Text("复现问题后点下面的按钮上传，我会直接在电脑上看到")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textTertiary)

                                    HStack(spacing: 10) {
                                        Button {
                                            Task { await uploadLogs() }
                                        } label: {
                                            HStack(spacing: 6) {
                                                if uploading {
                                                    ProgressView().tint(.white).scaleEffect(0.7)
                                                }
                                                Text(uploading ? "上传中…" : "上传日志")
                                                    .font(.system(size: 14, weight: .medium))
                                            }
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 38)
                                            .background(RoundedRectangle(cornerRadius: 8)
                                                .fill(Theme.primary))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(uploading)

                                        Button {
                                            Diagnostics.shared.clear()
                                            logLines = 0
                                            uploadMsg = "已清空"
                                        } label: {
                                            Text("清空")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(.white)
                                                .frame(width: 72, height: 38)
                                                .background(RoundedRectangle(cornerRadius: 8)
                                                    .fill(Color(white: 0.18)))
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    if let m = uploadMsg {
                                        Text(m)
                                            .font(.system(size: 12))
                                            .foregroundStyle(m.contains("成功")
                                                             ? Color.green.opacity(0.9)
                                                             : Theme.textTertiary)
                                    }
                                }
                            }
                            .padding(.vertical, 9)
                        }

                        // 服务器
                        section("服务器") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("地址")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                TextField("", text: $server)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .padding(.horizontal, 10)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(white: 0.16)))

                                HStack(spacing: 10) {
                                    Button {
                                        testAndSave()
                                    } label: {
                                        HStack(spacing: 6) {
                                            if testing { ProgressView().tint(.white).scaleEffect(0.7) }
                                            Text(testing ? "测试中…" : "保存并测试")
                                                .font(.system(size: 14, weight: .medium))
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 38)
                                        .background(RoundedRectangle(cornerRadius: 8)
                                            .fill(Theme.primary))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(testing)
                                }

                                if let r = testResult {
                                    Text(r)
                                        .font(.system(size: 12))
                                        .foregroundStyle(r.hasPrefix("✓") ? .green : Theme.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Text("抖音本地版 · 数据来自你自己的视频库")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { loadStats(); refreshCacheSize(); simTest() }
    }

    // MARK: - 组件

    private func section<C: View>(_ title: String,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.11)))
        }
    }

    private func row<T: View>(_ title: String, subtitle: String,
                              @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 9)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    // MARK: - 视频库

    private func refreshCacheSize() {
        let bytes = VideoCache.shared.usedBytes()
        cacheMB = Int((Double(bytes) / 1024 / 1024).rounded())
    }

    private func simTest() {
        similarTesting = true
        similarStatus = nil
        Task {
            let st = await SimilarAPI.checkStatus()
            await MainActor.run {
                similarStatus = st
                similarTesting = false
            }
        }
    }

    private func uploadLogs() async {
        uploading = true
        uploadMsg = nil
        let r = await Diagnostics.shared.upload()
        uploading = false
        switch r {
        case .success(let n):
            uploadMsg = "上传成功（\(n) 字符）"
            logLines = Diagnostics.shared.lineCount()
        case .failure(let e):
            uploadMsg = "上传失败：\(e.localizedDescription)"
        }
    }

    private func loadStats() {
        Task {
            if let st = try? await APIClient.shared.stats() {
                await MainActor.run { stats = st }
            }
        }
    }

    private func rescan() {
        scanning = true
        scanMsg = nil
        Task {
            do {
                let r = try await APIClient.shared.rescan()
                let st = try? await APIClient.shared.stats()
                await MainActor.run {
                    scanning = false
                    if let st { stats = st }
                    if r.added == 0 && r.removed == 0 {
                        scanMsg = "✓ 没有新增视频（当前 \(r.after) 个）"
                    } else {
                        scanMsg = "✓ 扫描完成：新增 \(r.added) 个" +
                                  (r.removed > 0 ? "，移除 \(r.removed) 个" : "") +
                                  "，共 \(r.after) 个（\(String(format: "%.1f", r.elapsed)) 秒）"
                    }
                }
            } catch {
                await MainActor.run {
                    scanning = false
                    scanMsg = "扫描失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 服务器测试

    private func testAndSave() {
        let raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: raw), u.scheme != nil else {
            testResult = "地址格式不对"
            return
        }
        testing = true
        testResult = nil
        APIClient.setBaseURL(raw)
        Task {
            do {
                var c = URLComponents(url: u.appendingPathComponent("api2/stats"),
                                      resolvingAgainstBaseURL: false)!
                c.query = nil
                let (data, resp) = try await URLSession.shared.data(from: c.url!)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let v = obj["videos"] as? Int else {
                    throw URLError(.badServerResponse)
                }
                await MainActor.run {
                    testResult = "✓ 连接正常，共 \(v) 个视频"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败：\(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }
}
