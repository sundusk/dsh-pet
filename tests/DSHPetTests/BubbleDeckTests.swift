import XCTest
@testable import DSHPet

final class BubbleDeckTests: XCTestCase {
    private let now: TimeInterval = 100

    func testAggregateAndTaskPagesUsePriorityAndTaskDetails() {
        let inputs = [
            input(running("a", mood: "jumping", tool: "bash"), project: "dsh-pet"),
            input(waiting("b", mood: "authorizing"), project: "dsh-pet"),
            input(failed("c", updatedAt: 5), project: "other", holdUntil: 200),
            input(completed("d", updatedAt: 6), project: "other", holdUntil: 200),
        ]

        let deck = DSHPetBubbleDeckBuilder.build(inputs: inputs, now: now)
        XCTAssertEqual(deck.mode, .multi)
        XCTAssertEqual(deck.totalTaskCount, 4)
        XCTAssertEqual(deck.pages.count, 5)
        XCTAssertTrue(deck.pages[0].isAggregate)
        XCTAssertEqual(deck.pages[0].mood, "authorizing")
        XCTAssertEqual(deck.pages[0].title, "4 个任务等待操作")
        XCTAssertEqual(deck.pages[0].bubbleText, "4 个任务等待操作")

        let waitingPage = deck.pages.first { $0.taskID == "b" }
        XCTAssertEqual(waitingPage?.bubbleText, "等待你的授权")
        XCTAssertEqual(waitingPage?.detail, "dsh-pet · 等待授权")
        XCTAssertEqual(waitingPage?.isWaiting, true)

        let runningPage = deck.pages.first { $0.taskID == "a" }
        XCTAssertEqual(runningPage?.bubbleText, "工具调用")
        XCTAssertEqual(runningPage?.detail, "dsh-pet · bash")

        let failedPage = deck.pages.first { $0.taskID == "c" }
        XCTAssertEqual(failedPage?.mood, "failed")
        XCTAssertEqual(failedPage?.bubbleText, "出错了")
        XCTAssertEqual(failedPage?.isHolding, true)
        XCTAssertEqual(failedPage?.detail, "other · 失败")

        let completedPage = deck.pages.first { $0.taskID == "d" }
        XCTAssertEqual(completedPage?.mood, "done")
        XCTAssertEqual(completedPage?.bubbleText, "搞定啦")
    }

    func testStoppedTaskOnlyAppearsDuringItsResultHold() {
        let stoppedTask = stopped("stopped")
        XCTAssertEqual(
            DSHPetBubbleDeckBuilder.build(inputs: [input(stoppedTask)], now: now).mode,
            .none
        )
        let held = DSHPetBubbleDeckBuilder.build(
            inputs: [input(stoppedTask, holdUntil: 103)],
            now: now
        )
        XCTAssertEqual(held.mode, .single)
        XCTAssertEqual(held.pages.first?.mood, "stopped")
        XCTAssertEqual(held.pages.first?.bubbleText, "已停止")

        let multi = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("running")), input(stoppedTask, holdUntil: 103)],
            now: now
        )
        XCTAssertEqual(multi.mode, .multi)
        XCTAssertEqual(multi.pages.count, 3)

        let expired = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("running")), input(stoppedTask, holdUntil: 99)],
            now: now
        )
        XCTAssertEqual(expired.mode, .single)
        XCTAssertEqual(expired.pages.first?.taskID, "running")
    }

    func testSingleTaskKeepsSingleModeAndHidesAfterHold() {
        let runningDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("running"))],
            now: now
        )
        XCTAssertEqual(runningDeck.mode, .single)
        XCTAssertEqual(runningDeck.pages.count, 1)

        let heldDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(completed("done"), holdUntil: 103)],
            now: now
        )
        XCTAssertEqual(heldDeck.mode, .single)
        XCTAssertEqual(heldDeck.pages.first?.isHolding, true)
        XCTAssertEqual(heldDeck.pages.first?.mood, "done")

        let expiredDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(completed("done"), holdUntil: 99)],
            now: now
        )
        XCTAssertEqual(expiredDeck.mode, .none)
        XCTAssertTrue(expiredDeck.pages.isEmpty)
    }

    func testInitialCompletedTaskIsStaticAndDoesNotHold() {
        let singleDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(completed("old"))],
            now: now
        )
        XCTAssertEqual(singleDeck.mode, .none)

        let multiDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("running")), input(completed("old"))],
            now: now
        )
        XCTAssertEqual(multiDeck.mode, .multi)
        XCTAssertEqual(multiDeck.pages.first?.mood, "jumping")
        let old = multiDeck.pages.first { $0.taskID == "old" }
        XCTAssertEqual(old?.isHolding, false)
        XCTAssertEqual(old?.mood, "idle")
        XCTAssertEqual(old?.bubbleText, "搞定啦")
    }

    func testTaskPagesAreCappedButTotalCountIsKept() {
        let inputs = (0..<7).map { index in
            input(running("task-\(index)", updatedAt: TimeInterval(index + 1)))
        }
        let deck = DSHPetBubbleDeckBuilder.build(inputs: inputs, now: now)
        XCTAssertEqual(deck.mode, .multi)
        XCTAssertEqual(deck.pages.count, 6)
        XCTAssertEqual(deck.totalTaskCount, 7)
        XCTAssertEqual(deck.pages.dropFirst().compactMap(\.taskID), ["task-0", "task-1", "task-2", "task-3", "task-4"])
    }

    func testSelectionKeepsCurrentTaskAndReturnsToAggregateOnHoldExpiry() {
        let runningDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("a")), input(running("b"))],
            now: now
        )
        XCTAssertEqual(
            DSHPetBubbleSelection.index(
                in: runningDeck,
                previousMode: .multi,
                previousID: "b",
                previousWasHolding: false,
                previousWaitingIDs: []
            ),
            2
        )
        XCTAssertEqual(
            DSHPetBubbleSelection.index(
                in: runningDeck,
                previousMode: .multi,
                previousID: "b",
                previousWasHolding: false,
                previousWaitingIDs: [],
                forcedID: "a"
            ),
            1
        )

        let waitingDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("a")), input(waiting("b"))],
            now: now
        )
        XCTAssertEqual(
            DSHPetBubbleSelection.index(
                in: waitingDeck,
                previousMode: .multi,
                previousID: "b",
                previousWasHolding: false,
                previousWaitingIDs: []
            ),
            0
        )

        let expiredDeck = DSHPetBubbleDeckBuilder.build(
            inputs: [input(running("a")), input(completed("b"), holdUntil: 99)],
            now: now
        )
        XCTAssertEqual(
            DSHPetBubbleSelection.index(
                in: expiredDeck,
                previousMode: .multi,
                previousID: "b",
                previousWasHolding: true,
                previousWaitingIDs: []
            ),
            0
        )
        XCTAssertEqual(
            DSHPetBubbleSelection.index(
                in: expiredDeck,
                previousMode: .multi,
                previousID: "b",
                previousWasHolding: false,
                previousWaitingIDs: []
            ),
            2
        )
        XCTAssertEqual(
            DSHPetBubbleSelection.index(
                in: expiredDeck,
                previousMode: .single,
                previousID: "b",
                previousWasHolding: false,
                previousWaitingIDs: []
            ),
            0
        )
    }

    private func input(
        _ task: DSHPetTaskSummary,
        project: String? = "project",
        unread: Bool = true,
        holdUntil: TimeInterval = 0
    ) -> DSHPetBubbleTaskInput {
        DSHPetBubbleTaskInput(
            task: task,
            workspaceTitle: project,
            isUnread: unread,
            holdUntil: holdUntil
        )
    }

    private func running(
        _ id: String,
        updatedAt: TimeInterval = 1,
        mood: String = "jumping",
        tool: String? = nil
    ) -> DSHPetTaskSummary {
        summary(
            id,
            updatedAt: updatedAt,
            running: true,
            taskRunning: true,
            state: mood == "jumping" ? .toolCalling : .thinking,
            mood: mood,
            tool: tool
        )
    }

    private func waiting(_ id: String, mood: String = "authorizing") -> DSHPetTaskSummary {
        summary(
            id,
            updatedAt: 2,
            taskRunning: true,
            waitingForUser: true,
            state: mood == "authorizing" ? .waitingApproval : .waitingUserAnswer,
            mood: mood
        )
    }

    private func failed(_ id: String, updatedAt: TimeInterval = 3) -> DSHPetTaskSummary {
        summary(id, updatedAt: updatedAt, failed: true, state: .failed, mood: "failed")
    }

    private func completed(_ id: String, updatedAt: TimeInterval = 4) -> DSHPetTaskSummary {
        summary(id, updatedAt: updatedAt, completed: true, state: .completed, mood: "done")
    }

    private func stopped(_ id: String, updatedAt: TimeInterval = 5) -> DSHPetTaskSummary {
        summary(id, updatedAt: updatedAt, state: .stopped, mood: "stopped")
    }

    private func summary(
        _ id: String,
        updatedAt: TimeInterval,
        running: Bool = false,
        taskRunning: Bool = false,
        waitingForUser: Bool = false,
        failed: Bool = false,
        completed: Bool = false,
        state: AgentState = .idle,
        mood: String = "idle",
        tool: String? = nil
    ) -> DSHPetTaskSummary {
        DSHPetTaskSummary(
            sessionID: id,
            workspaceID: "workspace",
            title: "Task \(id)",
            cwd: nil,
            updatedAt: updatedAt,
            running: running,
            blank: false,
            state: state,
            mood: mood,
            taskRunning: taskRunning,
            waitingForUser: waitingForUser,
            failed: failed,
            completed: completed,
            tool: tool,
            message: nil
        )
    }
}
