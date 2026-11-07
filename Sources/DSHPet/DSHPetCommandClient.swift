import Foundation
import AppKit
import Darwin
import Network
import SwiftUI

enum DSHPetCommandConnection: Equatable {
    case disconnected
    case connecting
    case connected
}

enum DSHPetCandidateKind: Equatable {
    case file, skill
}

struct DSHPetInputCandidate: Equatable, Identifiable {
    let id: String
    let label: String
    let insertText: String
    let detail: String?
    let disabledReason: String?
}

struct DSHPetWorkspace: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let path: String
    let status: String
    let sessionIds: [String]
}

struct DSHPetImageLimits: Codable, Equatable {
    let maxImageBytes: Int
    let maxImagesPerMessage: Int
    let maxMessageImageBytes: Int
    let mediaTypes: [String]
}

struct DSHPetDraftImage: Codable, Equatable, Identifiable {
    let id: String
    let path: String
    let mediaType: String
    let name: String
    let bytes: Int
    var error: String?

    var fileURL: URL { URL(fileURLWithPath: path) }
}

enum DSHPetSubmissionStatus: Equatable {
    case idle
    case submitting
    case submitted
    case unconfirmed
    case failed(String)

    var label: String? {
        switch self {
        case .idle: return nil
        case .submitting: return "正在提交…"
        case .submitted: return "已提交"
        case .unconfirmed: return "提交结果未确认"
        case .failed(let message): return message
        }
    }
}

enum DSHPetCommandError: LocalizedError {
    case unavailable
    case timedOut
    case malformed
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "发送服务未连接，请确认 DSH Pet 桥接插件已加载"
        case .timedOut: return "提交结果未确认"
        case .malformed: return "DSH Pet 桥接插件返回了无法识别的结果"
        case .server(_, let message): return message
        }
    }
}

/// DSHPet-only client for the plugin's user-local command socket.
@MainActor
final class DSHPetCommandClient: ObservableObject {
    @Published private(set) var connection: DSHPetCommandConnection = .disconnected
    @Published private(set) var capabilitiesAvailable = false
    @Published private(set) var taskListAvailable = false
    @Published private(set) var imageAttachmentsAvailable = false
    @Published private(set) var imageLimits: DSHPetImageLimits?
    @Published private(set) var workspaces: [DSHPetWorkspace] = []
    @Published private(set) var tasks: [DSHPetTaskSummary] = []
    /// Presentation deck for the pet's status bubble.
    @Published private(set) var bubbleDeck = DSHPetBubbleDeck.empty
    @Published private(set) var selectedWorkspaceID: String?
    @Published private(set) var sessionID: String?
    @Published private(set) var sessionSnapshot: MoodBridgeSnapshot?
    @Published private(set) var focusedTaskID: String?
    @Published private(set) var submissionStatus: DSHPetSubmissionStatus = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var continuationWarning: String?
    @Published private(set) var candidateKind: DSHPetCandidateKind?
    @Published private(set) var candidates: [DSHPetInputCandidate] = []
    @Published private(set) var candidatesLoading = false
    @Published private(set) var candidatesError: String?
    @Published private(set) var taskPreview: String?
    @Published private(set) var taskPreviewStatus: String?
    @Published private(set) var taskOpenError: String?
    @Published private(set) var draftImages: [DSHPetDraftImage] = []
    @Published var selectedSkillPrefix: String? {
        didSet {
            if let selectedSkillPrefix { defaults.set(selectedSkillPrefix, forKey: Keys.selectedSkillPrefix) }
            else { defaults.removeObject(forKey: Keys.selectedSkillPrefix) }
        }
    }
    @Published var draft: String {
        didSet {
            defaults.set(draft, forKey: Keys.draft)
            if let selectedSkillPrefix, !draft.hasPrefix(selectedSkillPrefix) { self.selectedSkillPrefix = nil }
        }
    }

    var onAccepted: (() -> Void)?

    var showsComposerStatusLine: Bool {
        connection != .connected
            || !capabilitiesAvailable
            || workspaces.isEmpty
            || submissionStatus.label != nil
            || lastError != nil
            || busyMessage != nil
    }

    private enum Keys {
        static let workspaceID = "dsh-pet.command.workspaceID"
        static let sessionID = "dsh-pet.command.sessionID"
        static let draft = "dsh-pet.command.draft"
        static let selectedSkillPrefix = "dsh-pet.command.selectedSkillPrefix"
        static let requestID = "dsh-pet.command.pendingRequestID"
        static let requestText = "dsh-pet.command.pendingRequestText"
        static let taskReadMarkers = "dsh-pet.command.taskReadMarkers"
        static let draftImages = "dsh-pet.command.draftImages"
        static let requestSignature = "dsh-pet.command.pendingRequestSignature"
        static let targetBindingKey = "dsh-pet.command.targetBindingKey"
    }

    private struct TaskReadMarker: Codable {
        let updatedAt: TimeInterval
        let mood: String
    }

    private struct BubbleObservation: Equatable {
        let mood: String
        let updatedAt: TimeInterval
        let terminal: Bool
    }

    private let defaults: UserDefaults
    private let legacySocketPath: String
    private var socketPath: String
    private var expectedInstanceID: String?
    private var targetInstance: HarnessInstance?
    private var persistedTargetBindingKey: String?
    private var allowLegacy = true
    private var sourceEnabled = true
    private let queue = DispatchQueue(label: "com.sundusk.dsh-pet.command-client")
    private var connectionHandle: NWConnection?
    private var receiveBuffer = Data()
    private var queuedPayloads: [Data] = []
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var started = false
    private var pendingRequestID: String?
    private var pendingRequestText: String?
    private var pendingRequestSignature: String?
    private var reconnectTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var capabilitiesValidated = false
    private var fileCandidatesAvailable = false
    private var skillCandidatesAvailable = false
    private var taskPreviewAvailable = false
    private var candidateGeneration = 0
    private var candidateTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var taskOpenGeneration = 0
    private var sessionBindingGeneration = 0
    private var sessionCreationTask: Task<String, Error>?
    private var readMarkers: [String: TaskReadMarker] = [:]
    private var hasReceivedTaskBaseline = false
    private var presentedActiveTaskIDs: Set<String>?
    private var bubbleOrder: [String] = []
    private var terminalHoldUntil: [String: TimeInterval] = [:]
    private var lastBubbleObservation: [String: BubbleObservation] = [:]
    private var bubbleHoldTask: Task<Void, Never>?
    private let now: () -> TimeInterval

    init(
        defaults: UserDefaults = .standard,
        socketPath: String = DSHPetCommandClient.defaultSocketPath,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.now = now
        self.legacySocketPath = socketPath
        self.socketPath = socketPath
        persistedTargetBindingKey = defaults.string(forKey: Keys.targetBindingKey)
        selectedWorkspaceID = defaults.string(forKey: Keys.workspaceID)
        sessionID = defaults.string(forKey: Keys.sessionID)
        let restoredDraft = defaults.string(forKey: Keys.draft) ?? ""
        draft = restoredDraft
        let savedSkillPrefix = defaults.string(forKey: Keys.selectedSkillPrefix)
        selectedSkillPrefix = savedSkillPrefix.flatMap { restoredDraft.hasPrefix($0) ? $0 : nil }
        pendingRequestID = defaults.string(forKey: Keys.requestID)
        pendingRequestText = defaults.string(forKey: Keys.requestText)
        pendingRequestSignature = defaults.string(forKey: Keys.requestSignature)
        // Attachments are no longer exposed by the DSHPet composer. Ignore
        // any legacy persisted draft metadata so it can never be sent unseen.
        defaults.removeObject(forKey: Keys.draftImages)
        if let data = defaults.data(forKey: Keys.taskReadMarkers),
           let markers = try? JSONDecoder().decode([String: TaskReadMarker].self, from: data) {
            readMarkers = markers
        }
    }

    nonisolated static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/DSH Pet/dsh-pet-command.sock"
    }

    var selectedWorkspace: DSHPetWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedWorkspaceTitle: String? { selectedWorkspace?.title }

    var hasWorkspace: Bool { selectedWorkspace != nil }

    /// Every ordinary Session projected by the bridge is a task-center
    /// candidate. The card list deliberately does not follow the composer's
    /// selected workspace: a task started from the Harness desktop or web UI
    /// must appear without first using the pet to pick a workspace.
    var taskCenterTasks: [DSHPetTaskSummary] { tasks }

    func workspaceTitle(for task: DSHPetTaskSummary) -> String? {
        workspaces.first { $0.id == task.workspaceID }?.title
    }

    /// Tasks that still need attention in any registered workspace. While the
    /// active-task panel is open, its opening snapshot remains visible so a
    /// result does not disappear immediately after the user reads it.
    var activeTasks: [DSHPetTaskSummary] {
        taskCenterTasks
            .filter { task in
                return isTaskActive(task) || (presentedActiveTaskIDs?.contains(task.id) == true)
            }
            .sorted(by: activeTaskPrecedes)
    }

    /// The five most recently updated, non-empty tasks which are not currently
    /// shown by the active-task classification (including its presentation
    /// snapshot).
    var recentTasks: [DSHPetTaskSummary] {
        let activeTaskIDs = Set(activeTasks.map(\.id))
        return Array(
            taskCenterTasks
                .filter { !$0.blank && !activeTaskIDs.contains($0.id) }
                .sorted(by: recentTaskPrecedes)
                .prefix(5)
        )
    }

    /// Task-center order: waiting for a user action, unread failures, unread
    /// completions, running work, then the remaining recent Sessions.
    var sortedTasks: [DSHPetTaskSummary] {
        taskCenterTasks.sorted(by: taskPrecedes)
    }

    var focusedTask: DSHPetTaskSummary? {
        guard let focusedTaskID else { return nil }
        return tasks.first { $0.id == focusedTaskID }
    }

    var unreadTaskCount: Int {
        activeTasks.reduce(into: 0) { count, task in
            if isTaskUnread(task) && (task.completed || task.failed) { count += 1 }
        }
    }

    var inputTargetTitle: String {
        guard let sessionID else { return "新建会话" }
        return tasks.first { $0.id == sessionID }?.title ?? "会话 \(sessionID.suffix(8))"
    }

    var canSend: Bool {
        guard connection == .connected,
              capabilitiesAvailable,
              hasWorkspace,
              (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty),
              submissionStatus != .submitting else { return false }
        if !draftImages.isEmpty && !imageAttachmentsAvailable { return false }
        return !(sessionSnapshot?.taskRunning ?? false)
    }

    /// A source change is destructive to the local routing context while a
    /// draft or an unconfirmed request is present. The caller can use this to
    /// disable a target picker before invoking `configure`.
    var targetSwitchBlocked: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftImages.isEmpty
            || submissionStatus == .submitting
            || submissionStatus == .unconfirmed
            || pendingRequestID != nil
    }

    var targetBindingKey: String? {
        targetInstance?.bindingKey ?? persistedTargetBindingKey
    }

    var attachmentLimitSummary: String? {
        guard let imageLimits else { return nil }
        return "最多 \(imageLimits.maxImagesPerMessage) 张，单张 \(Self.byteLabel(imageLimits.maxImageBytes))"
    }

    var busyMessage: String? {
        guard let snapshot = sessionSnapshot, snapshot.taskRunning else { return nil }
        if snapshot.message == "无法确认任务状态，暂不可发送" { return snapshot.message }
        if snapshot.waitingForUser { return "请在 Harness 中完成当前操作" }
        return "当前会话正在执行，请稍候"
    }

    func start() {
        guard !started else { return }
        started = true
        guard sourceEnabled else {
            connection = .disconnected
            return
        }
        connect()
    }

    /// Switch the command source. Every connection is revalidated against the
    /// selected descriptor before any business request is allowed through.
    @discardableResult
    func configure(instance: HarnessInstance?, allowLegacy: Bool) -> Bool {
        let currentBinding = targetBindingKey ?? (self.allowLegacy ? "legacy" : nil)
        let requestedBinding = instance?.bindingKey ?? (allowLegacy ? "legacy" : currentBinding)
        let sameInstance = targetInstance?.instanceId == instance?.instanceId
        let oldTargetStillRunning = targetInstance.map { Darwin.kill($0.pid, 0) == 0 } ?? false
        let parallelSameBinding = instance != nil
            && targetInstance != nil
            && requestedBinding == currentBinding
            && !sameInstance
            && oldTargetStillRunning
        let changed = requestedBinding != currentBinding || parallelSameBinding
        let canAdoptUnidentifiedTarget = targetInstance == nil
            && persistedTargetBindingKey == nil
            && instance != nil
            && pendingRequestID == nil
            && submissionStatus != .submitting
            && submissionStatus != .unconfirmed
        if changed && targetSwitchBlocked && !canAdoptUnidentifiedTarget {
            lastError = "请先处理当前草稿或未确认请求，再切换 Harness 来源"
            return false
        }

        let hadUnidentifiedHistory = persistedTargetBindingKey == nil
            && targetInstance == nil
            && instance != nil
            && (selectedWorkspaceID != nil || sessionID != nil || pendingRequestID != nil)
        invalidateConnection(clearPersistedPending: changed)
        if changed {
            clearTargetCaches()
        } else {
            // A restarted process may keep the same stable bindingKey but has
            // a new instanceId. Never replay old queued or in-flight requests.
            queuedPayloads.removeAll(keepingCapacity: false)
            failPending(with: DSHPetCommandError.unavailable)
            if submissionStatus == .submitting {
                submissionStatus = pendingRequestID == nil ? .idle : .unconfirmed
            }
        }

        if hadUnidentifiedHistory {
            selectedWorkspaceID = nil
            defaults.removeObject(forKey: Keys.workspaceID)
            continuationWarning = "Harness 来源已更新，请重新选择工作区"
        }

        self.allowLegacy = allowLegacy
        sourceEnabled = instance != nil || allowLegacy
        if let instance {
            targetInstance = instance
            persistedTargetBindingKey = instance.bindingKey
            defaults.set(instance.bindingKey, forKey: Keys.targetBindingKey)
            socketPath = instance.commandSocketPath
            expectedInstanceID = instance.instanceId
        } else if allowLegacy {
            targetInstance = nil
            persistedTargetBindingKey = "legacy"
            defaults.set("legacy", forKey: Keys.targetBindingKey)
            socketPath = legacySocketPath
            expectedInstanceID = nil
        } else {
            // Keep the last target identity for a later rediscovery, while the
            // disabled state prevents any stale socket from being used.
            socketPath = legacySocketPath
            expectedInstanceID = nil
        }
        capabilitiesValidated = false
        resetCapabilityState()
        guard started, sourceEnabled else {
            connection = .disconnected
            return true
        }
        connect()
        return true
    }

    func stop() {
        started = false
        invalidateConnection(clearPersistedPending: false)
        resetCapabilityState()
    }

    func addImageFromPasteboard(_ pasteboard: NSPasteboard = .general) {
        guard submissionStatus != .submitting else { return }
        guard imageAttachmentsAvailable else {
            lastError = "当前 DSH Pet 桥接插件不支持图片附件"
            return
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            lastError = "剪贴板中没有可用图片"
            return
        }
        addDraftImage(data: png, mediaType: "image/png", name: "粘贴图片.png")
    }

    func makeRegionCaptureURL() -> URL? {
        guard submissionStatus != .submitting else { return nil }
        guard imageAttachmentsAvailable else {
            lastError = "当前 DSH Pet 桥接插件不支持图片附件"
            return nil
        }
        do {
            let directory = try draftImageDirectory()
            return directory.appendingPathComponent("截屏-\(UUID().uuidString.lowercased()).png")
        } catch {
            lastError = errorMessage(error)
            return nil
        }
    }

    func acceptRegionCapture(at url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        addDraftImageFile(url: url, data: data, mediaType: "image/png", name: "框选截图.png")
    }

    func cancelRegionCapture(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func reportRegionCaptureFailure(_ message: String) {
        lastError = message.isEmpty ? "截图失败，请检查屏幕录制权限" : message
    }

    func removeDraftImage(_ id: String) {
        guard submissionStatus != .submitting else { return }
        guard let image = draftImages.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: image.fileURL)
        draftImages.removeAll { $0.id == id }
        invalidatePendingSubmission()
        persistDraftImages()
    }

    func retryFailedImages() {
        for index in draftImages.indices { draftImages[index].error = nil }
        persistDraftImages()
        submitDraft()
    }

    func refreshWorkspaces() {
        refreshWorkspaces(expectedGeneration: nil)
    }

    private func refreshWorkspaces(expectedGeneration: Int?) {
        let generation = expectedGeneration ?? connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(action: "workspaces", expectedGeneration: generation)
                guard self.connectionGeneration == generation else { return }
                applyWorkspaces(decodeWorkspaces(response["workspaces"]))
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    /// Install a workspace projection received from the bridge. Keeping the
    /// current send target requires it to still exist; otherwise the pet must
    /// ask for a new one before sending.
    func applyWorkspaces(_ decoded: [DSHPetWorkspace]) {
        workspaces = decoded
        if let selectedWorkspaceID, decoded.contains(where: { $0.id == selectedWorkspaceID }) {
            refreshBubbleDeck()
            return
        }
        if decoded.count == 1, let only = decoded.first {
            selectWorkspace(only.id)
        } else {
            selectedWorkspaceID = nil
            defaults.removeObject(forKey: Keys.workspaceID)
        }
        refreshBubbleDeck()
    }

    func selectWorkspace(_ id: String) {
        guard submissionStatus != .submitting else { return }
        guard workspaces.contains(where: { $0.id == id }) else { return }
        if selectedWorkspaceID != id {
            selectedWorkspaceID = id
            defaults.set(id, forKey: Keys.workspaceID)
            presentedActiveTaskIDs = nil
            clearSessionBinding()
            clearFocusedTask()
        }
    }

    /// Forget only DSHPet's current binding. Existing Harness sessions are
    /// never deleted or cancelled.
    func startNewSession() {
        guard submissionStatus != .submitting else { return }
        clearSessionBinding()
        clearFocusedTask()
        submissionStatus = .idle
        lastError = nil
        continuationWarning = nil
    }

    func focusTask(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if focusedTaskID != id { taskOpenGeneration &+= 1 }
        focusedTaskID = id
        markTaskRead(task)
        continuationWarning = nil
        taskOpenError = nil
        refreshTaskPreview(task, retryEmpty: !task.taskRunning)
    }

    /// Acknowledge a terminal result from its trailing status button. Unlike
    /// opening the detail card, this removes the card from the frozen active
    /// presentation immediately and drops it from the bubble deck.
    func acknowledgeTask(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }),
              DSHPetBubbleDeckBuilder.isTerminal(task) else { return }
        readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
        presentedActiveTaskIDs?.remove(task.id)
        if focusedTaskID == task.id { clearFocusedTask() }
        persistReadMarkers()
        rebuildBubbleDeck(now: now())
    }

    func clearFocusedTask() {
        taskOpenGeneration &+= 1
        focusedTaskID = nil
        continuationWarning = nil
        taskOpenError = nil
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        taskPreview = nil
        taskPreviewStatus = nil
    }

    /// Freeze the active-task panel's visible membership until it closes.
    func beginActiveTaskPresentation() {
        guard presentedActiveTaskIDs == nil else { return }
        presentedActiveTaskIDs = Set(activeTasks.map(\.id))
    }

    /// Release the presentation snapshot. Read terminal tasks then migrate to
    /// `recentTasks` on the next classification pass.
    func endActiveTaskPresentation() {
        presentedActiveTaskIDs = nil
    }

    /// Select a task as the input target. A non-empty draft blocks switching
    /// to another Session (or another task workspace) so a pending message
    /// cannot be sent elsewhere.
    @discardableResult
    func continueTask(_ task: DSHPetTaskSummary) -> Bool {
        guard submissionStatus != .submitting else { return false }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty
        if task.workspaceID != selectedWorkspaceID {
            guard workspaces.contains(where: { $0.id == task.workspaceID }) else {
                continuationWarning = "该任务的工作区已不可用"
                return false
            }
            if pendingRequestID != nil || submissionStatus == .unconfirmed {
                continuationWarning = "请先处理未确认的消息，再切换工作区"
                return false
            }
            if hasDraft {
                continuationWarning = "请先处理当前草稿，再切换会话"
                return false
            }
            selectWorkspace(task.workspaceID)
        }
        if hasDraft, sessionID != task.sessionID {
            continuationWarning = "请先处理当前草稿，再切换会话"
            return false
        }
        continuationWarning = nil
        focusedTaskID = task.id
        markTaskRead(task)
        if sessionID == task.sessionID { return true }

        sessionBindingGeneration &+= 1
        sessionCreationTask?.cancel()
        sessionCreationTask = nil
        dismissCandidates()
        sessionID = task.sessionID
        defaults.set(task.sessionID, forKey: Keys.sessionID)
        // Task summaries retain terminal results for card history. The pet must
        // wait for the live Session subscription instead of animating that
        // historical result indefinitely.
        sessionSnapshot = nil
        subscribe(to: task.sessionID)
        return true
    }

    /// Ask the Harness client half to focus this exact Session. The workspace
    /// membership check keeps a stale or forged task summary from selecting a
    /// Session outside the instance currently connected to DSH Pet.
    func openTaskSession(_ task: DSHPetTaskSummary) {
        taskOpenGeneration &+= 1
        let openGeneration = taskOpenGeneration
        taskOpenError = nil
        guard connection == .connected, capabilitiesValidated else {
            taskOpenError = DSHPetCommandError.unavailable.errorDescription
            lastError = taskOpenError
            return
        }
        guard let workspace = workspaces.first(where: { $0.id == task.workspaceID }),
              workspace.sessionIds.contains(task.sessionID) else {
            taskOpenError = "该任务已不属于当前 Harness 工作区"
            lastError = taskOpenError
            return
        }
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await request(
                    action: "openSession",
                    fields: ["workspaceId": task.workspaceID, "sessionId": task.sessionID],
                    timeout: 12,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation, taskOpenGeneration == openGeneration else { return }
                lastError = nil
                taskOpenError = nil
                focusTask(task.id)
            } catch {
                guard self.connectionGeneration == generation, taskOpenGeneration == openGeneration else { return }
                if case DSHPetCommandError.timedOut = error {
                    taskOpenError = "打开会话超时，请确认 Harness 客户端已加载"
                } else {
                    taskOpenError = errorMessage(error)
                }
                lastError = taskOpenError
            }
        }
    }

    func updateCandidates(kind: DSHPetCandidateKind, query: String) {
        candidateGeneration &+= 1
        let generation = candidateGeneration
        candidateTask?.cancel()
        candidateKind = kind
        candidates = []
        candidatesError = nil
        guard connection == .connected, capabilitiesValidated else {
            candidatesLoading = false
            candidatesError = "请先连接 Harness"
            return
        }
        guard kind == .file ? fileCandidatesAvailable : skillCandidatesAvailable else {
            candidatesLoading = false
            candidatesError = "当前 Harness 不支持此功能"
            return
        }
        guard let workspaceID = selectedWorkspaceID, hasWorkspace else {
            candidatesLoading = false
            candidatesError = "请先选择工作区"
            return
        }
        let connectionGeneration = self.connectionGeneration
        let bindingGeneration = sessionBindingGeneration
        candidatesLoading = true
        candidateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await ensureSession(expectedGeneration: connectionGeneration)
                guard !Task.isCancelled, candidateGeneration == generation,
                      sessionBindingGeneration == bindingGeneration,
                      selectedWorkspaceID == workspaceID, sessionID == session else { return }
                var fields: [String: Any] = ["workspaceId": workspaceID, "sessionId": session]
                if kind == .file { fields["query"] = query }
                let response = try await request(
                    action: kind == .file ? "fileCandidates" : "skillCandidates",
                    fields: fields, timeout: 12, expectedGeneration: connectionGeneration
                )
                guard !Task.isCancelled, candidateGeneration == generation,
                      sessionBindingGeneration == bindingGeneration,
                      selectedWorkspaceID == workspaceID, sessionID == session else { return }
                candidates = try Self.decodeCandidates(response, kind: kind, query: query)
                candidatesLoading = false
            } catch {
                guard !Task.isCancelled, candidateGeneration == generation,
                      self.connectionGeneration == connectionGeneration,
                      sessionBindingGeneration == bindingGeneration else { return }
                candidatesLoading = false
                candidatesError = errorMessage(error)
            }
        }
    }

    func dismissCandidates() {
        candidateGeneration &+= 1
        candidateTask?.cancel()
        candidateTask = nil
        candidateKind = nil
        candidates = []
        candidatesLoading = false
        candidatesError = nil
    }

    static func decodeCandidates(_ response: [String: Any], kind: DSHPetCandidateKind, query: String) throws -> [DSHPetInputCandidate] {
        if kind == .file {
            guard let rows = response["candidates"] as? [[String: Any]] else { throw DSHPetCommandError.malformed }
            return rows.compactMap { row in
                guard let path = row["path"] as? String,
                      let type = row["kind"] as? String,
                      type == "file" || type == "directory" else { return nil }
                let fullPath = path + (type == "directory" && !path.hasSuffix("/") ? "/" : "")
                let invalid = fullPath.unicodeScalars.contains {
                    $0.value == 34 || $0.value < 32 || (0x7f...0x9f).contains($0.value)
                }
                let quoted = fullPath.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
                let insert = quoted ? "@\"\(fullPath)\"" : "@\(fullPath)"
                return DSHPetInputCandidate(id: "\(type):\(path)", label: fullPath,
                    insertText: insert, detail: type == "directory" ? "目录" : "文件",
                    disabledReason: invalid ? "此路径无法用 Harness 引用格式表示" : nil)
            }
        }
        guard let rows = response["skills"] as? [[String: Any]] else { throw DSHPetCommandError.malformed }
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                  query.isEmpty || name.localizedCaseInsensitiveContains(query) else { return nil }
            return DSHPetInputCandidate(id: name, label: name, insertText: "/\(name) ",
                detail: row["description"] as? String,
                disabledReason: row["conflict"] as? Bool == false ? nil : "无法确认是否与 Harness 命令同名")
        }
    }

    private func refreshTaskPreview(_ task: DSHPetTaskSummary, retryEmpty: Bool = false) {
        previewGeneration &+= 1
        let generation = previewGeneration
        previewTask?.cancel()
        taskPreview = nil
        guard taskPreviewAvailable else {
            taskPreviewStatus = "当前 Harness 不支持回复预览"
            return
        }
        taskPreviewStatus = "正在加载回复预览…"
        let connectionGeneration = self.connectionGeneration
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for attempt in 0...(retryEmpty ? 2 : 0) {
                    if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
                    let response = try await request(action: "taskPreview", fields: [
                        "workspaceId": task.workspaceID, "sessionId": task.sessionID,
                    ], timeout: 12, expectedGeneration: connectionGeneration)
                    guard !Task.isCancelled, previewGeneration == generation,
                          focusedTaskID == task.id, self.connectionGeneration == connectionGeneration else { return }
                    guard let status = response["status"] as? String else { throw DSHPetCommandError.malformed }
                    switch status {
                    case "available":
                        guard let text = response["text"] as? String, !text.isEmpty else { throw DSHPetCommandError.malformed }
                        taskPreview = text
                        taskPreviewStatus = nil
                        return
                    case "empty":
                        taskPreviewStatus = "暂无回复预览"
                        if attempt < (retryEmpty ? 2 : 0) { continue }
                    case "unsupported": taskPreviewStatus = "当前 Harness 不支持回复预览"
                    case "migration-required": taskPreviewStatus = "会话需要迁移，暂无法显示回复预览"
                    default: throw DSHPetCommandError.malformed
                    }
                    return
                }
            } catch {
                guard !Task.isCancelled, previewGeneration == generation,
                      focusedTaskID == task.id, self.connectionGeneration == connectionGeneration else { return }
                taskPreviewStatus = "回复预览加载失败：\(errorMessage(error))"
            }
        }
    }

    func refreshTasks() {
        guard taskListAvailable else { return }
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(action: "tasks", timeout: 12, expectedGeneration: generation)
                guard self.connectionGeneration == generation else { return }
                applyTasks(response["tasks"])
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    func submitDraft() {
        guard submissionStatus != .submitting else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftImages.isEmpty else { return }
        guard selectedWorkspace != nil else {
            submissionStatus = .failed("请先选择工作区")
            return
        }
        if let busyMessage {
            submissionStatus = .failed(busyMessage)
            return
        }

        let signature = submissionSignature(text: text)
        let submittedImages = draftImages
        let submittedImageIDs = Set(submittedImages.map(\.id))
        let requestID: String
        if pendingRequestSignature == signature, let pendingRequestID {
            requestID = pendingRequestID
        } else {
            requestID = "dsh-pet-\(UUID().uuidString.lowercased())"
            pendingRequestID = requestID
            pendingRequestText = text
            pendingRequestSignature = signature
            defaults.set(requestID, forKey: Keys.requestID)
            defaults.set(text, forKey: Keys.requestText)
            defaults.set(signature, forKey: Keys.requestSignature)
        }

        submissionStatus = .submitting
        lastError = nil
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
                let encodedImages = try encodedDraftImages(submittedImages)
                guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
                let sessionID = try await ensureSession(expectedGeneration: generation)
                guard self.connectionGeneration == generation else { throw DSHPetCommandError.unavailable }
                let workspaceID = try requireWorkspaceID()
                let response = try await request(
                    action: "prompt",
                    fields: [
                        "workspaceId": workspaceID,
                        "sessionId": sessionID,
                        "requestId": requestID,
                        "text": text,
                        "images": encodedImages,
                    ],
                    timeout: 32,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation else { return }
                guard response["ok"] as? Bool != false,
                      response["accepted"] as? Bool == true else {
                    throw DSHPetCommandError.malformed
                }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                clearDraftImages(ids: submittedImageIDs)
                pendingRequestID = nil
                pendingRequestText = nil
                pendingRequestSignature = nil
                defaults.removeObject(forKey: Keys.requestID)
                defaults.removeObject(forKey: Keys.requestText)
                defaults.removeObject(forKey: Keys.requestSignature)
                submissionStatus = .submitted
                if let task = tasks.first(where: { $0.id == sessionID }) { markTaskRead(task) }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftImages.isEmpty {
                    onAccepted?()
                }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard self.connectionGeneration == generation else { return }
                if submissionStatus == .submitted { submissionStatus = .idle }
            } catch {
                guard self.connectionGeneration == generation else { return }
                if case DSHPetCommandError.timedOut = error {
                    submissionStatus = .unconfirmed
                } else {
                    submissionStatus = .failed(errorMessage(error))
                }
                lastError = errorMessage(error)
                if !draftImages.isEmpty {
                    let message = errorMessage(error)
                    for index in draftImages.indices where submittedImageIDs.contains(draftImages[index].id) {
                        draftImages[index].error = message
                    }
                    persistDraftImages()
                }
            }
        }
    }

    private func ensureSession(expectedGeneration: Int) async throws -> String {
        guard connectionGeneration == expectedGeneration else { throw DSHPetCommandError.unavailable }
        let workspaceID = try requireWorkspaceID()
        if let sessionCreationTask { return try await sessionCreationTask.value }
        let bindingGeneration = sessionBindingGeneration
        let creation = Task { @MainActor [weak self] in
            guard let self else { throw DSHPetCommandError.unavailable }
            return try await createBoundSession(workspaceID: workspaceID,
                expectedGeneration: expectedGeneration, bindingGeneration: bindingGeneration)
        }
        sessionCreationTask = creation
        defer {
            if sessionBindingGeneration == bindingGeneration { sessionCreationTask = nil }
        }
        return try await creation.value
    }

    private func createBoundSession(workspaceID: String, expectedGeneration: Int, bindingGeneration: Int) async throws -> String {
        let session = sessionID ?? "dsh-pet-session-\(UUID().uuidString.lowercased())"
        let response = try await request(
            action: "createSession",
            fields: ["workspaceId": workspaceID, "sessionId": session],
            timeout: 12,
            expectedGeneration: expectedGeneration
        )
        guard connectionGeneration == expectedGeneration, sessionBindingGeneration == bindingGeneration,
              selectedWorkspaceID == workspaceID else { throw DSHPetCommandError.unavailable }
        guard let returnedSession = response["sessionId"] as? String, !returnedSession.isEmpty else {
            throw DSHPetCommandError.malformed
        }
        sessionID = returnedSession
        defaults.set(returnedSession, forKey: Keys.sessionID)
        let subscribed = try await request(
            action: "subscribe",
            fields: ["sessionId": returnedSession],
            timeout: 8,
            expectedGeneration: expectedGeneration
        )
        guard connectionGeneration == expectedGeneration, sessionBindingGeneration == bindingGeneration,
              selectedWorkspaceID == workspaceID, sessionID == returnedSession else { throw DSHPetCommandError.unavailable }
        if let snapshot = decodeSnapshot(subscribed["snapshot"]),
           snapshotMatchesSelectedInstance(snapshot) {
            sessionSnapshot = snapshot
        }
        return returnedSession
    }

    private func requireWorkspaceID() throws -> String {
        guard let id = selectedWorkspaceID,
              workspaces.contains(where: { $0.id == id }) else {
            throw DSHPetCommandError.server(code: "workspace/not-selected", message: "请先选择工作区")
        }
        return id
    }

    private func clearSessionBinding() {
        sessionBindingGeneration &+= 1
        sessionCreationTask?.cancel()
        sessionCreationTask = nil
        dismissCandidates()
        sessionID = nil
        sessionSnapshot = nil
        pendingRequestID = nil
        pendingRequestText = nil
        pendingRequestSignature = nil
        defaults.removeObject(forKey: Keys.sessionID)
        defaults.removeObject(forKey: Keys.requestID)
        defaults.removeObject(forKey: Keys.requestText)
        defaults.removeObject(forKey: Keys.requestSignature)
        continuationWarning = nil
    }

    private func clearTargetCaches() {
        selectedWorkspaceID = nil
        defaults.removeObject(forKey: Keys.workspaceID)
        workspaces = []
        tasks = []
        readMarkers = [:]
        defaults.removeObject(forKey: Keys.taskReadMarkers)
        hasReceivedTaskBaseline = false
        presentedActiveTaskIDs = nil
        focusedTaskID = nil
        clearSessionBinding()
        submissionStatus = .idle
        lastError = nil
        resetBubbleDeckState()
    }

    private func invalidateConnection(clearPersistedPending: Bool) {
        connectionGeneration &+= 1
        sessionBindingGeneration &+= 1
        sessionCreationTask?.cancel()
        sessionCreationTask = nil
        dismissCandidates()
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        taskPreview = nil
        taskPreviewStatus = focusedTaskID == nil ? nil : "Harness 连接已断开"
        connectionHandle?.cancel()
        connectionHandle = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        queuedPayloads.removeAll(keepingCapacity: false)
        receiveBuffer.removeAll(keepingCapacity: false)
        failPending(with: DSHPetCommandError.unavailable)
        if clearPersistedPending {
            pendingRequestID = nil
            pendingRequestText = nil
            pendingRequestSignature = nil
            defaults.removeObject(forKey: Keys.requestID)
            defaults.removeObject(forKey: Keys.requestText)
            defaults.removeObject(forKey: Keys.requestSignature)
        }
        connection = .disconnected
    }

    private func resetCapabilityState() {
        capabilitiesValidated = false
        capabilitiesAvailable = false
        taskListAvailable = false
        imageAttachmentsAvailable = false
        fileCandidatesAvailable = false
        skillCandidatesAvailable = false
        taskPreviewAvailable = false
        imageLimits = nil
        dismissCandidates()
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        if focusedTaskID != nil {
            taskPreview = nil
            taskPreviewStatus = "Harness 连接已断开"
        }
        resetBubbleDeckState()
    }

    private func connect() {
        guard started, sourceEnabled, connectionHandle == nil else { return }
        connection = .connecting
        receiveBuffer.removeAll(keepingCapacity: true)
        let generation = connectionGeneration
        let handle = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connectionHandle = handle
        handle.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionGeneration == generation,
                      self.connectionHandle === handle else { return }
                switch state {
                case .ready:
                    connection = .connected
                    resetCapabilityState()
                    refreshCapabilitiesAndWorkspaces()
                case .waiting:
                    // A Unix socket that is not available yet enters
                    // NWConnection.waiting rather than failed. Clear the
                    // handle so the retry loop can reconnect after Harness
                    // starts and creates the command socket.
                    connectionHandle = nil
                    connection = .disconnected
                    resetCapabilityState()
                    failPending(with: DSHPetCommandError.unavailable)
                    handle.cancel()
                    scheduleReconnect()
                case .failed, .cancelled:
                    connectionHandle = nil
                    connection = .disconnected
                    resetCapabilityState()
                    failPending(with: DSHPetCommandError.unavailable)
                    scheduleReconnect()
                default:
                    break
                }
            }
        }
        handle.start(queue: queue)
        receiveNext(on: handle)
    }

    private func receiveNext(on handle: NWConnection) {
        handle.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionHandle === handle else { return }
                if let data { consume(data) }
                if isComplete {
                    connectionHandle = nil
                    connection = .disconnected
                    resetCapabilityState()
                    failPending(with: DSHPetCommandError.unavailable)
                    scheduleReconnect()
                } else if connectionHandle != nil {
                    receiveNext(on: handle)
                }
            }
        }
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 10) {
            let line = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["event"] as? String == "status" {
                if let sessionID = object["sessionId"] as? String,
                   sessionID == self.sessionID,
                   let snapshot = decodeSnapshot(object["snapshot"]),
                   snapshotMatchesSelectedInstance(snapshot) {
                    sessionSnapshot = snapshot
                }
                continue
            }
            if object["event"] as? String == "tasks" {
                applyTasks(object["tasks"])
                continue
            }
            if object["event"] as? String == "taskPreviewChanged" {
                if let task = focusedTask, object["sessionId"] as? String == task.sessionID {
                    refreshTaskPreview(task)
                }
                continue
            }
            guard let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
            if let ok = object["ok"] as? Bool, !ok {
                let error = object["error"] as? [String: Any]
                continuation(.failure(DSHPetCommandError.server(
                    code: error?["code"] as? String ?? "command-failed",
                    message: error?["message"] as? String ?? "DSH Pet 桥接插件拒绝了请求"
                )))
            } else {
                continuation(.success(object))
            }
        }
    }

    private func request(
        action: String,
        fields: [String: Any] = [:],
        timeout: TimeInterval = 8,
        expectedGeneration: Int? = nil
    ) async throws -> [String: Any] {
        guard started else { throw DSHPetCommandError.unavailable }
        if let expectedGeneration, expectedGeneration != connectionGeneration {
            throw DSHPetCommandError.unavailable
        }
        if action != "capabilities" && !capabilitiesValidated {
            throw DSHPetCommandError.unavailable
        }
        connect()
        let requestGeneration = connectionGeneration
        let id = UUID().uuidString.lowercased()
        var object: [String: Any] = ["id": id, "action": action]
        for (key, value) in fields { object[key] = value }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { result in continuation.resume(with: result) }
            queuedPayloads.append(data)
            if connection == .connected { flushQueuedPayloads() }
            Task { @MainActor [weak self] in
                let delay = UInt64(max(0.5, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.connectionGeneration == requestGeneration else { return }
                self.timeOut(id)
            }
        }
    }

    private func refreshCapabilitiesAndWorkspaces() {
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(
                    action: "capabilities",
                    timeout: 5,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation else { return }
                guard response["protocolVersion"] as? Int == 1,
                      response["commandSocket"] as? Bool == true,
                      validateCapabilitiesInstance(response["instance"]) else {
                    throw DSHPetCommandError.malformed
                }
                capabilitiesValidated = true
                capabilitiesAvailable = true
                let supports = response["supports"] as? [String] ?? []
                taskListAvailable = supports.contains("tasks") && supports.contains("subscribeTasks")
                imageAttachmentsAvailable = supports.contains("imageAttachments")
                fileCandidatesAvailable = supports.contains("fileCandidates")
                skillCandidatesAvailable = supports.contains("skillCandidates")
                taskPreviewAvailable = supports.contains("taskPreview")
                imageLimits = decodeImageLimits(response["attachmentLimits"])
                if taskListAvailable {
                    subscribeTasks(expectedGeneration: generation)
                } else {
                    tasks = []
                    refreshBubbleDeck()
                }
                if let sessionID { subscribe(to: sessionID, expectedGeneration: generation) }
                refreshWorkspaces(expectedGeneration: generation)
                if let task = focusedTask { refreshTaskPreview(task) }
            } catch {
                guard self.connectionGeneration == generation else { return }
                capabilitiesAvailable = false
                taskListAvailable = false
                imageAttachmentsAvailable = false
                imageLimits = nil
                resetBubbleDeckState()
                record(error)
            }
        }
    }

    private func flushQueuedPayloads() {
        guard let connectionHandle, connection == .connected else { return }
        let payloads = queuedPayloads
        queuedPayloads.removeAll(keepingCapacity: true)
        for payload in payloads {
            connectionHandle.send(content: payload + Data([10]), completion: .contentProcessed { _ in })
        }
    }

    private func timeOut(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation(.failure(DSHPetCommandError.timedOut))
    }

    private func scheduleReconnect() {
        guard started, reconnectTask == nil else { return }
        let generation = connectionGeneration
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.started,
                  self.connectionGeneration == generation else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation(.failure(error)) }
    }

    private func record(_ error: Error) {
        lastError = errorMessage(error)
        if case DSHPetCommandError.unavailable = error { connection = .disconnected }
    }

    private func decodeWorkspaces(_ value: Any?) -> [DSHPetWorkspace] {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([DSHPetWorkspace].self, from: data) else { return [] }
        return decoded
    }

    private func decodeSnapshot(_ value: Any?) -> MoodBridgeSnapshot? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MoodBridgeSnapshot.self, from: data)
    }

    private func snapshotMatchesSelectedInstance(_ snapshot: MoodBridgeSnapshot) -> Bool {
        guard let expectedInstanceID else { return true }
        return snapshot.instanceId == expectedInstanceID
    }

    private func validateCapabilitiesInstance(_ value: Any?) -> Bool {
        guard let targetInstance else {
            // Legacy bridges predate instance metadata. A discovered
            // descriptor must never be silently accepted as legacy, because
            // that would make an HTTP/socket fallback cross origins.
            return value == nil || allowLegacy
        }
        guard let descriptor = value as? [String: Any],
              descriptor["instanceId"] as? String == targetInstance.instanceId,
              descriptor["statusSocketPath"] as? String == targetInstance.statusSocketPath,
              descriptor["commandSocketPath"] as? String == targetInstance.commandSocketPath else {
            lastError = "Harness 来源身份校验失败，已停止发送"
            return false
        }
        return true
    }

    private func decodeImageLimits(_ value: Any?) -> DSHPetImageLimits? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(DSHPetImageLimits.self, from: data)
    }

    private func addDraftImage(data: Data, mediaType: String, name: String) {
        do {
            let directory = try draftImageDirectory()
            let url = directory.appendingPathComponent("draft-\(UUID().uuidString.lowercased()).png")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            addDraftImageFile(url: url, data: data, mediaType: mediaType, name: name)
        } catch {
            lastError = errorMessage(error)
        }
    }

    private func addDraftImageFile(url: URL, data: Data, mediaType: String, name: String) {
        if let limits = imageLimits {
            guard draftImages.count < limits.maxImagesPerMessage else {
                try? FileManager.default.removeItem(at: url)
                lastError = "图片数量超过 Harness 限制（最多 \(limits.maxImagesPerMessage) 张）"
                return
            }
            guard data.count <= limits.maxImageBytes else {
                try? FileManager.default.removeItem(at: url)
                lastError = "图片超过 Harness 单张大小限制（\(Self.byteLabel(limits.maxImageBytes))）"
                return
            }
            guard draftImages.reduce(0, { $0 + $1.bytes }) + data.count <= limits.maxMessageImageBytes else {
                try? FileManager.default.removeItem(at: url)
                lastError = "图片总大小超过 Harness 限制（\(Self.byteLabel(limits.maxMessageImageBytes))）"
                return
            }
        }
        draftImages.append(DSHPetDraftImage(
            id: UUID().uuidString.lowercased(),
            path: url.path,
            mediaType: mediaType,
            name: name,
            bytes: data.count,
            error: nil
        ))
        invalidatePendingSubmission()
        persistDraftImages()
        lastError = nil
    }

    private func encodedDraftImages(_ images: [DSHPetDraftImage]) throws -> [[String: Any]] {
        try images.map { image in
            let data = try Data(contentsOf: image.fileURL, options: [.mappedIfSafe])
            return [
                "id": image.id,
                "mediaType": image.mediaType,
                "name": image.name,
                "data": data.base64EncodedString(),
            ]
        }
    }

    private func draftImageDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("DSH Pet/PrivateDraftImages", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func clearDraftImages(ids: Set<String>) {
        for image in draftImages where ids.contains(image.id) {
            try? FileManager.default.removeItem(at: image.fileURL)
        }
        draftImages.removeAll { ids.contains($0.id) }
        persistDraftImages()
    }

    private func persistDraftImages() {
        if let data = try? JSONEncoder().encode(draftImages) {
            defaults.set(data, forKey: Keys.draftImages)
        }
    }

    private func invalidatePendingSubmission() {
        pendingRequestID = nil
        pendingRequestText = nil
        pendingRequestSignature = nil
        defaults.removeObject(forKey: Keys.requestID)
        defaults.removeObject(forKey: Keys.requestText)
        defaults.removeObject(forKey: Keys.requestSignature)
    }

    private func submissionSignature(text: String) -> String {
        ([text] + draftImages.map { "\($0.id):\($0.bytes)" }).joined(separator: "|")
    }

    private static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func subscribeTasks(expectedGeneration: Int? = nil) {
        let generation = expectedGeneration ?? connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(
                    action: "subscribeTasks",
                    timeout: 12,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation else { return }
                applyTasks(response["tasks"])
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    private func subscribe(to sessionID: String, expectedGeneration: Int? = nil) {
        let generation = expectedGeneration ?? connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await request(
                    action: "subscribe",
                    fields: ["sessionId": sessionID],
                    timeout: 8,
                    expectedGeneration: generation
                )
                guard self.connectionGeneration == generation,
                      self.sessionID == sessionID else { return }
                if let snapshot = decodeSnapshot(response["snapshot"]),
                   snapshotMatchesSelectedInstance(snapshot) {
                    self.sessionSnapshot = snapshot
                }
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    private func applyTasks(_ value: Any?) {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([DSHPetTaskSummary].self, from: data) else { return }

        if !hasReceivedTaskBaseline {
            // The first baseline is historical context, not a burst of unread
            // reminders. Retain existing markers so a result that arrived while
            // the App was closed can still be recognized after reconnect.
            for task in decoded where readMarkers[task.id] == nil {
                readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
            }
            hasReceivedTaskBaseline = true
            persistReadMarkers()
        }
        applyTaskSummaries(decoded)
    }

    /// Task-card history and the pet's live animation are separate state
    /// channels. In particular, a retained done/failed card must never replace
    /// the live Session snapshot merely because the card list refreshed.
    func applyTaskSummaries(_ decoded: [DSHPetTaskSummary], establishesBaseline: Bool = false) {
        if establishesBaseline {
            for task in decoded {
                readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
            }
            hasReceivedTaskBaseline = true
            persistReadMarkers()
        }
        let previousFocused = focusedTask
        let current = now()
        observeTaskTransitions(decoded, now: current)
        tasks = decoded
        rebuildBubbleDeck(now: current)
        if let previousFocused,
           let currentFocused = focusedTask,
           previousFocused.taskRunning && !currentFocused.taskRunning {
            refreshTaskPreview(currentFocused, retryEmpty: true)
        }
    }

    func isTaskUnread(_ task: DSHPetTaskSummary) -> Bool {
        guard hasReceivedTaskBaseline else { return false }
        guard let marker = readMarkers[task.id] else { return true }
        return marker.updatedAt != task.updatedAt || marker.mood != task.mood
    }

    private func markTaskRead(_ task: DSHPetTaskSummary) {
        if presentedActiveTaskIDs != nil, isTaskActive(task) {
            presentedActiveTaskIDs?.insert(task.id)
        }
        readMarkers[task.id] = TaskReadMarker(updatedAt: task.updatedAt, mood: task.mood)
        persistReadMarkers()
        rebuildBubbleDeck(now: now())
    }

    private func persistReadMarkers() {
        guard let data = try? JSONEncoder().encode(readMarkers) else { return }
        defaults.set(data, forKey: Keys.taskReadMarkers)
    }

    /// Rebuild the presentation deck from the current task list. Exposed to the
    /// hold timer (and tests) because terminal results expire without another
    /// Harness event arriving.
    func refreshBubbleDeck() {
        rebuildBubbleDeck(now: now())
    }

    private func resetBubbleDeckState() {
        bubbleHoldTask?.cancel()
        bubbleHoldTask = nil
        bubbleOrder = []
        terminalHoldUntil = [:]
        lastBubbleObservation = [:]
        if bubbleDeck != .empty { bubbleDeck = .empty }
    }

    private func observeTaskTransitions(_ decoded: [DSHPetTaskSummary], now: TimeInterval) {
        var next: [String: BubbleObservation] = [:]
        for task in decoded {
            let terminal = DSHPetBubbleDeckBuilder.isTerminal(task)
            let previous = lastBubbleObservation[task.sessionID]
            if terminal {
                let changed = previous.map {
                    !$0.terminal || $0.updatedAt != task.updatedAt || $0.mood != task.mood
                } ?? false
                if changed {
                    terminalHoldUntil[task.sessionID] = now + DSHPetBubbleDeckBuilder.holdDuration(for: task)
                }
            } else {
                terminalHoldUntil.removeValue(forKey: task.sessionID)
            }
            next[task.sessionID] = BubbleObservation(
                mood: task.mood,
                updatedAt: task.updatedAt,
                terminal: terminal
            )
        }
        lastBubbleObservation = next
        terminalHoldUntil = terminalHoldUntil.filter { next[$0.key] != nil }
    }

    private func rebuildBubbleDeck(now: TimeInterval) {
        let attention = tasks.filter { task in
            DSHPetBubbleDeckBuilder.isAttention(
                task: task,
                isUnread: isTaskUnread(task),
                holdUntil: terminalHoldUntil[task.sessionID] ?? 0,
                now: now
            )
        }
        let attentionIDs = attention.map { $0.sessionID }
        bubbleOrder = bubbleOrder.filter { attentionIDs.contains($0) }
        for id in attentionIDs where !bubbleOrder.contains(id) {
            bubbleOrder.append(id)
        }

        let inputs = bubbleOrder.compactMap { id in
            tasks.first { $0.sessionID == id }.map { task in
                DSHPetBubbleTaskInput(
                    task: task,
                    workspaceTitle: workspaceTitle(for: task),
                    isUnread: isTaskUnread(task),
                    holdUntil: terminalHoldUntil[id] ?? 0
                )
            }
        }
        let deck = DSHPetBubbleDeckBuilder.build(inputs: inputs, now: now)
        if bubbleDeck != deck { bubbleDeck = deck }
        scheduleBubbleHoldRefresh(now: now)
    }

    private func scheduleBubbleHoldRefresh(now: TimeInterval) {
        bubbleHoldTask?.cancel()
        bubbleHoldTask = nil
        let pending = terminalHoldUntil.values.filter { $0 > now }
        guard let next = pending.min() else { return }
        let delay = max(0.05, next - now)
        bubbleHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshBubbleDeck()
        }
    }

    private func taskRank(_ task: DSHPetTaskSummary) -> Int {
        if task.waitingForUser { return 0 }
        if isTaskUnread(task) && task.failed { return 1 }
        if isTaskUnread(task) && task.completed { return 2 }
        if task.taskRunning || task.running { return 3 }
        return 4
    }

    private func isTaskActive(_ task: DSHPetTaskSummary) -> Bool {
        task.waitingForUser
            || task.taskRunning
            || task.running
            || (isTaskUnread(task) && (task.completed || task.failed))
    }

    private func taskPrecedes(_ left: DSHPetTaskSummary, _ right: DSHPetTaskSummary) -> Bool {
        let leftRank = taskRank(left)
        let rightRank = taskRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        return recentTaskPrecedes(left, right)
    }

    /// Presentation membership preserves terminal cards after they are read;
    /// their visual priority must remain failure/completion instead of falling
    /// behind running work while the same panel is still open.
    private func activeTaskPrecedes(_ left: DSHPetTaskSummary, _ right: DSHPetTaskSummary) -> Bool {
        let leftRank = activeTaskRank(left)
        let rightRank = activeTaskRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        return recentTaskPrecedes(left, right)
    }

    private func activeTaskRank(_ task: DSHPetTaskSummary) -> Int {
        if task.waitingForUser { return 0 }
        if task.failed { return 1 }
        if task.completed { return 2 }
        if task.taskRunning || task.running { return 3 }
        return 4
    }

    private func recentTaskPrecedes(_ left: DSHPetTaskSummary, _ right: DSHPetTaskSummary) -> Bool {
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        let titleOrder = left.title.localizedStandardCompare(right.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return left.id < right.id
    }
}

private func errorMessage(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let message = localized.errorDescription { return message }
    return error.localizedDescription
}
