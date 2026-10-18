//
//  DouyinLocalApp.swift
//  DouyinLocal
//

import SwiftUI

@main
struct DouyinLocalApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    /// 是否已完成首次连接
    @AppStorage("hasServer") private var hasServer = false

    var body: some View {
        if hasServer {
            FeedView()
        } else {
            ServerSetupView()
        }
    }
}

/// 首次启动：填写服务器地址
struct ServerSetupView: View {
    @AppStorage("hasServer") private var hasServer = false
    @State private var text = "https://locvid-pc.tail83739b.ts.net:8444"
    @State private var checking = false
    @State private var status: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                Text("连接你的本地视频库")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("iPhone 需与电脑处于同一 Tailscale 网络")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)

                TextField("", text: $text, prompt: Text("https://…")
                    .foregroundStyle(Theme.textTertiary))
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.15)))

                if let s = status {
                    Text(s).font(.system(size: 12))
                        .foregroundStyle(s.hasPrefix("✓") ? .green : Theme.likeRed)
                }

                Button {
                    connect()
                } label: {
                    HStack {
                        if checking { ProgressView().tint(.white) }
                        Text("连接").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.primary))
                }
                .disabled(checking)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 26)
        }
        .preferredColorScheme(.dark)
    }

    private func connect() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: raw), u.scheme != nil else {
            status = "地址格式不对"
            return
        }
        checking = true
        status = "正在连接…"
        APIClient.setBaseURL(raw)
        Task {
            do {
                var c = URLComponents(url: u.appendingPathComponent("api2/stats"),
                                      resolvingAgainstBaseURL: false)!
                c.query = nil
                let (data, resp) = try await URLSession.shared.data(from: c.url!)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let v = obj["videos"] as? Int {
                    await MainActor.run {
                        status = "✓ 已连接，共 \(v) 个视频"
                        checking = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            hasServer = true
                        }
                    }
                } else {
                    throw URLError(.cannotParseResponse)
                }
            } catch {
                await MainActor.run {
                    status = "连接失败：\(error.localizedDescription)"
                    checking = false
                }
            }
        }
    }
}
