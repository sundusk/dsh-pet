import Darwin
import Foundation
import XCTest
@testable import DSHPet

final class LocalSocketTransportTests: XCTestCase {
    @MainActor
    func testConnectsAfterServerStartsAndRestarts() async throws {
        // macOS Unix socket paths have a short fixed limit; /tmp stays below it.
        let path = "/tmp/dsh-pet-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = LocalSocketTransport(socketPath: path)
        let firstSnapshot = expectation(description: "late server snapshot")
        let secondSnapshot = expectation(description: "restarted server snapshot")
        var snapshotCount = 0
        transport.onStateChanged = { snapshot in
            guard snapshot.mood == "idle" else { return }
            snapshotCount += 1
            if snapshotCount == 1 { firstSnapshot.fulfill() }
            if snapshotCount == 2 { secondSnapshot.fulfill() }
        }
        transport.connect()
        defer { transport.disconnect() }

        // Let the first connection fail before the plugin creates its socket.
        try await Task.sleep(nanoseconds: 250_000_000)
        var server: Int32? = try startServer(at: path)
        defer { if let server { Darwin.close(server) } }

        await fulfillment(of: [firstSnapshot], timeout: 5)
        Darwin.close(server!)
        server = nil
        try FileManager.default.removeItem(atPath: path)

        // The first accepted connection closes, then the plugin rebinds the path.
        try await Task.sleep(nanoseconds: 1_250_000_000)
        server = try startServer(at: path)
        await fulfillment(of: [secondSnapshot], timeout: 5)
        XCTAssertTrue(transport.isConnected)
    }

    @MainActor
    func testExplicitTransportWaitsForAndRequiresMatchingInstanceSnapshot() async throws {
        let path = "/tmp/dsh-pet-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = LocalSocketTransport(socketPath: path, expectedInstanceID: "expected")
        let connected = expectation(description: "validated connection")
        var snapshots = 0
        transport.onConnectionChanged = { status in
            if status == .connected { connected.fulfill() }
        }
        transport.onStateChanged = { _ in snapshots += 1 }
        transport.connect()
        defer { transport.disconnect() }

        var server: Int32? = try startServer(
            at: path,
            payload: "{\"instanceId\":\"wrong\",\"state\":\"idle\",\"mood\":\"idle\"}\n"
        )
        defer { if let server { Darwin.close(server) } }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(transport.isConnected)
        XCTAssertEqual(snapshots, 0)

        transport.disconnect()
        Darwin.close(server!)
        server = nil
        try? FileManager.default.removeItem(atPath: path)
        let matchingServer = try startServer(
            at: path,
            payload: "{\"instanceId\":\"expected\",\"state\":\"idle\",\"mood\":\"idle\"}\n"
        )
        defer { Darwin.close(matchingServer) }
        transport.connect()
        await fulfillment(of: [connected], timeout: 5)
        XCTAssertTrue(transport.isConnected)
    }

    private func startServer(
        at path: String,
        payload: String = "{\"state\":\"idle\",\"mood\":\"idle\"}\n"
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

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

        DispatchQueue.global().async {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let bytesToWrite = Array(payload.utf8)
            bytesToWrite.withUnsafeBytes { bytes in
                _ = Darwin.write(client, bytes.baseAddress, bytes.count)
            }
            Thread.sleep(forTimeInterval: 1)
            Darwin.close(client)
        }
        return descriptor
    }
}
