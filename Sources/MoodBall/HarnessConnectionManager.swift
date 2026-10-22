import AppKit
import Combine
import Darwin
import Foundation

struct HarnessInstance: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case desktop, web, unknown
    }

    let protocolVersion: Int
    let instanceId: String
    let kind: Kind
    let profile: String?
    let pid: Int32
    let startedAt: TimeInterval
    let webURL: String?
    let statusSocketPath: String
    let commandSocketPath: String
    var targetId: String? = nil

    var id: String { instanceId }

    var displayName: String {
        let name: String
        switch kind {
        case .desktop: name = "DeepSeek Harness 桌面版"
        case .web: name = "DeepSeek Harness 网页版"
        case .unknown: name = "Harness（来源未知）"
        }
        return profile.map { "\(name) · \($0)" } ?? name
    }

    // Only a profile identity supplied by the plugin can justify reusing a binding after restart.
    var bindingKey: String { targetId ?? "instance:\(instanceId)" }

    static func safeWebURL(_ value: String?, loopbackOnly: Bool = false) -> URL? {
        guard let value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        if loopbackOnly && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return nil }
        return url
    }
}

/// Discovers plugin-owned instances without starting, stopping or modifying Harness.
@MainActor
final class HarnessConnectionManager: ObservableObject {
    @Published private(set) var instances: [HarnessInstance] = []
    @Published private(set) var effectiveInstance: HarnessInstance?
    @Published private(set) var selectionID: String
    @Published private(set) var isDiscovering = false
    @Published private(set) var message: String?
    @Published private(set) var openingError: String?

    /// Called before changing channels so the command client can protect pending input.
    var onTargetChange: ((HarnessInstance?) -> Bool)?
    var onRefresh: (() -> Void)?

    nonisolated static var registryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoodBall/instances", isDirectory: true)
    }

    private let directory: URL
    private let defaults: UserDefaults
    private var discoveryTask: Task<Void, Never>?
    private var preferredBindingKey: String?
    private static let selectionKey = "moodball.harness.selection"
    private static let bindingKey = "moodball.harness.binding"

    init(directory: URL = HarnessConnectionManager.registryDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        selectionID = defaults.string(forKey: Self.selectionKey) ?? "auto"
        preferredBindingKey = defaults.string(forKey: Self.bindingKey)
    }

    func start() {
        guard discoveryTask == nil else { return }
        refresh()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    func refresh() {
        isDiscovering = true
        defer {
            isDiscovering = false
            onRefresh?()
        }
        instances = Self.discover(in: directory)
        reconcile()
    }

    @discardableResult
    func select(_ id: String) -> Bool {
        guard id == "auto" || instances.contains(where: { $0.id == id }) else { return false }
        let previousSelection = selectionID
        let previousPreference = preferredBindingKey
        selectionID = id
        preferredBindingKey = id == "auto" ? nil : instances.first(where: { $0.id == id })?.bindingKey
        guard reconcile() else {
            selectionID = previousSelection
            preferredBindingKey = previousPreference
            return false
        }
        defaults.set(selectionID, forKey: Self.selectionKey)
        defaults.set(preferredBindingKey, forKey: Self.bindingKey)
        return true
    }

    @discardableResult
    private func reconcile() -> Bool {
        let candidate: HarnessInstance?
        if selectionID == "auto" {
            // Keep the current source when another Harness appears during a task.
            candidate = instances.first(where: { $0.id == effectiveInstance?.id })
                ?? (instances.count == 1 ? instances.first : nil)
        } else {
            let replacements = instances.filter { $0.bindingKey == preferredBindingKey }
            candidate = instances.first(where: { $0.id == selectionID })
                ?? (replacements.count == 1 ? replacements.first : nil)
        }
        if candidate != effectiveInstance {
            guard onTargetChange?(candidate) ?? true else {
                message = "请先处理当前草稿或未确认的消息，再切换 Harness。"
                return false
            }
            effectiveInstance = candidate
        }
        if selectionID != "auto", let candidate, selectionID != candidate.id {
            selectionID = candidate.id
            defaults.set(selectionID, forKey: Self.selectionKey)
        }
        if effectiveInstance == nil {
            if instances.count > 1 {
                message = "检测到多个 Harness，请选择本次连接的目标。"
            } else if selectionID != "auto" {
                message = "选定的 Harness 未运行。不会自动改连其他目标。"
            } else {
                message = "未发现新版桥接实例。旧版连接只能显示来源未知；升级桥接插件后可选择目标。"
            }
        } else {
            message = nil
        }
        return true
    }

    static func discover(in directory: URL) -> [HarnessInstance] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return files.prefix(256).compactMap { file -> HarnessInstance? in
            guard file.pathExtension == "json", isOwnedFile(file.path, type: S_IFREG),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 16_384,
                  let data = try? Data(contentsOf: file),
                  let instance = try? JSONDecoder().decode(HarnessInstance.self, from: data),
                  instance.protocolVersion == 1,
                  !instance.id.isEmpty, instance.id.count <= 128,
                  file.deletingPathExtension().lastPathComponent == instance.id,
                  instance.pid > 1, kill(instance.pid, 0) == 0,
                  instance.startedAt.isFinite,
                  instance.statusSocketPath != instance.commandSocketPath,
                  validSocket(instance.statusSocketPath), validSocket(instance.commandSocketPath),
                  instance.webURL == nil || HarnessInstance.safeWebURL(instance.webURL, loopbackOnly: true) != nil
            else { return nil }
            return instance
        }.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    private static func validSocket(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count < 104 && isOwnedFile(path, type: S_IFSOCK)
    }

    private static func isOwnedFile(_ path: String, type: mode_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == type
    }

    func open(legacyWebAddress: String, legacyConnected: Bool = false) {
        openingError = nil
        guard let instance = effectiveInstance else {
            guard legacyConnected, instances.isEmpty, selectionID == "auto",
                  let url = HarnessInstance.safeWebURL(legacyWebAddress) else {
                openingError = "请先选择可用的 Harness；旧版插件需升级后才能识别打开目标。"
                return
            }
            if !NSWorkspace.shared.open(url) { openingError = "无法打开配置的 Harness 网页地址。" }
            return
        }
        switch instance.kind {
        case .desktop:
            guard let url = Self.desktopApplicationURL(for: instance.pid) else {
                openingError = "未找到该实例所属的桌面应用，请重新检测连接。"
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                if error != nil {
                    Task { @MainActor in self?.openingError = "无法唤起选定的 Harness 桌面版。" }
                }
            }
        case .web:
            guard let url = HarnessInstance.safeWebURL(instance.webURL, loopbackOnly: true) else {
                openingError = "该网页版尚未提供可验证的访问地址。"
                return
            }
            if !NSWorkspace.shared.open(url) { openingError = "无法打开该 Harness 网页版。" }
        case .unknown:
            openingError = "此桥接未报告运行类型，无法可靠确定打开目标。请升级桥接插件或从原入口打开 Harness。"
        }
    }

    private static func desktopApplicationURL(for pid: Int32) -> URL? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier, !$0.isTerminated else { return false }
            return id == "com.deepseek.dsh" || id.hasPrefix("com.deepseek.harness.dev.")
        }
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted {
            if let app = apps.first(where: { $0.processIdentifier == current }) { return app.bundleURL }
            var info = kinfo_proc()
            var length = MemoryLayout<kinfo_proc>.stride
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&query, UInt32(query.count), &info, &length, nil, 0) == 0, length > 0 else { return nil }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }
}
