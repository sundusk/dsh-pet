import Foundation
import Network

enum TransportConnection: Equatable {
    case connected
    case unavailable
}

enum TransportKind: String {
    case localSocket = "本地桥接"
    case disconnected = "未连接"
}

@MainActor
protocol HarnessStateTransport: AnyObject {
    var kind: TransportKind { get }
    var isConnected: Bool { get }
    var onStateChanged: ((MoodBridgeSnapshot) -> Void)? { get set }
    var onConnectionChanged: ((TransportConnection) -> Void)? { get set }

    func connect()
    func disconnect()
}

/// Local transport. It observes newline-delimited JSON from the plugin's
/// Unix domain socket and never owns the Harness process or socket server.
@MainActor
final class LocalSocketTransport: HarnessStateTransport {
    let kind: TransportKind = .localSocket
    private(set) var isConnected = false

    var onStateChanged: ((MoodBridgeSnapshot) -> Void)?
    var onConnectionChanged: ((TransportConnection) -> Void)?

    private var socketPath: String
    private var expectedInstanceID: String?
    private let queue = DispatchQueue(label: "com.sundusk.dsh-pet.local-transport")
    private var connection: NWConnection?
    private var retryTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var buffer = Data()
    private var hasValidatedInstance = false

    init(socketPath: String, expectedInstanceID: String? = nil) {
        self.socketPath = socketPath
        self.expectedInstanceID = expectedInstanceID
    }

    func connect() {
        shouldReconnect = true
        retryTask?.cancel()
        retryTask = nil
        openConnection()
    }

    /// Change the selected Harness endpoint without allowing callbacks from
    /// the old connection to reach the new selection.
    func reconfigure(socketPath: String, expectedInstanceID: String?) {
        let wasRunning = shouldReconnect
        disconnect()
        self.socketPath = socketPath
        self.expectedInstanceID = expectedInstanceID
        if wasRunning { connect() }
    }

    private func openConnection() {
        guard connection == nil else { return }
        buffer.removeAll(keepingCapacity: true)
        hasValidatedInstance = false
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    if self.expectedInstanceID == nil {
                        self.isConnected = true
                        self.onConnectionChanged?(.connected)
                    }
                    self.receiveNext(connection)
                case .waiting, .failed, .cancelled:
                    self.connectionEnded(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        shouldReconnect = false
        retryTask?.cancel()
        retryTask = nil
        let previous = connection
        connection = nil
        previous?.cancel()
        buffer.removeAll(keepingCapacity: false)
        hasValidatedInstance = false
        isConnected = false
    }

    private func connectionEnded(_ ended: NWConnection) {
        guard connection === ended else { return }
        connection = nil
        ended.cancel()
        buffer.removeAll(keepingCapacity: false)
        hasValidatedInstance = false
        isConnected = false
        onConnectionChanged?(.unavailable)
        guard shouldReconnect else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, self.shouldReconnect else { return }
            self.retryTask = nil
            self.openConnection()
        }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data { self.consume(data) }
                if isComplete {
                    self.connectionEnded(connection)
                } else {
                    self.receiveNext(connection)
                }
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            if let snapshot = try? JSONDecoder().decode(MoodBridgeSnapshot.self, from: line) {
                if let expectedInstanceID,
                   snapshot.instanceId != expectedInstanceID {
                    if let activeConnection = connection {
                        connectionEnded(activeConnection)
                    }
                    return
                }
                if self.expectedInstanceID != nil && !hasValidatedInstance {
                    hasValidatedInstance = true
                    isConnected = true
                    onConnectionChanged?(.connected)
                }
                onStateChanged?(snapshot)
            }
        }
    }
}
