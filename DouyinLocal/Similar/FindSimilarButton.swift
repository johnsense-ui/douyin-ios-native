//
//  FindSimilarButton.swift
//  DouyinLocal
//
//  暂停时显示的「找相似」按钮（推荐页 / 作者页 / 搜索 / 收藏 通用）
//

import SwiftUI

/// 找相似的目标
struct SimilarTarget: Identifiable {
    let vid: String
    let t: Double
    let frameURL: URL?
    let author: String
    var id: String { vid + String(format: "%.2f", t) }
}

struct FindSimilarButton: View {
    let vid: String
    let t: Double
    let frameURL: URL?
    let author: String
    @Binding var target: SimilarTarget?

    var body: some View {
        Button {
            target = SimilarTarget(vid: vid,
                                   t: max(0.5, t),
                                   frameURL: frameURL,
                                   author: author)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "viewfinder.circle")
                    .font(.system(size: 15, weight: .medium))
                Text("找相似")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(.black.opacity(0.55))
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
    }
}
