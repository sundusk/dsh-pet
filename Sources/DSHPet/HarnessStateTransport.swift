import Foundation
import Network

enum TransportConnection: Equatable {
    case connected
    case pluginDisabled
    case unavailable
}

enum TransportKind: String {
    case localSocket = "本地桥接"
    case http = "HTTP 兼容"
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

/// HTTP transport for the DSH Pet status endpoint.
@MainActor
final class HTTPPollingTransport: HarnessStateTransport {
    let kind: TransportKind = .http
    private(set) var isConnected = false

    var onStateChanged: ((MoodBridgeSnapshot) -> Void)?
    var onConnectionChanged: ((TransportConnection) -> Void)?

    private var baseURL: String
    private var pollInterval: TimeInterval
    private var requestTimeout: TimeInterval
    private var pollingTask: Task<Void, Never>?

    init(baseURL: String, pollInterval: TimeInterval, requestTimeout: TimeInterval) {
        self.baseURL = baseURL
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
    }

    func updateConfiguration(baseURL: String, pollInterval: TimeInterval, requestTimeout: TimeInterval) {
        self.baseURL = baseURL
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
    }

    func connect() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                guard !Task.isCancelled else { return }
                let delay = UInt64(max(0.3, self?.pollInterval ?? 0.7) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        isConnected = false
    }

    private func pollOnce() async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/dsh-pet/status") else {
            mark(.unavailable)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                guard let legacyURL = URL(string: "\(trimmed)/api/moodball/status") else { mark(.pluginDisabled); return }
                var legacyRequest = URLRequest(url: legacyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
                legacyRequest.httpMethod = "GET"
                legacyRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                let legacyResult = try await URLSession.shared.data(for: legacyRequest)
                guard let legacyHTTP = legacyResult.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if legacyHTTP.statusCode == 404 { mark(.pluginDisabled); return }
                guard legacyHTTP.statusCode == 200 else { throw URLError(.badServerResponse) }
                let snapshot = try JSONDecoder().decode(MoodBridgeSnapshot.self, from: legacyResult.0)
                onStateChanged?(snapshot)
                mark(.connected)
                return
            }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let snapshot = try JSONDecoder().decode(MoodBridgeSnapshot.self, from: data)
            onStateChanged?(snapshot)
            mark(.connected)
        } catch {
            mark(.unavailable)
        }
    }

    private func mark(_ status: TransportConnection) {
        let connected = status == .connected
        if isConnected != connected { isConnected = connected }
        onConnectionChanged?(status)
    }
}

/// New local transport. It observes newline-delimited JSON from the plugin's
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

    init(socketPath: String = LocalSocketTransport.defaultSocketPath, expectedInstanceID: String? = nil) {
        self.socketPath = socketPath
        self.expectedInstanceID = expectedInstanceID
    }

    nonisolated static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/DSH Pet/dsh-pet.sock"
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
