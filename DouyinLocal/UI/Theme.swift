//
//  Theme.swift
//  DouyinLocal
//
//  抖音视觉参数。数值按抖音实际界面比例取。
//

import SwiftUI

enum Theme {
    // 主色：抖音红
    static let primary = Color(red: 0xFE / 255.0, green: 0x2C / 255.0, blue: 0x55 / 255.0)
    static let likeRed = Color(red: 0xFE / 255.0, green: 0x2C / 255.0, blue: 0x55 / 255.0)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.78)
    static let textTertiary = Color.white.opacity(0.55)
    static let overlay = Color.black.opacity(0.35)

    // 间距（按 390pt 宽设计）
    static let hPadding: CGFloat = 14
    static let actionIconSize: CGFloat = 30
    static let actionSpacing: CGFloat = 20
}

/// 抖音侧边操作栏图标（带数字）
struct ActionButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .white
    var filled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: Theme.actionIconSize, weight: .regular))
                    .foregroundStyle(tint)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .symbolEffect(.bounce, value: filled)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 作者头像占位（昵称首字）
struct AvatarView: View {
    let author: Author?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if let a = author {
                Text(a.initial)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        LinearGradient(colors: [Theme.primary.opacity(0.9),
                                                Color(red: 0.35, green: 0.2, blue: 0.6)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.2))
            } else {
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: size, height: size)
            }
        }
    }
}

/// 顶部 tab：推荐 / 关注
struct TopTabs: View {
    @Binding var selected: Int
    let titles: [String]

    var body: some View {
        HStack(spacing: 26) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selected = i }
                } label: {
                    VStack(spacing: 5) {
                        Text(titles[i])
                            .font(.system(size: selected == i ? 17.5 : 16,
                                          weight: selected == i ? .bold : .medium))
                            .foregroundStyle(selected == i ? .white : Theme.textTertiary)
                        Capsule()
                            .fill(selected == i ? Color.white : .clear)
                            .frame(width: 20, height: 2.5)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }
}
