import Darwin
import Foundation
import XCTest
@testable import DSHPet

final class CommandSocketHandshakeTests: XCTestCase {
    @MainActor
    func testDisconnectDuringPromptRemainsUnconfirmedWithoutAutomaticResend() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, disconnectOnPrompt: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        defer { client.stop() }
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(client.selectedWorkspaceID)
        client.draft = "断线时保留的消息"
        client.submitDraft()
        await server.waitForAction("prompt")
        for _ in 0..<100 where client.submissionStatus != .unconfirmed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.submissionStatus, .unconfirmed)
        XCTAssertEqual(client.draft, "断线时保留的消息")
        await server.waitForActionCount("capabilities", atLeast: 2)
        XCTAssertGreaterThanOrEqual(server.actionCount("capabilities"), 2)
        XCTAssertEqual(server.actionCount("prompt"), 1)
    }

    @MainActor
    func testPreviewUpdatesOnlyForFocusedSession() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, previewSupport: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        await server.waitForAction("workspaces")
        let task = DSHPetTaskSummary(sessionID: "focused", workspaceID: "workspace", title: "测试", cwd: nil,
            updatedAt: 1, running: false, blank: false, state: .completed, mood: "done", taskRunning: false,
            waitingForUser: false, failed: false, completed: true, tool: nil, message: nil)
        client.applyTaskSummaries([task])
        client.focusTask(task.id)
        await server.waitForAction("taskPreview")
        server.sendEvent(["event": "taskPreviewChanged", "sessionId": "other"])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.actionCount("taskPreview"), 1)
        server.sendEvent(["event": "taskPreviewChanged", "sessionId": "focused"])
        await server.waitForActionCount("taskPreview", atLeast: 2)
        XCTAssertEqual(server.actionCount("taskPreview"), 2)
        client.stop()
    }

    @MainActor
    func testCandidateQueriesSharePendingSessionAndIgnoreOldQuery() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, delayCreateSession: true, candidateSupport: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        client.updateCandidates(kind: .file, query: "old")
        await server.waitForAction("createSession")
        client.updateCandidates(kind: .file, query: "new")
        server.releaseCreateSession()
        await server.waitForAction("fileCandidates")
        for _ in 0..<100 where client.candidatesLoading {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(server.actionCount("createSession"), 1)
        XCTAssertEqual(client.candidates.map(\.insertText), ["@new"])
        client.stop()
    }

    @MainActor
    func testNewSessionInvalidatesPendingCandidateSessionCreation() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, delayCreateSession: true, candidateSupport: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)
        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<100 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        client.updateCandidates(kind: .file, query: "old")
        await server.waitForAction("createSession")
        client.startNewSession()
        server.releaseCreateSession()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(client.sessionID)
        XCTAssertFalse(server.containsAction("subscribe"))
        XCTAssertFalse(server.containsAction("fileCandidates"))
        XCTAssertNil(client.candidateKind)
        client.stop()
    }
    @MainActor
    func testMismatchedCapabilitiesNeverUnlockBusinessRequests() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let wrong = makeInstance(id: "other", status: "/tmp/other-status.sock", command: "/tmp/other-command.sock")
        let server = try CommandSocketServer(path: path, instance: wrong)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)

        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        await server.waitForAction("capabilities")
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(client.capabilitiesAvailable)
        client.refreshWorkspaces()
        client.draft = "不会发送"
        client.submitDraft()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(server.containsAction("workspaces"))
        XCTAssertFalse(server.containsAction("createSession"))
        XCTAssertFalse(server.containsAction("prompt"))
        client.stop()
    }

    @MainActor
    func testMatchingCapabilitiesUnlocksWorkspacesOnSelectedSocket() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)

        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<20 where client.workspaces.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.capabilitiesAvailable)
        XCTAssertEqual(client.workspaces.map(\.id), ["workspace"])
        client.stop()
    }

    @MainActor
    func testSameBindingCannotJumpToConcurrentProcessWithDraft() {
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: "/tmp/unused.sock")
        let first = makeInstance(id: "first", status: "/tmp/first-status.sock", command: "/tmp/first-command.sock", pid: Int32(getpid()))
        let second = makeInstance(id: "second", status: "/tmp/second-status.sock", command: "/tmp/second-command.sock", pid: Int32(getpid()))
        XCTAssertTrue(client.configure(instance: first, allowLegacy: false))
        client.draft = "保留在第一个目标"

        XCTAssertFalse(client.configure(instance: second, allowLegacy: false))
        XCTAssertEqual(client.draft, "保留在第一个目标")
    }

    @MainActor
    func testSubmitTransactionStopsBeforeSubscribeAfterSameSourceRestart() async throws {
        let path = "/tmp/dsh-pet-command-\(UUID().uuidString.prefix(8)).sock"
        let instance = makeInstance(id: "selected", status: "/tmp/selected-status.sock", command: path)
        let server = try CommandSocketServer(path: path, instance: instance, delayCreateSession: true)
        defer { server.stop() }
        let suite = "CommandSocketHandshakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DSHPetCommandClient(defaults: defaults, socketPath: path)

        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        client.start()
        await server.waitForAction("workspaces")
        for _ in 0..<20 where client.selectedWorkspaceID == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        client.draft = "等待来源切换"
        client.submitDraft()
        await server.waitForAction("createSession")

        // Reconnect the same selected target while createSession is awaiting a
        // response. The old task must not subscribe or prompt on the new socket.
        XCTAssertTrue(client.configure(instance: nil, allowLegacy: false))
        XCTAssertEqual(client.submissionStatus, .failed("消息尚未发送，请在连接恢复后重试"))
        XCTAssertEqual(client.draft, "等待来源切换")
        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        server.releaseCreateSession()
        await server.waitForActionCount("capabilities", atLeast: 2)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(server.containsAction("subscribe"))
        XCTAssertFalse(server.containsAction("prompt"))
        client.stop()
    }

    private func makeInstance(
        id: String,
        status: String,
        command: String,
        pid: Int32 = 999_999
    ) -> HarnessInstance {
        HarnessInstance(
            protocolVersion: 1,
            instanceId: id,
            kind: .desktop,
            profile: "desktop",
            pid: pid,
            startedAt: 1,
            webURL: nil,
            statusSocketPath: status,
            commandSocketPath: command,
            targetId: "profile-desktop"
        )
    }

}

private final class CommandSocketServer: @unchecked Sendable {
    private let listener: Int32
    private let path: String
    private let instance: HarnessInstance
    private let delayCreateSession: Bool
    private let candidateSupport: Bool
    private let previewSupport: Bool
    private let disconnectOnPrompt: Bool
    private let createSessionRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var clients: [Int32] = []
    private(set) var actions: [String] = []

    init(path: String, instance: HarnessInstance, delayCreateSession: Bool = false, candidateSupport: Bool = false, previewSupport: Bool = false, disconnectOnPrompt: Bool = false) throws {
        self.path = path
        self.instance = instance
        self.delayCreateSession = delayCreateSession
        self.candidateSupport = candidateSupport
        self.previewSupport = previewSupport
        self.disconnectOnPrompt = disconnectOnPrompt
        listener = try Self.makeListener(path: path)
        DispatchQueue.global().async { [weak self] in self?.acceptLoop() }
    }

    func waitForAction(_ action: String) async {
        for _ in 0..<100 {
            if lock.withLock({ actions.contains(action) }) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func containsAction(_ action: String) -> Bool {
        lock.withLock { actions.contains(action) }
    }

    func actionCount(_ action: String) -> Int {
        lock.withLock { actions.filter { $0 == action }.count }
    }

    func waitForActionCount(_ action: String, atLeast count: Int) async {
        for _ in 0..<100 {
            if lock.withLock({ actions.filter { $0 == action }.count >= count }) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func releaseCreateSession() {
        createSessionRelease.signal()
    }

    func sendEvent(_ event: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: event) else { return }
        data.append(10)
        lock.withLock {
            for client in clients {
                _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            }
        }
    }

    func stop() {
        Darwin.close(listener)
        lock.withLock {
            for client in clients { Darwin.close(client) }
            clients.removeAll()
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            lock.withLock { clients.append(client) }
            DispatchQueue.global().async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] as? String,
                      let action = request["action"] as? String else { continue }
                lock.withLock { actions.append(action) }
                if action == "prompt", disconnectOnPrompt {
                    Darwin.shutdown(client, SHUT_RDWR)
                    return
                }
                let response: [String: Any]
                if action == "capabilities" {
                    response = [
                        "id": id, "ok": true, "protocolVersion": 1,
                        "commandSocket": true, "supports": ["workspaces"]
                            + (candidateSupport ? ["fileCandidates"] : []) + (previewSupport ? ["taskPreview"] : []),
                        "instance": [
                            "protocolVersion": instance.protocolVersion,
                            "instanceId": instance.instanceId,
                            "kind": instance.kind.rawValue,
                            "profile": instance.profile as Any,
                            "pid": instance.pid,
                            "startedAt": instance.startedAt,
                            "statusSocketPath": instance.statusSocketPath,
                            "commandSocketPath": instance.commandSocketPath,
                        ],
                    ]
                } else if action == "workspaces" {
                    response = [
                        "id": id, "ok": true,
                        "workspaces": [[
                            "id": "workspace", "title": "测试工作区", "path": "/tmp",
                            "status": "ready", "sessionIds": [],
                        ]],
                    ]
                } else {
                    if action == "createSession", delayCreateSession {
                        createSessionRelease.wait()
                    }
                    if action == "createSession" {
                        response = ["id": id, "ok": true, "sessionId": request["sessionId"] ?? ""]
                    } else if action == "fileCandidates" {
                        response = ["id": id, "ok": true, "candidates": [["path": request["query"] ?? "", "kind": "file"]]]
                    } else if action == "taskPreview" {
                        response = ["id": id, "ok": true, "status": "available", "text": "测试回复"]
                    } else {
                        response = ["id": id, "ok": true]
                    }
                }
                guard var data = try? JSONSerialization.data(withJSONObject: response) else { continue }
                data.append(10)
                _ = data.withUnsafeBytes { raw in
                    Darwin.write(client, raw.baseAddress, raw.count)
                }
            }
        }
    }

    private static func makeListener(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        try? FileManager.default.removeItem(atPath: path)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map(UInt8.init(bitPattern:)))
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
