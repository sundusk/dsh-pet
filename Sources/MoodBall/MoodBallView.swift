import SwiftUI

/// 发光心情球：radialGradient 本体 + blur 外发光 + 高光，
/// 用 TimelineView 按 mood 周期做正弦呼吸（透明度 + 缩放，ease-in-out 平滑）。
///
/// 性能说明：呼吸是 ~0.5Hz 的慢变化，12fps 与 60fps 视觉无差，
/// 且球体整体走 drawingGroup（内容变化才重新栅格化，缩放/透明度变成便宜的核心动画图层变换），
/// 光晕用多 stop 渐变代替 blur 滤镜。
///
/// 附带拖拽手势：按住球体任意位置即可把整个悬浮窗拖到任何地方（位置会记住）。
/// 非空闲状态时，在球脑门上方显示漫画风说话气泡（中文状态提醒），空闲时隐藏。
/// 宠物底部锚定：面板随皮肤、发光和气泡调整大小，宠物脚底的屏幕位置保持不变。
///
/// 状态来源：只消费 `MoodBallModel`（由 `AppCoordinator.activityState` 派生），
/// 不接触任何 wire 事件 / DOM（规格 9 / 23）。
struct MoodBallView: View {
    @ObservedObject var model: MoodBallModel
    @ObservedObject var settings: SettingsStore
    let onOpenDesktopHarness: () -> Void

    /// 按下时鼠标与窗口原点的偏移（全局坐标），拖拽中保持不变
    @State private var grabOffset: CGSize = .zero
    @State private var hasGrabOffset = false
    /// 拖拽按下时的鼠标全局坐标（用于区分「单击」与「拖动」）
    @State private var dragStart: CGPoint?
    /// 小雨拖拽奔跑方向；用锚点累积细小移动，避免鼠标抖动导致频繁换向。
    @State private var dragDirection: XiaoyuDragDirection?
    @State private var dragDirectionAnchorX: CGFloat?
    /// 上次单击时间（用于识别双击 → 兴奋晃动）
    @State private var lastTapAt: Date?

    /// 状态气泡总高度（正文 30 + 尾巴 14），气泡出现时面板额外增高的量。
    /// MoodBallCoordinator 同步用它计算面板高度。
    static let bubbleHeight: CGFloat = 44
    /// 气泡尾巴尖端与球头顶部的间距
    static let tailGap: CGFloat = 4

    static func petHeight(for skin: FloatingPetSkin, size: CGFloat, glowEnabled: Bool) -> CGFloat {
        skin.isSprite ? size * (glowEnabled ? 1.55 : 1.10) : size * 2
    }

    static func panelWidth(for skin: FloatingPetSkin, size: CGFloat, glowEnabled: Bool, showBubble: Bool) -> CGFloat {
        if skin.isSprite && !showBubble {
            return size * (glowEnabled ? 1.55 : 0.95)
        }
        return size * 2
    }

    static func panelHeight(for skin: FloatingPetSkin, size: CGFloat, glowEnabled: Bool, showBubble: Bool) -> CGFloat {
        petHeight(for: skin, size: size, glowEnabled: glowEnabled)
            + (showBubble ? bubbleHeight + (skin.isSprite ? tailGap : 0) : 0)
    }

    var body: some View {
        let d = settings.ballSize
        let showBubble = model.bubbleText != nil && settings.showStatusBubble
        let panelWidth = Self.panelWidth(
            for: settings.skin, size: d, glowEnabled: settings.glowEnabled, showBubble: showBubble
        )
        let petHeight = Self.petHeight(for: settings.skin, size: d, glowEnabled: settings.glowEnabled)
        let bubbleSpace = Self.panelHeight(
            for: settings.skin, size: d, glowEnabled: settings.glowEnabled, showBubble: showBubble
        ) - petHeight
        // 心情球保留完整光晕；小雨窗口只包含精灵、光晕和当前显示的气泡。
        let bubbleAnchorOffset = bubbleAnchor(for: d)

        ZStack(alignment: .top) {
            Group {
                switch settings.skin {
                case .moodBall:
                    moodBallArtwork(diameter: d)
                        .contentShape(Circle())
                case .xiaoyu, .xinzhizhu, .jingyuniang:
                    XiaoyuSpriteView(
                        skin: settings.skin,
                        mood: model.mood,
                        color: model.color,
                        size: d,
                        glowEnabled: settings.glowEnabled,
                        interactionTriggeredAt: model.wiggleTriggeredAt,
                        dragDirection: dragDirection
                    )
                        .contentShape(Rectangle())
                }
            }
            .frame(width: panelWidth, height: petHeight)
            .offset(y: bubbleSpace)
            .gesture(dragGesture)

            // —— 状态气泡层：仅动画自身显隐，不影响布局（面板高度由外层瞬时切换）——
            ZStack(alignment: .top) {
                if showBubble, let text = model.bubbleText {
                    SpeechBubble(text: text, color: model.color)
                        .offset(y: settings.skin.isSprite ? 0 : bubbleAnchorOffset - Self.tailGap)
                        .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showBubble)
            .allowsHitTesting(false)
        }
        // 顶部对齐使新增的气泡空间只向上延伸，宠物底部不动。
        .frame(
            width: panelWidth,
            height: petHeight + bubbleSpace,
            alignment: .top
        )
    }

    /// 原心情球画面完整保留；只有选择心情球皮肤时才计算呼吸、眨眼和晃动。
    private func moodBallArtwork(diameter d: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wave = (sin(t * 2.0 * .pi / model.breathingPeriod) + 1.0) / 2.0
            let scale = 0.90 + 0.14 * wave
            let opacity = 0.55 + 0.45 * wave
            let eyeScale = Self.blinkScale(at: t)
            let wiggleStart = model.wiggleTriggeredAt?.timeIntervalSinceReferenceDate
            let wiggleTime = wiggleStart.map { t - $0 } ?? 2.0
            let wiggleAngle = wiggleTime < 2.0
                ? sin(wiggleTime * 2.0 * .pi) * (1.0 - wiggleTime / 2.0) * 0.35
                : 0

            ZStack {
                if settings.glowEnabled {
                    Circle()
                        .fill(RadialGradient(
                            stops: [
                                .init(color: model.color.opacity(0.60), location: 0),
                                .init(color: model.color.opacity(0.30), location: 0.45),
                                .init(color: model.color.opacity(0.08), location: 0.75),
                                .init(color: model.color.opacity(0), location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: d * 0.85
                        ))
                        .frame(width: d * 1.7, height: d * 1.7)
                }

                Circle()
                    .fill(RadialGradient(
                        colors: [model.color, model.color.opacity(0.75)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: d
                    ))
                    .frame(width: d, height: d)
                    .shadow(color: settings.glowEnabled ? model.color.opacity(0.8) : .clear, radius: d * 0.16)

                Circle()
                    .fill(RadialGradient(
                        colors: [Color.white.opacity(0.65), Color.white.opacity(0)],
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 0,
                        endRadius: d * 0.6
                    ))
                    .frame(width: d * 0.82, height: d * 0.82)
                    .blendMode(.screen)

                if settings.showEyes {
                    ForEach([-CGFloat(1), CGFloat(1)], id: \.self) { direction in
                        Ellipse()
                            .fill(settings.eyeColor.color)
                            .frame(width: d * 0.10, height: d * 0.183)
                            .offset(x: direction * d * 0.117)
                            .scaleEffect(x: 1, y: eyeScale, anchor: .center)
                    }
                }
            }
            .drawingGroup()
            .scaleEffect(scale)
            .opacity(opacity)
            .rotationEffect(.radians(wiggleAngle), anchor: .bottom)
            .frame(width: d * 2, height: d * 2)
        }
    }

    private func bubbleAnchor(for diameter: CGFloat) -> CGFloat {
        switch settings.skin {
        case .moodBall:
            return diameter / 2
        case .xiaoyu, .xinzhizhu, .jingyuniang:
            return diameter
        }
    }

    /// 眨眼竖向缩放：周期 4s，闭眼 0.12s（快）+ 睁眼 0.18s（慢），其余全睁（1.0）。
    /// 返回 0.08...1.0 的竖向缩放值，越小眼睛越「闭」。
    static func blinkScale(at t: TimeInterval) -> CGFloat {
        let period: TimeInterval = 4.0
        let closeDur: TimeInterval = 0.12
        let openDur: TimeInterval = 0.18
        let phase = t.truncatingRemainder(dividingBy: period)
        if phase < closeDur {
            // 闭眼：从 1 → 0.08（线性，快）
            return CGFloat(1.0 - phase / closeDur * 0.92)
        }
        if phase < closeDur + openDur {
            // 睁眼：从 0.08 → 1（线性，稍慢）
            let p = (phase - closeDur) / openDur
            return CGFloat(0.08 + p * 0.92)
        }
        return 1.0
    }

    /// 拖拽：让窗口跟随鼠标的全局位置（抓取点保持在光标下），
    /// 不依赖手势 translation，避免窗口移动后坐标系反馈导致拖拽缩水。
    /// 单击无操作；双击触发宠物动作，并唤出正在运行的桌面版 Harness；锁定位置时不可拖拽。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard let panel = MoodBallPanel.current else { return }
                panel.isDragging = true
                let mouse = NSEvent.mouseLocation // 全局坐标（左下原点），与 frame.origin 同坐标系
                if !hasGrabOffset {
                    grabOffset = CGSize(
                        width: mouse.x - panel.frame.origin.x,
                        height: mouse.y - panel.frame.origin.y
                    )
                    dragStart = mouse
                    dragDirectionAnchorX = mouse.x
                    hasGrabOffset = true
                }
                // 锁定位置：不移动窗口（仍允许单击）
                if settings.lockPosition {
                    dragDirection = nil
                    dragDirectionAnchorX = nil
                    return
                }
                if let anchorX = dragDirectionAnchorX,
                   let direction = XiaoyuDragDirection.direction(
                       forHorizontalDelta: mouse.x - anchorX
                   ) {
                    dragDirection = direction
                    dragDirectionAnchorX = mouse.x
                }
                panel.setFrameOrigin(NSPoint(
                    x: mouse.x - grabOffset.width,
                    y: mouse.y - grabOffset.height
                ))
            }
            .onEnded { _ in
                guard let panel = MoodBallPanel.current else {
                    resetDragTracking(panel: nil)
                    return
                }
                let mouse = NSEvent.mouseLocation
                // 几乎没移动 → 单击
                let isTap: Bool
                if let start = dragStart {
                    isTap = hypot(mouse.x - start.x, mouse.y - start.y) < 4
                } else {
                    isTap = false
                }
                if isTap {
                    // 双击（0.35s 内两次单击）→ 宠物动作 + 唤出桌面版；单击无操作
                    let now = Date()
                    if let last = lastTapAt, now.timeIntervalSince(last) < 0.35 {
                        lastTapAt = nil
                        model.triggerWiggle()
                        onOpenDesktopHarness()
                    } else {
                        lastTapAt = now
                    }
                    resetDragTracking(panel: panel)
                    return
                }
                if settings.lockPosition {
                    resetDragTracking(panel: panel)
                    return
                }
                // 抬手时把抓取点精确归位到光标下，消除事件延迟造成的残差
                if hasGrabOffset {
                    panel.setFrameOrigin(NSPoint(
                        x: mouse.x - grabOffset.width,
                        y: mouse.y - grabOffset.height
                    ))
                }
                resetDragTracking(panel: panel)
                panel.persistPosition()
            }
    }

    private func resetDragTracking(panel: MoodBallPanel?) {
        dragStart = nil
        dragDirection = nil
        dragDirectionAnchorX = nil
        hasGrabOffset = false
        grabOffset = .zero
        panel?.isDragging = false
    }
}
// MARK: - 状态气泡（漫画风说话框）

/// 漫画风说话气泡：圆角矩形白底 + 状态色描边 + 底部小三角尾巴指向球脑门。
struct SpeechBubble: View {
    let text: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.8))
                .lineLimit(1)
                .frame(height: 30)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color, lineWidth: 2)
                )
            BubbleTail(color: color)
                .frame(width: 16, height: 14)
        }
        .fixedSize()
    }
}

/// 气泡尾巴：白色小三角 + 两侧状态色描边（顶部与圆角矩形下缘相接，不封口）。
struct BubbleTail: View {
    let color: Color

    var body: some View {
        Triangle()
            .fill(.white.opacity(0.92))
            .overlay(
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 8, y: 14))
                    p.addLine(to: CGPoint(x: 16, y: 0))
                }
                .stroke(color, lineWidth: 2)
            )
    }
}

/// 倒三角（尖端朝下）。
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
