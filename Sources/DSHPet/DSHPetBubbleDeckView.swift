import SwiftUI

/// Single status bubble (original) or the stacked multi-task bubble deck.
/// The multi bubble reuses the original 30 pt body, 10 pt corner radius, 13 pt
/// text, border, shadow and tail. Only a small page tab and thin stacked edges
/// are new.
struct DSHPetBubbleDeckView: View {
    let presentation: DSHPetBubblePresentation
    let color: Color
    let onTap: () -> Void

    var body: some View {
        if presentation.style == .single {
            SpeechBubble(text: presentation.title, color: color)
        } else {
            multiBubble
        }
    }

    private var displayText: String {
        let limit = 10
        guard presentation.title.count > limit else { return presentation.title }
        return String(presentation.title.prefix(limit)) + "…"
    }

    private var multiBubble: some View {
        ZStack(alignment: .top) {
            ForEach(0..<max(0, presentation.stackDepth), id: \.self) { depth in
                bubbleBody(showText: false, bodyHeight: 26)
                    .offset(
                        x: CGFloat(depth + 1) * 4,
                        y: CGFloat(depth + 1) * 1.5
                    )
            }

            VStack(spacing: 0) {
                bubbleBody(showText: true, bodyHeight: DSHPetView.bubbleBodyHeight)
                    .overlay(alignment: .topTrailing) {
                        if let pageNumber = presentation.pageNumber {
                            Text("\(pageNumber)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 13, height: 13)
                                .background(Circle().fill(color))
                                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                                .offset(x: 6, y: -5)
                                .accessibilityLabel("第 \(pageNumber) 页")
                        }
                    }

                BubbleTail(color: color)
                    .frame(width: 16, height: 14)
            }
        }
        .padding(.top, DSHPetView.multiBubbleTopInset)
        .contentShape(Rectangle())
        .onTapGesture {
            if presentation.interactive { onTap() }
        }
        .help(presentation.interactive ? "点击切换任务气泡" : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func bubbleBody(showText: Bool, bodyHeight: CGFloat) -> some View {
        Text(displayText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(showText ? Color.black.opacity(0.8) : Color.clear)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: bodyHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(showText ? 0.92 : 0.58))
                    .shadow(
                        color: showText ? .black.opacity(0.18) : .clear,
                        radius: showText ? 4 : 0,
                        y: showText ? 2 : 0
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color.opacity(showText ? 1 : 0.30), lineWidth: showText ? 2 : 1.5)
            )
    }

    private var accessibilityText: String {
        var parts = [displayText]
        if let pageNumber = presentation.pageNumber { parts.append("第 \(pageNumber) 页") }
        if presentation.interactive { parts.append("点击切换") }
        return parts.joined(separator: "，")
    }
}
