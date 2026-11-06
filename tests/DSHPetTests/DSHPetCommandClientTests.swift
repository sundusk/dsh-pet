import XCTest
@testable import DSHPet

final class DSHPetCommandClientTests: XCTestCase {
    private let workspaceID = "workspace"

    @MainActor
    func testViewingCompletedTaskDoesNotDrivePetSnapshot() {
        let suiteName = "DSHPetCommandClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("completed-session", forKey: "dsh-pet.command.sessionID")

        let client = DSHPetCommandClient(
            defaults: defaults,
            socketPath: "/tmp/dsh-pet-command-client-tests-unused.sock"
        )
        let completedTask = DSHPetTaskSummary(
            sessionID: "completed-session",
            workspaceID: "workspace",
            title: "已完成任务",
            cwd: nil,
            updatedAt: 1,
            running: false,
            blank: false,
            state: .completed,
            mood: "done",
            taskRunning: false,
            waitingForUser: false,
            failed: false,
            completed: true,
            tool: nil,
            message: nil
        )

        client.applyTaskSummaries([completedTask])
        client.focusTask(completedTask.id)

        XCTAssertEqual(client.focusedTask?.id, completedTask.id)
        XCTAssertEqual(client.focusedTask?.statusLabel, "已完成")
        XCTAssertNil(client.sessionSnapshot)
    }

    @MainActor
    func testActiveTasksIncludeOtherWorkspacesAndFollowPriorityOrder() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        let baseline = [
            task("waiting", updatedAt: 10, waitingForUser: true),
            task("failed", updatedAt: 20, failed: false),
            task("completed", updatedAt: 30),
            task("running", updatedAt: 40, taskRunning: true),
            task("blank-running", updatedAt: 50, blank: true, running: true),
            task("other-workspace", workspaceID: "other", updatedAt: 60, running: true),
        ]
        client.applyTaskSummaries(baseline, establishesBaseline: true)

        let updated = [
            baseline[0],
            task("failed", updatedAt: 21, failed: true, mood: "failed"),
            task("completed", updatedAt: 31, completed: true, mood: "done"),
            baseline[3], baseline[4], baseline[5],
        ]
        client.applyTaskSummaries(updated)

        XCTAssertEqual(
            client.activeTasks.map(\.id),
            ["waiting", "failed", "completed", "other-workspace", "blank-running", "running"]
        )
        XCTAssertEqual(client.unreadTaskCount, 2)
    }

    @MainActor
    func testTaskCenterShowsDesktopTasksWithoutSelectedWorkspace() {
        let (client, cleanup) = makeClient(workspace: nil)
        defer { cleanup() }

        XCTAssertNil(client.selectedWorkspaceID)
        client.applyTaskSummaries([
            task("desktop-task", workspaceID: "desktop", updatedAt: 1, running: true),
        ], establishesBaseline: true)

        XCTAssertEqual(client.activeTasks.map(\.id), ["desktop-task"])
    }

    @MainActor
    func testBubbleDeckUsesAggregateAndStableTaskOrderForMultipleTasks() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        let first = task("first", workspaceID: "workspace-a", updatedAt: 10, running: true, taskRunning: true, mood: "jumping")
        let second = task("second", workspaceID: "workspace-b", updatedAt: 20, running: true, taskRunning: true, mood: "waiting")
        client.applyTaskSummaries([first, second])

        XCTAssertEqual(client.bubbleDeck.mode, .multi)
        XCTAssertEqual(client.bubbleDeck.pages.count, 3)
        XCTAssertTrue(client.bubbleDeck.pages[0].isAggregate)
        XCTAssertEqual(client.bubbleDeck.pages[0].title, "2 个任务进行中")
        XCTAssertEqual(client.bubbleDeck.pages.compactMap(\.taskID), ["first", "second"])
        XCTAssertEqual(client.bubbleDeck.totalTaskCount, 2)

        // A later refresh must keep the existing card order even when the
        // Harness list order or timestamps change.
        client.applyTaskSummaries([second, first])
        XCTAssertEqual(client.bubbleDeck.pages.compactMap(\.taskID), ["first", "second"])
    }

    @MainActor
    func testBubbleDeckPriorityPrefersWaitingAndFailure() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([
            task("completed", updatedAt: 10, running: true, taskRunning: true, mood: "jumping"),
            task("running", updatedAt: 20, running: true, taskRunning: true, mood: "jumping"),
            task("failed", updatedAt: 30, running: true, taskRunning: true, mood: "jumping"),
            task("waiting", updatedAt: 40, running: true, taskRunning: true, mood: "jumping"),
        ], establishesBaseline: true)

        let completed = task("completed", updatedAt: 11, completed: true, mood: "done")
        let running = task("running", updatedAt: 20, running: true, taskRunning: true, mood: "jumping")
        let failed = task("failed", updatedAt: 31, failed: true, mood: "failed")
        let waiting = task("waiting", updatedAt: 41, waitingForUser: true, mood: "authorizing")

        client.applyTaskSummaries([completed, running, failed, waiting])
        XCTAssertEqual(client.bubbleDeck.pages[0].mood, "authorizing")
        XCTAssertEqual(client.bubbleDeck.totalTaskCount, 4)

        client.applyTaskSummaries([completed, running, failed])
        XCTAssertEqual(client.bubbleDeck.pages[0].mood, "failed")

        client.focusTask("failed")
        XCTAssertEqual(client.bubbleDeck.pages[0].mood, "jumping")

        client.focusTask("completed")
        XCTAssertEqual(client.bubbleDeck.mode, .single)
        XCTAssertEqual(client.bubbleDeck.pages.first?.taskID, "running")
    }

    @MainActor
    func testAcknowledgeRemovesCompletedTaskFromPresentationAndDeck() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        let running = task("running", updatedAt: 1, running: true, taskRunning: true, mood: "jumping")
        let completed = task("completed", updatedAt: 2, completed: true, mood: "done")
        client.applyTaskSummaries([running, completed])
        client.beginActiveTaskPresentation()

        XCTAssertTrue(client.activeTasks.contains { $0.id == "completed" })
        XCTAssertEqual(client.bubbleDeck.mode, .multi)

        client.acknowledgeTask("completed")

        XCTAssertFalse(client.activeTasks.contains { $0.id == "completed" })
        XCTAssertEqual(client.bubbleDeck.mode, .single)
        XCTAssertEqual(client.bubbleDeck.pages.first?.taskID, "running")
        XCTAssertFalse(client.isTaskUnread(completed))
    }

    @MainActor
    func testBubbleDeckKeepsWaitingTaskAfterItIsRead() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        let waiting = task("waiting", updatedAt: 1, waitingForUser: true, mood: "questioning")
        client.applyTaskSummaries([waiting], establishesBaseline: true)
        client.focusTask("waiting")

        XCTAssertEqual(client.bubbleDeck.mode, .single)
        XCTAssertEqual(client.bubbleDeck.pages.first?.taskID, "waiting")
        XCTAssertEqual(client.bubbleDeck.pages.first?.mood, "questioning")
    }

    @MainActor
    func testBubbleDeckCapsTaskPagesAtFive() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        let tasks = (0..<6).map { index in
            task("task-\(index)", updatedAt: TimeInterval(index + 1), running: true, taskRunning: true, mood: "jumping")
        }
        client.applyTaskSummaries(tasks)

        XCTAssertEqual(client.bubbleDeck.mode, .multi)
        XCTAssertEqual(client.bubbleDeck.pages.count, 6)
        XCTAssertEqual(client.bubbleDeck.totalTaskCount, 6)
    }

    @MainActor
    func testBubbleDeckIgnoresIdleTasks() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([
            task("idle", updatedAt: 1),
            task("blank", updatedAt: 2, blank: true),
        ], establishesBaseline: true)

        XCTAssertEqual(client.bubbleDeck.mode, .none)
        XCTAssertTrue(client.bubbleDeck.pages.isEmpty)
    }

    @MainActor
    func testBubbleDeckSingleModeHidesAfterTerminalHold() {
        var clock: TimeInterval = 100
        let (client, cleanup) = makeClient(now: { clock })
        defer { cleanup() }

        client.applyTaskSummaries([
            task("one", updatedAt: 1, running: true, taskRunning: true, mood: "jumping"),
        ], establishesBaseline: true)
        XCTAssertEqual(client.bubbleDeck.mode, .single)
        XCTAssertEqual(client.bubbleDeck.pages.first?.isHolding, false)

        clock = 101
        client.applyTaskSummaries([
            task("one", updatedAt: 2, completed: true, mood: "done"),
        ])
        XCTAssertEqual(client.bubbleDeck.mode, .single)
        XCTAssertEqual(client.bubbleDeck.pages.first?.isHolding, true)
        XCTAssertEqual(client.bubbleDeck.pages.first?.mood, "done")

        clock = 104
        client.refreshBubbleDeck()
        XCTAssertEqual(client.bubbleDeck.mode, .none)
        XCTAssertTrue(client.bubbleDeck.pages.isEmpty)
    }

    @MainActor
    func testBubbleDeckMultiModeKeepsStaticCompletedPageAfterHold() {
        var clock: TimeInterval = 100
        let (client, cleanup) = makeClient(now: { clock })
        defer { cleanup() }

        let running = task("running", updatedAt: 1, running: true, taskRunning: true, mood: "jumping")
        let completing = task("completing", updatedAt: 2, running: true, taskRunning: true, mood: "waiting")
        client.applyTaskSummaries([running, completing], establishesBaseline: true)

        clock = 101
        client.applyTaskSummaries([
            running,
            task("completing", updatedAt: 3, completed: true, mood: "done"),
        ])
        XCTAssertEqual(client.bubbleDeck.mode, .multi)
        XCTAssertEqual(client.bubbleDeck.pages.first?.mood, "jumping")
        let completingPage = client.bubbleDeck.pages.first { $0.taskID == "completing" }
        XCTAssertEqual(completingPage?.isHolding, true)
        XCTAssertEqual(completingPage?.mood, "done")

        clock = 104
        client.refreshBubbleDeck()
        XCTAssertEqual(client.bubbleDeck.mode, .multi)
        XCTAssertEqual(client.bubbleDeck.pages.first?.mood, "jumping")
        let staticPage = client.bubbleDeck.pages.first { $0.taskID == "completing" }
        XCTAssertEqual(staticPage?.isHolding, false)
        XCTAssertEqual(staticPage?.mood, "idle")
    }

    @MainActor
    func testBubbleDeckReadTerminalTaskDowngradesToSingleMode() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        let running = task("running", updatedAt: 1, running: true, taskRunning: true, mood: "jumping")
        let completed = task("completed", updatedAt: 2, completed: true, mood: "done")
        client.applyTaskSummaries([running, completed])
        XCTAssertEqual(client.bubbleDeck.mode, .multi)

        client.focusTask("completed")
        XCTAssertEqual(client.bubbleDeck.mode, .single)
        XCTAssertEqual(client.bubbleDeck.pages.first?.taskID, "running")
    }

    @MainActor
    func testActiveTaskOrderingUsesNewestUpdateWithinPriority() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        client.applyTaskSummaries([
            task("older-wait", updatedAt: 10, waitingForUser: true),
            task("newer-wait", updatedAt: 20, waitingForUser: true),
            task("older-run", updatedAt: 30, running: true),
            task("newer-run", updatedAt: 40, running: true),
        ])

        XCTAssertEqual(client.activeTasks.map(\.id), ["newer-wait", "older-wait", "newer-run", "older-run"])
    }

    @MainActor
    func testReadTerminalTaskStaysForPresentationThenMigratesToRecent() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([
            task("terminal", updatedAt: 10, taskRunning: true, mood: "working"),
            task("running", updatedAt: 20, taskRunning: true, mood: "working"),
        ], establishesBaseline: true)
        client.applyTaskSummaries([
            task("terminal", updatedAt: 11, completed: true, mood: "done"),
            task("running", updatedAt: 20, taskRunning: true, mood: "working"),
        ])

        client.beginActiveTaskPresentation()
        client.focusTask("terminal")

        XCTAssertEqual(client.activeTasks.map(\.id), ["terminal", "running"])
        XCTAssertEqual(client.unreadTaskCount, 0)
        XCTAssertTrue(client.recentTasks.isEmpty)

        client.endActiveTaskPresentation()

        XCTAssertEqual(client.activeTasks.map(\.id), ["running"])
        XCTAssertEqual(client.recentTasks.map(\.id), ["terminal"])
    }

    @MainActor
    func testPresentationSnapshotDropsTasksThatNoLongerExist() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([task("running", updatedAt: 1, running: true)], establishesBaseline: true)
        client.beginActiveTaskPresentation()
        client.applyTaskSummaries([])

        XCTAssertTrue(client.activeTasks.isEmpty)
    }

    @MainActor
    func testTerminalTaskArrivingDuringPresentationStaysAfterItIsRead() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        client.beginActiveTaskPresentation()
        client.applyTaskSummaries([task("arrived", updatedAt: 1, completed: true, mood: "done")])
        client.focusTask("arrived")

        XCTAssertEqual(client.activeTasks.map(\.id), ["arrived"])

        client.endActiveTaskPresentation()
        XCTAssertTrue(client.activeTasks.isEmpty)
        XCTAssertEqual(client.recentTasks.map(\.id), ["arrived"])
    }

    @MainActor
    func testRecentTasksExcludeActiveAndBlankAndKeepNewestFive() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }

        client.applyTaskSummaries([], establishesBaseline: true)
        client.applyTaskSummaries([
            task("active", updatedAt: 100, running: true),
            task("blank", updatedAt: 99, blank: true),
            task("recent-1", updatedAt: 1),
            task("recent-2", updatedAt: 2),
            task("recent-3", updatedAt: 3),
            task("recent-4", updatedAt: 4),
            task("recent-5", updatedAt: 5),
            task("recent-6", updatedAt: 6),
        ])

        XCTAssertEqual(
            client.recentTasks.map(\.id),
            ["recent-6", "recent-5", "recent-4", "recent-3", "recent-2"]
        )
    }

    @MainActor
    func testDraftProtectsInputTargetAcrossSessions() {
        let (client, cleanup) = makeClient(sessionID: "current")
        defer { cleanup() }
        let current = task("current", updatedAt: 2)
        let other = task("other", updatedAt: 1)
        client.applyTaskSummaries([current, other], establishesBaseline: true)
        client.draft = "尚未发送"

        XCTAssertFalse(client.continueTask(other))
        XCTAssertEqual(client.sessionID, "current")
        XCTAssertEqual(client.continuationWarning, "请先处理当前草稿，再切换会话")

        client.draft = "  \n "
        XCTAssertTrue(client.continueTask(other))
        XCTAssertEqual(client.sessionID, "other")
    }

    @MainActor
    func testContinueTaskSwitchesToItsWorkspaceWhenDraftIsEmpty() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }
        client.applyWorkspaces([workspace("workspace"), workspace("other")])
        let target = task("target", workspaceID: "other", updatedAt: 1)
        client.applyTaskSummaries([target], establishesBaseline: true)

        XCTAssertEqual(client.selectedWorkspaceID, "workspace")
        XCTAssertTrue(client.continueTask(target))
        XCTAssertEqual(client.selectedWorkspaceID, "other")
        XCTAssertEqual(client.sessionID, "target")
    }

    @MainActor
    func testDraftBlocksContinuingTaskInAnotherWorkspace() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }
        client.applyWorkspaces([workspace("workspace"), workspace("other")])
        client.draft = "尚未发送"
        let target = task("target", workspaceID: "other", updatedAt: 1)
        client.applyTaskSummaries([target], establishesBaseline: true)

        XCTAssertFalse(client.continueTask(target))
        XCTAssertEqual(client.selectedWorkspaceID, "workspace")
        XCTAssertEqual(client.continuationWarning, "请先处理当前草稿，再切换会话")
    }

    @MainActor
    func testHarnessTargetSwitchKeepsDraftAndRejectsNewSource() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }
        let first = harnessInstance(id: "first", profile: "desktop")
        let second = harnessInstance(id: "second", profile: "web")

        XCTAssertTrue(client.configure(instance: first, allowLegacy: false))
        client.draft = "尚未发送"

        XCTAssertFalse(client.configure(instance: second, allowLegacy: false))
        XCTAssertEqual(client.draft, "尚未发送")
        XCTAssertEqual(client.lastError, "请先处理当前草稿或未确认请求，再切换 Harness 来源")
        XCTAssertEqual(client.targetBindingKey, first.bindingKey)
    }

    @MainActor
    func testFirstIdentifiedTargetClearsUnownedWorkspaceButKeepsDraft() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }
        let instance = harnessInstance(id: "first", profile: "desktop")
        client.draft = "旧来源草稿"

        XCTAssertTrue(client.configure(instance: instance, allowLegacy: false))
        XCTAssertEqual(client.draft, "旧来源草稿")
        XCTAssertNil(client.selectedWorkspaceID)
        XCTAssertEqual(client.continuationWarning, "Harness 来源已更新，请重新选择工作区")
    }

    @MainActor
    func testHarnessRestartWithSameBindingDoesNotClearDraft() {
        let (client, cleanup) = makeClient()
        defer { cleanup() }
        let first = harnessInstance(id: "first", profile: "desktop")
        let restarted = harnessInstance(id: "second", profile: "desktop")

        XCTAssertTrue(client.configure(instance: first, allowLegacy: false))
        client.draft = "保留草稿"

        XCTAssertTrue(client.configure(instance: restarted, allowLegacy: false))
        XCTAssertEqual(client.draft, "保留草稿")
        XCTAssertEqual(client.targetBindingKey, restarted.bindingKey)
    }

    @MainActor
    private func makeClient(
        sessionID: String? = nil,
        workspace: String? = "workspace",
        now: @escaping () -> TimeInterval = { 100 }
    ) -> (DSHPetCommandClient, () -> Void) {
        let suiteName = "DSHPetCommandClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let workspace {
            defaults.set(workspace, forKey: "dsh-pet.command.workspaceID")
        }
        if let sessionID { defaults.set(sessionID, forKey: "dsh-pet.command.sessionID") }
        let client = DSHPetCommandClient(
            defaults: defaults,
            socketPath: "/tmp/dsh-pet-command-client-tests-unused.sock",
            now: now
        )
        return (client, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func workspace(_ id: String) -> DSHPetWorkspace {
        DSHPetWorkspace(id: id, title: id, path: "/tmp/\(id)", status: "ok", sessionIds: [])
    }

    private func task(
        _ id: String,
        workspaceID: String? = nil,
        updatedAt: TimeInterval,
        blank: Bool = false,
        running: Bool = false,
        taskRunning: Bool = false,
        waitingForUser: Bool = false,
        failed: Bool = false,
        completed: Bool = false,
        mood: String = "idle"
    ) -> DSHPetTaskSummary {
        DSHPetTaskSummary(
            sessionID: id,
            workspaceID: workspaceID ?? self.workspaceID,
            title: id,
            cwd: nil,
            updatedAt: updatedAt,
            running: running,
            blank: blank,
            state: completed ? .completed : (failed ? .failed : .idle),
            mood: mood,
            taskRunning: taskRunning,
            waitingForUser: waitingForUser,
            failed: failed,
            completed: completed,
            tool: nil,
            message: nil
        )
    }

    private func harnessInstance(id: String, profile: String) -> HarnessInstance {
        HarnessInstance(
            protocolVersion: 1,
            instanceId: id,
            kind: profile == "desktop" ? .desktop : .web,
            profile: profile,
            pid: 999_999,
            startedAt: 1,
            webURL: profile == "web" ? "http://127.0.0.1:3080" : nil,
            statusSocketPath: "/tmp/\(id)-status.sock",
            commandSocketPath: "/tmp/\(id)-command.sock",
            targetId: "profile-\(profile)"
        )
    }
}
