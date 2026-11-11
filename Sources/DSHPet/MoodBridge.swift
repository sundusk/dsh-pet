import Foundation
import Combine

/// Observes the status socket of the selected Harness instance and exposes one
/// stable stream to the pet model. There is no HTTP fallback: an instance is
/// either discovered through its manifest and connected, or the pet is offline.
@MainActor
final class MoodBridge: ObservableObject {
    @Published private(set) var snapshot = MoodBridgeSnapshot.disconnected
    @Published private(set) var connection: TransportConnection = .unavailable
    @Published private(set) var transportKind: TransportKind = .disconnected

    private let local: LocalSocketTransport
    private var isRunning = false
    private var selectedInstance: HarnessInstance?

    init() {
        local = LocalSocketTransport(socketPath: "")
        local.onStateChanged = { [weak self] snapshot in
            guard let self, let expected = self.selectedInstance?.instanceId,
                  snapshot.instanceId == expected else { return }
            self.snapshot = snapshot
            self.transportKind = .localSocket
        }
        local.onConnectionChanged = { [weak self] status in
            guard let self else { return }
            self.connection = status
            if status == .connected {
                self.transportKind = .localSocket
            }
        }
    }

    func start() {
        guard !local.isConnected else { return }
        isRunning = true
        connection = .unavailable
        transportKind = .disconnected
        guard selectedInstance != nil else { return }
        local.connect()
    }

    /// Select the discovered Harness instance to observe. `nil` disconnects
    /// without falling through to another origin.
    func configure(instance: HarnessInstance?) {
        selectedInstance = instance
        if let instance {
            local.reconfigure(socketPath: instance.statusSocketPath, expectedInstanceID: instance.instanceId)
        } else {
            local.disconnect()
        }
        connection = .unavailable
        transportKind = .disconnected
        snapshot = .disconnected
        guard isRunning, instance != nil else { return }
        local.connect()
    }

    func stop() {
        isRunning = false
        local.disconnect()
        connection = .unavailable
        transportKind = .disconnected
        snapshot = .disconnected
    }
}
