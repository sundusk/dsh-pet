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
}

enum MoodBallBarPhase: Equatable {
    case resting
    case hovering
    case composer
}

enum MoodBallTaskPanelMode: Equatable {
    case closed
    case active
    case recent
}

/// Presentation model. It only consumes MoodBridgeSnapshot and shared settings;
/// no view or pet knows about HTTP, Unix sockets, or Harness wire events.
@MainActor
final class MoodBallModel: ObservableObject {
    static let shared = MoodBallModel()

    @Published private(set) var connected = false
    @Published private(set) var mood = "idle"
    @Published private(set) var color: Color = Color(hex: disconnectedHex)
    @Published private(set) var moodLabel = "未连接"
    @Published private(set) var breathingPeriod: Double = 2.0
    @Published private(set) var connectionState: ConnectionState = .unreachable
    @Published private(set) var transportKind: TransportKind = .disconnected
    @Published private(set) var barPhase: MoodBallBarPhase = .resting
    @Published private(set) var taskPanelMode: MoodBallTaskPanelMode = .closed
    @Published private(set) var composerFocusRequest = 0
    @Published private(set) var composerInputHeight: CGFloat = 38

    let commandClient = MoodBallCommandClient()
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

    var bubbleText: String? {
        switch mood {
        case "idle", "unreachable", "disabled", "disconnected": return nil
        default: return moodLabel
        }
    }

    @Published private(set) var wiggleTriggeredAt: Date?

    private let bridge: MoodBridge
    private var bridgeCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var commandSnapshotCancellable: AnyCancellable?
    private var didStart = false
    private var configuredHarnessID: String?

    init() {
        bridge = MoodBridge()
        bridgeCancellable = Publishers.CombineLatest3(bridge.$snapshot, bridge.$connection, bridge.$transportKind)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, connection, kind in
                self?.transportKind = kind
                self?.apply(snapshot, connection: connection)
            }
        commandSnapshotCancellable = commandClient.$sessionSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                if let snapshot {
                    self.apply(snapshot, connection: .connected)
                } else {
                    self.apply(self.bridge.snapshot, connection: self.bridge.connection)
                }
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

    func toggleTaskPanel(_ mode: MoodBallTaskPanelMode) {
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
    func continueTask(_ task: MoodBallTaskSummary) -> Bool {
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

    private func apply(_ snapshot: MoodBridgeSnapshot, connection: TransportConnection) {
        breathingPeriod = SettingsStore.shared.breathingSpeed

        switch connection {
        case .connected:
            connected = true
            connectionState = .connected
            mood = snapshot.mood
            moodLabel = MoodColorMap.label(for: snapshot.mood)
            color = snapshot.mood == "disconnected"
                ? SettingsStore.shared.disconnectedColor
                : SettingsStore.shared.moodColors[snapshot.mood] ?? SettingsStore.shared.disconnectedColor
        case .pluginDisabled:
            applyPluginDisabled()
        case .unavailable:
            applyUnreachable()
        }
    }

    private func applyPluginDisabled() {
        connected = false
        connectionState = .pluginDisabled
        mood = "disabled"
        color = SettingsStore.shared.disconnectedColor
        moodLabel = "插件已关闭"
    }

    private func applyUnreachable() {
        connected = false
        connectionState = .unreachable
        mood = "unreachable"
        color = SettingsStore.shared.disconnectedColor
        moodLabel = "未连接"
    }
}
