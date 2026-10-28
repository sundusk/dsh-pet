import AppKit
import SwiftUI

/// The quiet bar, hover action bar, and composer share one stable panel. Task
/// content is intentionally rendered by `DSHPetTaskPanelView` in a separate
/// AppKit panel so hover never resizes or clips task cards.
struct DSHPetComposerView: View {
    @ObservedObject var model: DSHPetModel
    @ObservedObject var command: DSHPetCommandClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Leave one small transparent inset around the idle capsule so its curved
    // ends and antialiasing are not clipped by the backing NSPanel.
    static let restingPanelWidth: CGFloat = 28
    static let restingPanelHeight: CGFloat = 12
    static let expandedBarPanelWidth: CGFloat = 220
    static let expandedBarPanelHeight: CGFloat = 42
    static let restingBarWidth: CGFloat = 24
    static let restingBarHeight: CGFloat = 8
    static let taskBarHeight: CGFloat = 34
    static let composerInputMinimumHeight: CGFloat = 38

    static func expandedComposerHeight(inputHeight: CGFloat, showsStatusLine: Bool) -> CGFloat {
        (showsStatusLine ? 125 : 106) + inputHeight - composerInputMinimumHeight
    }

    var body: some View {
        Group {
            if model.barPhase == .composer {
                expandedComposer
            } else {
                standardComposer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var standardComposer: some View {
        switch model.barPhase {
        case .resting, .hovering:
            actionBar(expanded: model.barPhase == .hovering)
        case .composer:
            expandedComposer
        }
    }

    private func actionBar(expanded: Bool) -> some View {
        let expandedWidth: CGFloat = 148
        let shapeAnimation: Animation? = reduceMotion
            ? nil
            : (expanded
                ? .timingCurve(0.77, 0, 0.175, 1, duration: 0.5)
                : .timingCurve(0.23, 1, 0.32, 1, duration: 0.25))
        let barShape = RoundedRectangle(
            cornerRadius: expanded ? Self.taskBarHeight / 2 : Self.restingBarHeight / 2,
            style: .continuous
        )
        return ZStack {
            barShape
                .fill(expanded ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.white.opacity(0.46)))
                .overlay(
                    barShape.stroke(.white.opacity(expanded ? 0.25 : 0), lineWidth: 0.7)
                )
                .shadow(
                    color: .black.opacity(expanded ? 0.2 : 0.16),
                    radius: expanded ? 4 : 0.5,
                    y: expanded ? 2 : 0.5
                )

            if expanded {
                HStack(spacing: 4) {
                    actionButton("square.and.pencil", label: "输入消息") {
                        model.openComposer(focus: false)
                    }

                    Divider().frame(height: 16).opacity(0.45)

                    Button {
                        model.toggleTaskPanel(.active)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: command.unreadTaskCount > 0 ? "bell.badge.fill" : "checklist")
                            if !command.activeTasks.isEmpty {
                                Text("\(command.activeTasks.count)")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(command.unreadTaskCount > 0 ? Color.orange : .primary.opacity(0.72))
                        .frame(width: 38, height: 26)
                    }
                    .buttonStyle(.plain)
                    .disabled(!command.taskListAvailable)
                    .accessibilityLabel("当前任务，\(command.activeTasks.count)项")

                    actionButton("clock.arrow.circlepath", label: "最近任务") {
                        model.toggleTaskPanel(.recent)
                    }
                    .disabled(!command.taskListAvailable)
                }
                .padding(.horizontal, 7)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(
            width: expanded ? expandedWidth : Self.restingBarWidth,
            height: expanded ? Self.taskBarHeight : Self.restingBarHeight
        )
        .animation(shapeAnimation, value: expanded)
    }

    private func actionButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.76))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var expandedComposer: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Menu {
                    if command.workspaces.isEmpty {
                        Text("请先在 Harness 中添加工作区")
                    } else {
                        ForEach(command.workspaces) { workspace in
                            Button {
                                command.selectWorkspace(workspace.id)
                            } label: {
                                if workspace.id == command.selectedWorkspaceID {
                                    Label(workspace.title, systemImage: "checkmark")
                                } else {
                                    Text(workspace.title)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("刷新工作区") { command.refreshWorkspaces() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                        Text(command.selectedWorkspaceTitle ?? "选择工作区")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
                }
                .menuStyle(.borderlessButton)
                .disabled(command.submissionStatus == .submitting)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 2)

                if let sessionID = command.sessionID {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sessionID, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("复制会话 ID")
                }

                Button {
                    model.collapseComposer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("收起输入框")
            }

            Text("输入目标 · \(command.inputTargetTitle)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .topLeading) {
                    if command.draft.isEmpty {
                        Text(command.hasWorkspace ? "输入消息…" : "请先选择工作区")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .padding(.leading, 11)
                            .padding(.top, 10)
                    }
                    DSHPetTextView(
                        text: $command.draft,
                        measuredHeight: Binding(
                            get: { model.composerInputHeight },
                            set: { model.setComposerInputHeight($0) }
                        ),
                        onSubmit: { model.submitDraft() },
                        onEscape: { model.collapseComposer() },
                        focusRequest: model.composerFocusRequest
                    )
                    .padding(.trailing, 38)
                }
                .frame(height: model.composerInputHeight)

                let inputShape = RoundedRectangle(
                    cornerRadius: model.composerInputHeight == Self.composerInputMinimumHeight ? 19 : 16,
                    style: .continuous
                )

                inputShape
                    .fill(.white.opacity(0.14))
                    .allowsHitTesting(false)
                    .zIndex(-1)

                inputShape
                    .stroke(.white.opacity(0.23), lineWidth: 0.8)
                    .allowsHitTesting(false)

                Button {
                    model.submitDraft()
                } label: {
                    if command.submissionStatus == .submitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(command.canSend ? Color.accentColor : Color.secondary.opacity(0.35), in: Circle())
                .disabled(!command.canSend)
                .accessibilityLabel("发送")
                .padding(.trailing, 5)
                .padding(.bottom, 4.5)
            }

            if command.connection != .connected || !command.capabilitiesAvailable {
                Text("输入服务未连接，请确认 DSH Pet 桥接插件已加载")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if command.workspaces.isEmpty {
                Text("没有可用工作区，请先在 Harness 中添加")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let label = command.submissionStatus.label ?? command.lastError {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(command.submissionStatus == .submitted ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 0.8)
        )
        .frame(
            width: 340,
            height: Self.expandedComposerHeight(
                inputHeight: model.composerInputHeight,
                showsStatusLine: command.showsComposerStatusLine
            )
        )
    }
}

/// NSTextView keeps IME composition separate from submit: Enter confirms a
/// composed Chinese candidate first, while Shift+Enter remains a newline.
struct DSHPetTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        DispatchQueue.main.async {
            scroll.window?.makeFirstResponder(textView)
            context.coordinator.updateMeasuredHeight(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.updateMeasuredHeight(textView)
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                scroll.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DSHPetTextView
        var lastFocusRequest: Int?

        init(_ parent: DSHPetTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateMeasuredHeight(textView)
        }

        func updateMeasuredHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
            let clamped = min(max(contentHeight, 38), 96)
            guard abs(parent.measuredHeight - clamped) > 0.5 else { return }
            parent.measuredHeight = clamped
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                if textView.hasMarkedText() { return false }
                if NSEvent.modifierFlags.contains(.shift) { return false }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
