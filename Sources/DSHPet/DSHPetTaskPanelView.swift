import AppKit
import SwiftUI

struct DSHPetTaskPanelView: View {
    @ObservedObject var model: DSHPetModel
    @ObservedObject var command: DSHPetCommandClient

    private let cardHeight: CGFloat = 60

    var body: some View {
        VStack(spacing: 10) {
            header

            Group {
                if let task = command.focusedTask {
                    detail(task)
                } else {
                    switch model.taskPanelMode {
                    case .active:
                        activeContent
                    case .recent:
                        recentContent
                    case .closed:
                        EmptyView()
                    }
                }
            }
            .id("\(model.taskPanelMode)-\(command.focusedTaskID ?? "list")")
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: model.taskPanelMode)

            footer
        }
        .padding(12)
        .frame(width: 340, height: 340, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 0.8)
        )
        .onExitCommand { model.closeTaskPanel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if command.focusedTask != nil {
                Button {
                    model.clearFocusedTask()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回任务列表")
            }

            Text(command.focusedTask != nil ? "任务详情" : panelTitle)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.closeTaskPanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭任务面板")
        }
        .frame(height: 24)
    }

    private var panelTitle: String {
        model.taskPanelMode == .recent ? "最近任务" : "当前关注"
    }

    @ViewBuilder
    private var activeContent: some View {
        let tasks = command.activeTasks
        if tasks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("当前没有进行中的任务")
                    .font(.system(size: 12, weight: .medium))
                Button("查看最近任务") { model.toggleTaskPanel(.recent) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            taskList(tasks, limitHeightToFour: true)
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        let tasks = command.recentTasks
        if tasks.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "clock")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("还没有最近任务")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            taskList(tasks, limitHeightToFour: false)
        }
    }

    private func taskList(_ tasks: [DSHPetTaskSummary], limitHeightToFour: Bool) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 7) {
                ForEach(tasks) { task in
                    taskCard(task)
                }
            }
            .background(TaskPanelHiddenScroller())
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: limitHeightToFour ? cardHeight * 4 + 21 : .infinity)
    }

    private func taskCard(_ task: DSHPetTaskSummary) -> some View {
        Button {
            model.focusTask(task.id)
        } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Image(systemName: task.statusIcon)
                        Text(task.statusLabel)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                statusIcon(task)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .leading)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(command.isTaskUnread(task) ? Color.orange.opacity(0.72) : .white.opacity(0.18), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(task.title)，\(task.statusLabel)")
    }

    @ViewBuilder
    private func statusIcon(_ task: DSHPetTaskSummary) -> some View {
        if task.taskRunning || task.running {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: task.statusIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(task.failed ? Color.red : task.completed ? Color.green : .secondary)
                .frame(width: 22, height: 22)
        }
    }

    private func detail(_ task: DSHPetTaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)

            HStack(spacing: 6) {
                Image(systemName: task.statusIcon)
                Text(task.statusLabel)
                    .fontWeight(.medium)
                Text("· 更新于")
                Text(Date(timeIntervalSince1970: task.updatedAt / 1000), style: .relative)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if let message = task.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let warning = command.continuationWarning {
                Text(warning)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Spacer()
            HStack(spacing: 12) {
                Button("继续此会话") {
                    if model.continueTask(task) {
                        model.openComposer(focus: true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.sessionID, forType: .string)
                } label: {
                    Label("复制 ID", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Button("新建会话") { model.startNewSession() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
            Spacer()
            Button("打开 Harness") { model.openHarness() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(height: 18)
    }
}

private struct TaskPanelHiddenScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TaskPanelHiddenScrollerView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? TaskPanelHiddenScrollerView)?.hideEnclosingScroller()
    }
}

private final class TaskPanelHiddenScrollerView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideEnclosingScroller()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideEnclosingScroller()
    }

    func hideEnclosingScroller() {
        enclosingScrollView?.hasVerticalScroller = false
        enclosingScrollView?.verticalScroller = nil
    }
}
