import Darwin
import Foundation
import XCTest
@testable import DSHPet

final class HarnessConnectionManagerTests: XCTestCase {
    @MainActor
    func testMultipleInstancesRequireSelectionAndKeepTheSelectedSource() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let desktop = try fixture.add("desktop", kind: .desktop)
        let web = try fixture.add("web", kind: .web)
        let manager = HarnessConnectionManager(directory: fixture.directory, defaults: fixture.defaults)
        manager.refresh()
        XCTAssertEqual(manager.instances.count, 2)
        XCTAssertNil(manager.effectiveInstance)
        XCTAssertNotNil(manager.message)

        XCTAssertTrue(manager.select(desktop.id))
        XCTAssertEqual(manager.effectiveInstance?.id, desktop.id)
        XCTAssertTrue(manager.select("auto"))
        manager.refresh()
        XCTAssertEqual(manager.effectiveInstance?.id, desktop.id)

        XCTAssertTrue(manager.select(web.id))
        try fixture.remove(web.id)
        manager.refresh()
        XCTAssertNil(manager.effectiveInstance)
        XCTAssertEqual(manager.selectionID, web.id)
        XCTAssertTrue(manager.message?.contains("不会自动改连") == true)
    }

    @MainActor
    func testDraftProtectionDoesNotPersistRejectedSelection() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let first = try fixture.add("first", kind: .desktop)
        let manager = HarnessConnectionManager(directory: fixture.directory, defaults: fixture.defaults)
        manager.refresh()
        XCTAssertEqual(manager.effectiveInstance?.id, first.id)
        let second = try fixture.add("second", kind: .web)
        manager.refresh()
        manager.onTargetChange = { _ in false }
        XCTAssertFalse(manager.select(second.id))
        XCTAssertEqual(manager.effectiveInstance?.id, first.id)
        XCTAssertEqual(manager.selectionID, "auto")
        XCTAssertNil(fixture.defaults.string(forKey: "dsh-pet.harness.selection"))
    }

    @MainActor
    func testSelectionRestoresOnlySameTargetAfterRestart() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let first = try fixture.add("first", kind: .desktop, targetID: "desktop-profile-a")
        let manager = HarnessConnectionManager(directory: fixture.directory, defaults: fixture.defaults)
        manager.refresh()
        XCTAssertTrue(manager.select(first.id))
        try fixture.remove(first.id)
        let replacement = try fixture.add("replacement", kind: .desktop, targetID: "desktop-profile-a")
        _ = try fixture.add("other", kind: .desktop, targetID: "desktop-profile-b")
        let restored = HarnessConnectionManager(directory: fixture.directory, defaults: fixture.defaults)
        restored.refresh()
        XCTAssertEqual(restored.effectiveInstance?.id, replacement.id)
    }

    @MainActor
    func testMissingStableIdentityNeverAdoptsAnotherSameProfileInstance() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let first = try fixture.add("unidentified-first", kind: .desktop)
        let manager = HarnessConnectionManager(directory: fixture.directory, defaults: fixture.defaults)
        manager.refresh()
        XCTAssertTrue(manager.select(first.id))
        try fixture.remove(first.id)
        let other = try fixture.add("unidentified-other", kind: .desktop)
        XCTAssertNotEqual(first.bindingKey, other.bindingKey)
        manager.refresh()
        XCTAssertNil(manager.effectiveInstance)
        XCTAssertEqual(manager.selectionID, first.id)
    }

    @MainActor
    func testDiscoveryRejectsDeadProcessesAndUntrustedAddresses() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        _ = try fixture.add("valid", kind: .web)
        var dead = try fixture.add("dead", kind: .web)
        dead = HarnessInstance(
            protocolVersion: 1, instanceId: dead.id, kind: dead.kind, profile: dead.profile,
            pid: Int32.max, startedAt: dead.startedAt, webURL: dead.webURL,
            statusSocketPath: dead.statusSocketPath, commandSocketPath: dead.commandSocketPath
        )
        try fixture.write(dead)
        let invalid = try fixture.add("invalid", kind: .web)
        let malicious = HarnessInstance(
            protocolVersion: 1, instanceId: invalid.id, kind: .web, profile: "web",
            pid: getpid(), startedAt: 1, webURL: "https://example.com/?token=private",
            statusSocketPath: invalid.statusSocketPath, commandSocketPath: invalid.commandSocketPath
        )
        try fixture.write(malicious)
        XCTAssertEqual(HarnessConnectionManager.discover(in: fixture.directory).map(\.id), ["valid"])
    }

    func testWebURLValidationRejectsCredentialsAndUnsafeSchemes() {
        XCTAssertNotNil(HarnessInstance.safeWebURL("http://127.0.0.1:3080", loopbackOnly: true))
        XCTAssertNotNil(HarnessInstance.safeWebURL("http://[::1]:3080", loopbackOnly: true))
        XCTAssertNil(HarnessInstance.safeWebURL("http://user:secret@localhost:3080", loopbackOnly: true))
        XCTAssertNil(HarnessInstance.safeWebURL("file:///tmp/a"))
        XCTAssertNil(HarnessInstance.safeWebURL("https://example.com", loopbackOnly: true))
        XCTAssertNil(HarnessInstance.safeWebURL("http://localhost:3080?token=secret"))
    }
}

private final class RegistryFixture {
    let directory: URL
    let defaults: UserDefaults
    private let suite: String
    private var descriptors: [Int32] = []

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/dsh-registry-\(UUID().uuidString.prefix(8))")
        suite = "HarnessRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func add(_ id: String, kind: HarnessInstance.Kind, targetID: String? = nil) throws -> HarnessInstance {
        let status = directory.appendingPathComponent("\(id)-s.sock").path
        let command = directory.appendingPathComponent("\(id)-c.sock").path
        try bindSocket(status)
        try bindSocket(command)
        let instance = HarnessInstance(
            protocolVersion: 1, instanceId: id, kind: kind, profile: kind.rawValue,
            pid: getpid(), startedAt: 1, webURL: "http://127.0.0.1:3080",
            statusSocketPath: status, commandSocketPath: command, targetId: targetID
        )
        try write(instance)
        return instance
    }

    func write(_ instance: HarnessInstance) throws {
        try JSONEncoder().encode(instance).write(to: directory.appendingPathComponent("\(instance.id).json"))
    }

    func remove(_ id: String) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    func cleanup() {
        for descriptor in descriptors { Darwin.close(descriptor) }
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func bindSocket(_ path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        descriptors.append(descriptor)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map(UInt8.init(bitPattern:))) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(descriptor, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
    }
}
