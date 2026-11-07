import Foundation
import AppKit
import SwiftUI
import Combine

enum ConnectionState {
    case connected
    case pluginDisabled
    case unreachable
}

enum MoodColorMap {
    static func label(for mood: String) -> String {
        switch mood {
        case "idle": return "空闲"
        case "waiting": return "正在思考中"
        case "jumping": return "工具调用"
        case "authorizing": return "等待你的授权"
        case "questioning": return "做出你的抉择"
        case "done": return "搞定啦"
        case "failed": return "出错了"
        case "stopped": return "已停止"
        case "disconnected", "unreachable", "disabled": return "未连接"
        default: return "未知"
        }
    }

    /// One sprite can only show one mood; when several tasks are active, keep
    /// the primary mood but make the total count visible in the bubble/menu.
    static func aggregateLabel(for mood: String, taskCount: Int) -> String {
        guard taskCount > 1 else { return label(for: mood) }
        switch mood {
        case "authorizing", "questioning": return "\(taskCount) 个任务等待操作"
        case "jumping", "waiting": return "\(taskCount) 个任务进行中"
        case "failed": return "\(taskCount) 个任务出错了"
        case "done": return "\(taskCount) 个任务已完成"
        case "stopped": return "\(taskCount) 个任务已停止"
        default: return "\(taskCount) 个任务"
        }
    }
}

enum DSHPetBarPhase: Equatable {
    case resting
    case hovering
    case composer
}

enum DSHPetTaskPanelMode: Equatable {
    case closed
    case active
    case recent
}

/// Presentation model. It only consumes MoodBridgeSnapshot and shared settings;
/// no view or pet knows about HTTP, Unix sockets, or Harness wire events.
@MainActor
final class DSHPetModel: ObservableObject {
    static let shared = DSHPetModel()

    @Published private(set) var connected = false
    @Published private(set) var mood = "idle"
    @Published private(set) var color: Color = Color(hex: disconnectedHex)
    @Published private(set) var moodLabel = "未连接"
    @Published private(set) var bubblePresentation: DSHPetBubblePresentation?
    @Published private(set) var breathingPeriod: Double = 2.0
    @Published private(set) var connectionState: ConnectionState = .unreachable
    @Published private(set) var transportKind: TransportKind = .disconnected
    @Published private(set) var barPhase: DSHPetBarPhase = .resting
    @Published private(set) var taskPanelMode: DSHPetTaskPanelMode = .closed
    @Published private(set) var composerFocusRequest = 0
    @Published private(set) var composerInputHeight: CGFloat = 38

    let commandClient = DSHPetCommandClient()
    let harnessConnections = HarnessConnectionManager()

    /// Menu bar status text includes the active transport without exposing its
    /// implementation to the views.
    var statusText: String {
        switch connectionState {
        case .connected:
            return "已连接 · \(moodLabel) · \(transportKind.rawValue)"
        case .pluginDisabled:
            return "插件已关闭（灰球）"
        case .unreachable:
            return "Harness 未连接（灰球）"
        }
    }

    @Published private(set) var wiggleTriggeredAt: Date?

    private let bridge: MoodBridge
    private var bridgeCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var commandSnapshotCancellable: AnyCancellable?
    private var didStart = false
    private var configuredHarnessID: String?
    private var selectedBubbleID: String?
    private var selectedPageWasHolding = false
    private var lastBubbleDeckMode: DSHPetBubbleDeck.Mode = .none
    private var lastWaitingTaskIDs: Set<String> = []

    init() {
        bridge = MoodBridge()
        bridgeCancellable = Publishers.CombineLatest3(bridge.$snapshot, bridge.$connection, bridge.$transportKind)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, kind in
                guard let self else { return }
                self.transportKind = kind
                self.refreshPresentation()
            }
        commandSnapshotCancellable = Publishers.CombineLatest4(
            commandClient.$bubbleDeck,
            commandClient.$connection,
            commandClient.$taskListAvailable,
            commandClient.$sessionSnapshot
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshPresentation()
            }
        commandClient.onAccepted = { [weak self] in
            self?.barPhase = .resting
        }
        harnessConnections.onTargetChange = { [weak self] instance in
            self?.configureHarness(instance) ?? false
        }
        harnessConnections.onRefresh = { [weak self] in
            guard let self else { return }
            _ = self.configureHarness(self.harnessConnections.effectiveInstance)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        let settings = SettingsStore.shared
        settingsCancellable = Publishers.CombineLatest3(settings.$apiBase, settings.$pollInterval, settings.$requestTimeout)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.bridge.updateHTTPConfiguration(settings: settings)
            }
        bridge.updateHTTPConfiguration(settings: settings)
        harnessConnections.start()
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        settingsCancellable?.cancel()
        settingsCancellable = nil
        bridge.stop()
        commandClient.stop()
        harnessConnections.stop()
        configuredHarnessID = nil
    }

    func triggerWiggle() {
        wiggleTriggeredAt = Date()
    }

    func setComposerHovering(_ hovering: Bool) {
        guard barPhase != .composer else { return }
        barPhase = hovering || taskPanelMode != .closed ? .hovering : .resting
    }

    func openComposer(focus: Bool = false) {
        closeTaskPanel()
        barPhase = .composer
        if focus { composerFocusRequest &+= 1 }
        commandClient.refreshWorkspaces()
    }

    func collapseComposer() {
        barPhase = .resting
    }

    func toggleTaskPanel(_ mode: DSHPetTaskPanelMode) {
        guard mode != .closed else {
            closeTaskPanel()
            return
        }
        if taskPanelMode == mode {
            closeTaskPanel()
            return
        }

        if taskPanelMode == .active {
            commandClient.endActiveTaskPresentation()
        }
        commandClient.clearFocusedTask()
        taskPanelMode = mode
        barPhase = .hovering
        if mode == .active {
            commandClient.beginActiveTaskPresentation()
        }
    }

    func closeTaskPanel() {
        guard taskPanelMode != .closed else { return }
        if taskPanelMode == .active {
            commandClient.endActiveTaskPresentation()
        }
        commandClient.clearFocusedTask()
        taskPanelMode = .closed
    }

    func focusTask(_ id: String) {
        commandClient.focusTask(id)
    }

    func clearFocusedTask() {
        commandClient.clearFocusedTask()
    }

    @discardableResult
    func continueTask(_ task: DSHPetTaskSummary) -> Bool {
        commandClient.continueTask(task)
    }

    func submitDraft() {
        commandClient.submitDraft()
    }

    func setComposerInputHeight(_ height: CGFloat) {
        let clamped = min(max(height, 38), 96)
        guard abs(composerInputHeight - clamped) > 0.5 else { return }
        composerInputHeight = clamped
    }

    func startNewSession() {
        commandClient.startNewSession()
        closeTaskPanel()
        barPhase = .composer
    }

    func openHarness() {
        harnessConnections.open(
            legacyWebAddress: SettingsStore.shared.apiBase,
            legacyConnected: connected && transportKind == .http
        )
    }

    func selectHarnessTarget(_ id: String) {
        _ = harnessConnections.select(id)
    }

    func refreshHarnessConnections() {
        harnessConnections.refresh()
        _ = configureHarness(harnessConnections.effectiveInstance, force: true)
    }

    @discardableResult
    private func configureHarness(_ instance: HarnessInstance?, force: Bool = false) -> Bool {
        guard didStart else { return true }
        let legacy = instance == nil && harnessConnections.instances.isEmpty
            && harnessConnections.selectionID == "auto"
        let id = instance?.id ?? (legacy ? "legacy-read-only" : "none")
        guard force || id != configuredHarnessID else { return true }
        // Source-less legacy sockets cannot prove that status and commands have the same owner.
        guard commandClient.configure(instance: instance, allowLegacy: false) else { return false }
        bridge.configure(instance: instance, allowLegacy: legacy)
        if instance != nil { commandClient.start() }
        if instance != nil || legacy { bridge.start() }
        configuredHarnessID = id
        return true
    }

    /// Pick the best available presentation source. The command socket's task
    /// deck wins while the task API is available; otherwise the bound Session
    /// and finally the global bridge snapshot keep the legacy behavior.
    private func refreshPresentation() {
        if commandClient.connection == .connected, commandClient.taskListAvailable {
            applyBubbleDeck(commandClient.bubbleDeck)
            return
        }
        clearBubbleDeckSelection()
        if let snapshot = commandClient.sessionSnapshot {
            transportKind = .localSocket
            apply(snapshot, connection: .connected)
            return
        }
        apply(bridge.snapshot, connection: bridge.connection)
    }

    private func applyBubbleDeck(
        _ deck: DSHPetBubbleDeck,
        forceSelection: String? = nil
    ) {
        breathingPeriod = SettingsStore.shared.breathingSpeed
        connected = true
        connectionState = .connected
        transportKind = .localSocket

        switch deck.mode {
        case .none:
            selectedBubbleID = nil
            selectedPageWasHolding = false
            lastBubbleDeckMode = .none
            lastWaitingTaskIDs = []
            bubblePresentation = nil
            setMood("idle", label: "空闲")

        case .single:
            guard let page = deck.pages.first else {
                selectedBubbleID = nil
                lastBubbleDeckMode = .single
                lastWaitingTaskIDs = []
                bubblePresentation = nil
                setMood("idle", label: "空闲")
                return
            }
            selectedBubbleID = page.id
            selectedPageWasHolding = page.isHolding
            lastBubbleDeckMode = .single
            lastWaitingTaskIDs = deck.waitingTaskIDs
            let label = MoodColorMap.label(for: page.mood)
            bubblePresentation = DSHPetBubblePresentation(
                style: .single,
                title: label,
                detail: nil,
                pageNumber: nil,
                stackDepth: 0,
                interactive: false,
                taskID: page.taskID
            )
            setMood(page.mood, label: label)

        case .multi:
            guard !deck.pages.isEmpty else {
                selectedBubbleID = nil
                lastBubbleDeckMode = .multi
                lastWaitingTaskIDs = []
                bubblePresentation = nil
                setMood("idle", label: "空闲")
                return
            }
            let index = DSHPetBubbleSelection.index(
                in: deck,
                previousMode: lastBubbleDeckMode,
                previousID: selectedBubbleID,
                previousWasHolding: selectedPageWasHolding,
                previousWaitingIDs: lastWaitingTaskIDs,
                forcedID: forceSelection
            )
            let page = deck.pages[index]
            selectedBubbleID = page.id
            selectedPageWasHolding = page.isHolding
            lastBubbleDeckMode = .multi
            lastWaitingTaskIDs = deck.waitingTaskIDs
            let displayText = page.isAggregate ? page.title : page.bubbleText
            bubblePresentation = DSHPetBubblePresentation(
                style: page.isAggregate ? .aggregate : .task,
                title: displayText,
                detail: page.detail,
                pageNumber: index + 1,
                stackDepth: min(2, max(0, deck.pages.count - 1)),
                interactive: true,
                taskID: page.taskID
            )
            setMood(page.mood, label: displayText)
        }
    }

    private func setMood(_ mood: String, label: String) {
        self.mood = mood
        moodLabel = label
        color = mood == "disconnected"
            ? SettingsStore.shared.disconnectedColor
            : SettingsStore.shared.moodColors[mood] ?? SettingsStore.shared.disconnectedColor
    }

    private func clearBubbleDeckSelection() {
        selectedBubbleID = nil
        selectedPageWasHolding = false
        lastBubbleDeckMode = .none
        lastWaitingTaskIDs = []
        bubblePresentation = nil
    }

    /// Advance the bubble deck. This never changes the composer target.
    func advanceBubble() {
        let deck = commandClient.bubbleDeck
        guard commandClient.connection == .connected,
              commandClient.taskListAvailable,
              deck.mode == .multi,
              deck.pages.count > 1 else { return }
        let current = selectedBubbleID.flatMap { id in
            deck.pages.firstIndex(where: { $0.id == id })
        } ?? 0
        let next = (current + 1) % deck.pages.count
        applyBubbleDeck(deck, forceSelection: deck.pages[next].id)
    }

    /// Open the Session represented by the currently visible task bubble.
    /// Aggregate and legacy status bubbles intentionally remain inert.
    func openBubbleTask() {
        guard let taskID = bubblePresentation?.taskID,
              let task = commandClient.tasks.first(where: { $0.id == taskID }) else { return }
        // Bring the exact selected Harness instance forward before its client
        // half selects the Session.
        harnessConnections.open(
            legacyWebAddress: SettingsStore.shared.apiBase,
            legacyConnected: connected && transportKind == .http
        )
        commandClient.openTaskSession(task)
    }

    func showAggregateBubble() {
        let deck = commandClient.bubbleDeck
        guard commandClient.connection == .connected,
              commandClient.taskListAvailable,
              deck.mode == .multi,
              let first = deck.pages.first else { return }
        applyBubbleDeck(deck, forceSelection: first.id)
    }

    var canCycleBubbles: Bool {
        commandClient.connection == .connected
            && commandClient.taskListAvailable
            && commandClient.bubbleDeck.mode == .multi
            && commandClient.bubbleDeck.pages.count > 1
    }

    var canShowAggregateBubble: Bool {
        guard canCycleBubbles else { return false }
        let aggregateID = commandClient.bubbleDeck.pages.first?.id
        return selectedBubbleID != aggregateID
    }

    private func apply(_ snapshot: MoodBridgeSnapshot, connection: TransportConnection) {
        breathingPeriod = SettingsStore.shared.breathingSpeed

        switch connection {
        case .connected:
            connected = true
            connectionState = .connected
            let label = MoodColorMap.label(for: snapshot.mood)
            setMood(snapshot.mood, label: label)
            if snapshot.mood == "idle" || snapshot.mood == "disconnected" {
                bubblePresentation = nil
            } else {
                bubblePresentation = DSHPetBubblePresentation(
                    style: .single,
                    title: label,
                    detail: nil,
                    pageNumber: nil,
                    stackDepth: 0,
                    interactive: false,
                    taskID: nil
                )
            }
        case .pluginDisabled:
            applyPluginDisabled()
        case .unavailable:
            applyUnreachable()
        }
    }

    private func applyPluginDisabled() {
        connected = false
        connectionState = .pluginDisabled
        bubblePresentation = nil
        mood = "disabled"
        color = SettingsStore.shared.disconnectedColor
        moodLabel = "插件已关闭"
    }

    private func applyUnreachable() {
        connected = false
        connectionState = .unreachable
        bubblePresentation = nil
        mood = "unreachable"
        color = SettingsStore.shared.disconnectedColor
        moodLabel = "未连接"
    }
}
