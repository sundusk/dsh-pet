import Foundation

/// One page in the pet's bubble deck. The deck is presentation-only: it never
/// changes the composer's selected workspace or Session binding.
struct DSHPetBubblePage: Equatable, Identifiable {
    enum Kind: Equatable {
        case aggregate
        case task
    }

    let id: String
    let kind: Kind
    /// Aggregate: the count/status sentence. Task: the task title.
    let title: String
    /// Task: "workspace · tool/status"; aggregate has no second line.
    let detail: String?
    /// Mood used by the single pet sprite while this page is selected.
    let mood: String
    let taskID: String?
    let isWaiting: Bool
    let isTerminal: Bool
    let isHolding: Bool

    var isAggregate: Bool { kind == .aggregate }
}

/// What the floating pet should render above its head. Single keeps the
/// original compact status bubble; aggregate/task enable the stacked deck.
struct DSHPetBubblePresentation: Equatable {
    enum Style: Equatable {
        case single
        case aggregate
        case task
    }

    let style: Style
    let title: String
    let detail: String?
    let pageNumber: Int?
    let stackDepth: Int
    let interactive: Bool

    var isMulti: Bool { style != .single }
}

/// The pages the pet can cycle through. With one task the deck keeps the
/// original single status bubble; the aggregate page only exists for 2+ tasks.
struct DSHPetBubbleDeck: Equatable {
    enum Mode: Equatable {
        case none
        case single
        case multi
    }

    let mode: Mode
    let pages: [DSHPetBubblePage]
    let totalTaskCount: Int
    let waitingTaskIDs: Set<String>

    static let empty = DSHPetBubbleDeck(
        mode: .none,
        pages: [],
        totalTaskCount: 0,
        waitingTaskIDs: []
    )
}

/// Input for one ordinary Session considered for the bubble deck.
struct DSHPetBubbleTaskInput: Equatable {
    let task: DSHPetTaskSummary
    let workspaceTitle: String?
    let isUnread: Bool
    let holdUntil: TimeInterval
}

/// Pure deck construction so ordering, priority and terminal holds are easy
/// to test without sockets or UI.
enum DSHPetBubbleDeckBuilder {
    static let maxTaskPages = 5
    static let doneHold: TimeInterval = 2.5
    static let failureHold: TimeInterval = 3.0

    static func isWaitingForUser(_ task: DSHPetTaskSummary) -> Bool {
        task.waitingForUser || task.state == .waitingApproval || task.state == .waitingUserAnswer
    }

    static func isRunning(_ task: DSHPetTaskSummary) -> Bool {
        task.taskRunning || task.running || task.state == .thinking || task.state == .toolCalling
    }

    static func isFailed(_ task: DSHPetTaskSummary) -> Bool {
        task.failed || task.state == .failed || task.mood == "failed"
    }

    static func isCompleted(_ task: DSHPetTaskSummary) -> Bool {
        task.completed || task.state == .completed || task.mood == "done"
    }

    static func isStopped(_ task: DSHPetTaskSummary) -> Bool {
        task.state == .stopped || task.mood == "stopped"
    }

    static func isTerminal(_ task: DSHPetTaskSummary) -> Bool {
        isFailed(task) || isCompleted(task) || isStopped(task)
    }

    static func isAttention(
        task: DSHPetTaskSummary,
        isUnread: Bool,
        holdUntil: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        if isWaitingForUser(task) || isRunning(task) { return true }
        if isStopped(task) {
            // Stopped has no persistent card in the task center; it only gets
            // the short result animation while its hold is live.
            return isUnread && holdUntil > now
        }
        if isFailed(task) || isCompleted(task) { return isUnread }
        return false
    }

    static func isAttention(_ input: DSHPetBubbleTaskInput, now: TimeInterval) -> Bool {
        isAttention(
            task: input.task,
            isUnread: input.isUnread,
            holdUntil: input.holdUntil,
            now: now
        )
    }

    static func holdDuration(for task: DSHPetTaskSummary) -> TimeInterval {
        if isFailed(task) || isStopped(task) { return failureHold }
        return doneHold
    }

    static func build(inputs: [DSHPetBubbleTaskInput], now: TimeInterval) -> DSHPetBubbleDeck {
        let attention = inputs.filter { isAttention($0, now: now) }
        guard !attention.isEmpty else { return .empty }

        if attention.count == 1, let only = attention.first {
            let terminal = isTerminal(only.task)
            let holding = terminal && only.holdUntil > now
            guard !terminal || holding else { return .empty }
            let page = taskPage(for: only, now: now)
            return DSHPetBubbleDeck(
                mode: .single,
                pages: [page],
                totalTaskCount: 1,
                waitingTaskIDs: isWaitingForUser(only.task) ? [only.task.sessionID] : []
            )
        }

        let total = attention.count
        let visible = Array(attention.prefix(maxTaskPages))
        let aggregateMood = aggregateActionMood(from: attention, now: now)
        let labelMood = aggregateLabelMood(from: attention, actionMood: aggregateMood)
        let aggregate = DSHPetBubblePage(
            id: "aggregate",
            kind: .aggregate,
            title: MoodColorMap.aggregateLabel(for: labelMood, taskCount: total),
            detail: nil,
            mood: aggregateMood,
            taskID: nil,
            isWaiting: attention.contains { isWaitingForUser($0.task) },
            isTerminal: false,
            isHolding: false
        )
        let waitingIDs = Set(attention.filter { isWaitingForUser($0.task) }.map { $0.task.sessionID })
        return DSHPetBubbleDeck(
            mode: .multi,
            pages: [aggregate] + visible.map { taskPage(for: $0, now: now) },
            totalTaskCount: total,
            waitingTaskIDs: waitingIDs
        )
    }

    private static func taskPage(for input: DSHPetBubbleTaskInput, now: TimeInterval) -> DSHPetBubblePage {
        let task = input.task
        let terminal = isTerminal(task)
        let holding = terminal && input.holdUntil > now
        let mood: String
        if terminal && !holding {
            mood = "idle"
        } else if isWaitingForUser(task) {
            mood = task.mood == "authorizing" ? "authorizing" : "questioning"
        } else if isFailed(task) {
            mood = "failed"
        } else if isCompleted(task) {
            mood = "done"
        } else if isStopped(task) {
            mood = "stopped"
        } else {
            mood = task.mood == "jumping" ? "jumping" : "waiting"
        }

        let trimmedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty
            ? "会话 \(task.sessionID.suffix(8))"
            : trimmedTitle
        return DSHPetBubblePage(
            id: task.sessionID,
            kind: .task,
            title: title,
            detail: detail(for: input),
            mood: mood,
            taskID: task.sessionID,
            isWaiting: isWaitingForUser(task),
            isTerminal: terminal,
            isHolding: holding
        )
    }

    private static func detail(for input: DSHPetBubbleTaskInput) -> String? {
        let task = input.task
        let status: String
        if isWaitingForUser(task) {
            status = task.mood == "authorizing" ? "等待授权" : "等待回答"
        } else if isTerminal(task) {
            status = task.statusLabel
        } else if isRunning(task) {
            if task.mood == "jumping", let tool = task.tool, !tool.isEmpty {
                status = tool
            } else {
                status = "执行中"
            }
        } else {
            status = task.statusLabel
        }
        guard let project = input.workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !project.isEmpty else { return status }
        return "\(project) · \(status)"
    }

    private static func aggregateRank(_ input: DSHPetBubbleTaskInput, now: TimeInterval) -> Int? {
        let task = input.task
        if isWaitingForUser(task) { return 0 }
        if isFailed(task), input.holdUntil > now { return 1 }
        if isRunning(task) { return 2 }
        if isCompleted(task), input.holdUntil > now { return 3 }
        if isStopped(task), input.holdUntil > now { return 4 }
        return nil
    }

    private static func aggregateActionMood(from inputs: [DSHPetBubbleTaskInput], now: TimeInterval) -> String {
        let ranked = inputs.compactMap { input -> (Int, DSHPetBubbleTaskInput)? in
            guard let rank = aggregateRank(input, now: now) else { return nil }
            return (rank, input)
        }
        guard let primary = ranked.min(by: {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1.task.updatedAt != $1.1.task.updatedAt {
                return $0.1.task.updatedAt > $1.1.task.updatedAt
            }
            return $0.1.task.sessionID < $1.1.task.sessionID
        })?.1 else { return "idle" }

        let task = primary.task
        if isWaitingForUser(task) {
            return task.mood == "authorizing" ? "authorizing" : "questioning"
        }
        if isFailed(task) { return "failed" }
        if isRunning(task) {
            return task.mood == "jumping" ? "jumping" : "waiting"
        }
        if isCompleted(task) { return "done" }
        if isStopped(task) { return "stopped" }
        return "idle"
    }

    private static func aggregateLabelMood(
        from inputs: [DSHPetBubbleTaskInput],
        actionMood: String
    ) -> String {
        if actionMood != "idle" { return actionMood }
        if inputs.contains(where: { isFailed($0.task) }) { return "failed" }
        if inputs.contains(where: { isCompleted($0.task) }) { return "done" }
        if inputs.contains(where: { isStopped($0.task) }) { return "stopped" }
        return "idle"
    }
}

/// Pure selection rules for the bubble deck. Kept outside the model so mode
/// changes, new waiting tasks and terminal-hold expiry are directly testable.
enum DSHPetBubbleSelection {
    static func index(
        in deck: DSHPetBubbleDeck,
        previousMode: DSHPetBubbleDeck.Mode,
        previousID: String?,
        previousWasHolding: Bool,
        previousWaitingIDs: Set<String>,
        forcedID: String? = nil
    ) -> Int {
        guard !deck.pages.isEmpty else { return 0 }
        if let forcedID, let forced = deck.pages.firstIndex(where: { $0.id == forcedID }) {
            return forced
        }
        guard deck.mode == .multi else { return 0 }

        var index = 0
        if previousMode == .multi, let previousID,
           let previous = deck.pages.firstIndex(where: { $0.id == previousID }) {
            index = previous
        }
        if previousMode != .multi { index = 0 }
        if !deck.waitingTaskIDs.subtracting(previousWaitingIDs).isEmpty { index = 0 }
        if index < deck.pages.count {
            let page = deck.pages[index]
            if previousWasHolding, page.id == previousID, page.isTerminal, !page.isHolding {
                index = 0
            }
        }
        return min(max(0, index), deck.pages.count - 1)
    }
}
