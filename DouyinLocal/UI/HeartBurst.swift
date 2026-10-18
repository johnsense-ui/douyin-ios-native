//
//  HeartBurst.swift
//  DouyinLocal
//
//  双击点赞：爱心从点击点弹出，缩放回弹 + 轻微旋转 + 上浮淡出。
//  抖音的实际表现是：爱心在点击位置中心放大到最大后略微回落并淡出。
//

import SwiftUI

struct HeartBurst: View, Equatable, Identifiable {
    let id: UUID
    let position: CGPoint

    @State private var scale: CGFloat = 0.0
    @State private var opacity: Double = 0.0
    @State private var rotation: Double = -14
    @State private var offsetY: CGFloat = 0

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 96, weight: .bold))
            .foregroundStyle(Theme.likeRed)
            .shadow(color: .black.opacity(0.25), radius: 8)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(y: offsetY)
            .opacity(opacity)
            .position(position)
            .allowsHitTesting(false)
            .onAppear {
                // 弹出
                withAnimation(.spring(response: 0.26, dampingFraction: 0.52)) {
                    scale = 1.0
                    opacity = 1.0
                    rotation = 6
                }
                // 回落 + 淡出
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                    withAnimation(.easeOut(duration: 0.34)) {
                        scale = 0.78
                        opacity = 0
                        offsetY = -34
                        rotation = 0
                    }
                }
            }
    }

    static func == (l: HeartBurst, r: HeartBurst) -> Bool { l.id == r.id }
}

/// 管理多个爱心（连点时不会互相打断）
@MainActor
final class HeartBurstManager: ObservableObject {
    @Published var bursts: [HeartBurst] = []

    func pop(at p: CGPoint) {
        let b = HeartBurst(id: UUID(), position: p)
        bursts.append(b)
        // 清理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            if !self.bursts.isEmpty {
                self.bursts.removeFirst()
            }
        }
    }
}
