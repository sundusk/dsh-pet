import Foundation

/// Stable presentation-facing state. Harness wire events never reach a pet view.
enum AgentState: String, Codable, CaseIterable {
    case disconnected
    case idle
    case thinking
    case toolCalling
    case waitingApproval
    case waitingUserAnswer
    case completed
    case failed
    case stopped

    static func fromMood(_ mood: String?) -> AgentState {
        switch mood {
        case "waiting": return .thinking
        case "jumping": return .toolCalling
        case "authorizing": return .waitingApproval
        case "questioning": return .waitingUserAnswer
        case "done": return .completed
        case "failed": return .failed
        case "stopped": return .stopped
        case "idle": return .idle
        default: return .disconnected
        }
    }

    var mood: String {
        switch self {
        case .disconnected: return "disconnected"
        case .idle: return "idle"
        case .thinking: return "waiting"
        case .toolCalling: return "jumping"
        case .waitingApproval: return "authorizing"
        case .waitingUserAnswer: return "questioning"
        case .completed: return "done"
        case .failed: return "failed"
        case .stopped: return "stopped"
        }
    }
}

/// Reserved multi-session shape. The first UI still presents the newest global
/// snapshot, but the bridge does not have to change when session switching lands.
struct AgentSessionState: Codable, Equatable, Identifiable {
    let sessionId: String
    let workspaceId: String?
    let state: AgentState
    let updatedAt: TimeInterval

    var id: String { sessionId }
}

/// Version-tolerant payload shared by HTTP and the local Unix socket.
struct MoodBridgeSnapshot: Codable, Equatable {
    let instanceId: String?
    let state: AgentState
    let mood: String
    let sessionId: String?
    let workspaceId: String?
    let taskRunning: Bool
    let waitingForUser: Bool
    let failed: Bool
    let completed: Bool
    let tool: String?
    let message: String?
    let updatedAt: TimeInterval

    static let disconnected = MoodBridgeSnapshot(
        instanceId: nil,
        state: .disconnected,
        mood: "disconnected",
        sessionId: nil,
        workspaceId: nil,
        taskRunning: false,
        waitingForUser: false,
        failed: false,
        completed: false,
        tool: nil,
        message: nil,
        updatedAt: 0
    )

    init(
        instanceId: String? = nil,
        state: AgentState,
        mood: String? = nil,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        taskRunning: Bool? = nil,
        waitingForUser: Bool? = nil,
        failed: Bool? = nil,
        completed: Bool? = nil,
        tool: String? = nil,
        message: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.instanceId = instanceId
        self.state = state
        self.mood = mood ?? state.mood
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.taskRunning = taskRunning ?? [AgentState.thinking, .toolCalling, .waitingApproval, .waitingUserAnswer].contains(state)
        self.waitingForUser = waitingForUser ?? [AgentState.waitingApproval, .waitingUserAnswer].contains(state)
        self.failed = failed ?? (state == .failed)
        self.completed = completed ?? (state == .completed)
        self.tool = tool
        self.message = message
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId, state, mood, sessionId, workspaceId, taskRunning, waitingForUser, failed, completed, tool, message, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawMood = try values.decodeIfPresent(String.self, forKey: .mood)
        let decodedState = try values.decodeIfPresent(AgentState.self, forKey: .state)
            ?? AgentState.fromMood(rawMood)
        self.init(
            instanceId: try values.decodeIfPresent(String.self, forKey: .instanceId),
            state: decodedState,
            mood: rawMood,
            sessionId: try values.decodeIfPresent(String.self, forKey: .sessionId),
            workspaceId: try values.decodeIfPresent(String.self, forKey: .workspaceId),
            taskRunning: try values.decodeIfPresent(Bool.self, forKey: .taskRunning),
            waitingForUser: try values.decodeIfPresent(Bool.self, forKey: .waitingForUser),
            failed: try values.decodeIfPresent(Bool.self, forKey: .failed),
            completed: try values.decodeIfPresent(Bool.self, forKey: .completed),
            tool: try values.decodeIfPresent(String.self, forKey: .tool),
            message: try values.decodeIfPresent(String.self, forKey: .message),
            updatedAt: try values.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        )
    }
}

/// One ordinary Harness Session displayed by the MoodBall task center.
/// Status is projected by the plugin; read state remains local to the App.
struct MoodBallTaskSummary: Codable, Equatable, Identifiable {
    let sessionID: String
    let workspaceID: String
    let title: String
    let cwd: String?
    let updatedAt: TimeInterval
    let running: Bool
    let blank: Bool
    let state: AgentState
    let mood: String
    let taskRunning: Bool
    let waitingForUser: Bool
    let failed: Bool
    let completed: Bool
    let tool: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case workspaceID = "workspaceId"
        case title, cwd, updatedAt, running, blank, state, mood
        case taskRunning, waitingForUser, failed, completed, tool, message
    }

    var id: String { sessionID }

    var statusLabel: String {
        if waitingForUser { return mood == "authorizing" ? "等待授权" : "等待操作" }
        if failed { return "失败" }
        if completed { return "已完成" }
        if taskRunning || running { return "执行中" }
        if state == .stopped { return "已停止" }
        if blank { return "新会话" }
        return "就绪"
    }

    var statusIcon: String {
        if waitingForUser { return "hand.raised.fill" }
        if failed { return "exclamationmark.circle.fill" }
        if completed { return "checkmark.circle.fill" }
        if taskRunning || running { return "progress.indicator" }
        if state == .stopped { return "stop.circle.fill" }
        return "circle"
    }

    var snapshot: MoodBridgeSnapshot {
        MoodBridgeSnapshot(
            state: state,
            mood: mood,
            sessionId: sessionID,
            workspaceId: workspaceID,
            taskRunning: taskRunning,
            waitingForUser: waitingForUser,
            failed: failed,
            completed: completed,
            tool: tool,
            message: message,
            updatedAt: updatedAt
        )
    }
}
