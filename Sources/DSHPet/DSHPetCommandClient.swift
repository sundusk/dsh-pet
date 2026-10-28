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
    @Published private(set) var selectedWorkspaceID: String?
    @Published private(set) var sessionID: String?
    @Published private(set) var sessionSnapshot: MoodBridgeSnapshot?
    @Published private(set) var focusedTaskID: String?
    @Published private(set) var submissionStatus: DSHPetSubmissionStatus = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var continuationWarning: String?
    @Published private(set) var draftImages: [DSHPetDraftImage] = []
    @Published var draft: String {
        didSet { defaults.set(draft, forKey: Keys.draft) }
    }

    var onAccepted: (() -> Void)?

    var showsComposerStatusLine: Bool {
        connection != .connected
            || !capabilitiesAvailable
            || workspaces.isEmpty
            || submissionStatus.label != nil
            || lastError != nil
    }

    private enum Keys {
        static let workspaceID = "dsh-pet.command.workspaceID"
        static let sessionID = "dsh-pet.command.sessionID"
        static let draft = "dsh-pet.command.draft"
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
    private var readMarkers: [String: TaskReadMarker] = [:]
    private var hasReceivedTaskBaseline = false
    private var presentedActiveTaskIDs: Set<String>?

    init(defaults: UserDefaults = .standard, socketPath: String = DSHPetCommandClient.defaultSocketPath) {
        self.defaults = defaults
        self.legacySocketPath = socketPath
        self.socketPath = socketPath
        persistedTargetBindingKey = defaults.string(forKey: Keys.targetBindingKey)
        selectedWorkspaceID = defaults.string(forKey: Keys.workspaceID)
        sessionID = defaults.string(forKey: Keys.sessionID)
        draft = defaults.string(forKey: Keys.draft) ?? ""
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

    var currentWorkspaceTasks: [DSHPetTaskSummary] {
        guard let selectedWorkspaceID else { return [] }
        return tasks.filter { $0.workspaceID == selectedWorkspaceID }
    }

    /// Tasks that still need attention in the selected workspace. While the
    /// active-task panel is open, its opening snapshot remains visible so a
    /// result does not disappear immediately after the user reads it.
    var activeTasks: [DSHPetTaskSummary] {
        currentWorkspaceTasks
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
            currentWorkspaceTasks
                .filter { !$0.blank && !activeTaskIDs.contains($0.id) }
                .sorted(by: recentTaskPrecedes)
                .prefix(5)
        )
    }

    /// Task-center order: waiting for a user action, unread failures, unread
    /// completions, running work, then the remaining recent Sessions.
    var sortedTasks: [DSHPetTaskSummary] {
        currentWorkspaceTasks.sorted(by: taskPrecedes)
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
                let decoded = decodeWorkspaces(response["workspaces"])
                workspaces = decoded
                if let selectedWorkspaceID, decoded.contains(where: { $0.id == selectedWorkspaceID }) {
                    return
                }
                if decoded.count == 1, let only = decoded.first {
                    selectWorkspace(only.id)
                } else {
                    selectedWorkspaceID = nil
                    defaults.removeObject(forKey: Keys.workspaceID)
                }
            } catch {
                guard self.connectionGeneration == generation else { return }
                record(error)
            }
        }
    }

    func selectWorkspace(_ id: String) {
        guard submissionStatus != .submitting else { return }
        guard workspaces.contains(where: { $0.id == id }) else { return }
        if selectedWorkspaceID != id {
            selectedWorkspaceID = id
            defaults.set(id, forKey: Keys.workspaceID)
            presentedActiveTaskIDs = nil
            clearSessionBinding()
            focusedTaskID = nil
        }
    }

    /// Forget only DSHPet's current binding. Existing Harness sessions are
    /// never deleted or cancelled.
    func startNewSession() {
        guard submissionStatus != .submitting else { return }
        clearSessionBinding()
        focusedTaskID = nil
        submissionStatus = .idle
        lastError = nil
        continuationWarning = nil
    }

    func focusTask(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        focusedTaskID = id
        markTaskRead(task)
        continuationWarning = nil
    }

    func clearFocusedTask() {
        focusedTaskID = nil
        continuationWarning = nil
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
    /// to another Session so a pending message cannot be sent elsewhere.
    @discardableResult
    func continueTask(_ task: DSHPetTaskSummary) -> Bool {
        guard submissionStatus != .submitting else { return false }
        guard task.workspaceID == selectedWorkspaceID else { return false }
        if (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty),
           sessionID != task.sessionID {
            continuationWarning = "请先处理当前草稿，再切换会话"
            return false
        }
        continuationWarning = nil
        focusedTaskID = task.id
        markTaskRead(task)
        if sessionID == task.sessionID { return true }

        sessionID = task.sessionID
        defaults.set(task.sessionID, forKey: Keys.sessionID)
        // Task summaries retain terminal results for card history. The pet must
        // wait for the live Session subscription instead of animating that
        // historical result indefinitely.
        sessionSnapshot = nil
        subscribe(to: task.sessionID)
        return true
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
        let session = sessionID ?? "dsh-pet-session-\(UUID().uuidString.lowercased())"
        let response = try await request(
            action: "createSession",
            fields: ["workspaceId": workspaceID, "sessionId": session],
            timeout: 12,
            expectedGeneration: expectedGeneration
        )
        guard connectionGeneration == expectedGeneration else { throw DSHPetCommandError.unavailable }
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
        guard connectionGeneration == expectedGeneration else { throw DSHPetCommandError.unavailable }
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
    }

    private func invalidateConnection(clearPersistedPending: Bool) {
        connectionGeneration &+= 1
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
        imageLimits = nil
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
                imageLimits = decodeImageLimits(response["attachmentLimits"])
                if taskListAvailable { subscribeTasks(expectedGeneration: generation) } else { tasks = [] }
                if let sessionID { subscribe(to: sessionID, expectedGeneration: generation) }
                refreshWorkspaces(expectedGeneration: generation)
            } catch {
                guard self.connectionGeneration == generation else { return }
                capabilitiesAvailable = false
                taskListAvailable = false
                imageAttachmentsAvailable = false
                imageLimits = nil
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
        tasks = decoded
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
    }

    private func persistReadMarkers() {
        guard let data = try? JSONEncoder().encode(readMarkers) else { return }
        defaults.set(data, forKey: Keys.taskReadMarkers)
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
