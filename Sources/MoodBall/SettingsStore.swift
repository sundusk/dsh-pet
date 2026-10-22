import Foundation
import AppKit
import SwiftUI

// MARK: - 状态颜色契约

struct MoodColorConfig {
    let mood: String
    let label: String
    let defaultHex: UInt32
}

let moodColorConfigs: [MoodColorConfig] = [
    MoodColorConfig(mood: "idle", label: "空闲", defaultHex: 0x60a5fa),
    MoodColorConfig(mood: "waiting", label: "正在思考中", defaultHex: 0x34d399),
    MoodColorConfig(mood: "jumping", label: "工具调用", defaultHex: 0xa855f7),
    MoodColorConfig(mood: "authorizing", label: "等待你的授权", defaultHex: 0xfacc15),
    MoodColorConfig(mood: "questioning", label: "做出你的抉择", defaultHex: 0xec4899),
    MoodColorConfig(mood: "done", label: "搞定啦", defaultHex: 0x22d3ee),
    MoodColorConfig(mood: "failed", label: "出错了", defaultHex: 0xf87171),
    MoodColorConfig(mood: "stopped", label: "已停止", defaultHex: 0x000000),
]

let disconnectedHex: UInt32 = 0x9ca3af

// MARK: - 桌宠类型与通用设置

enum FloatingPetSkin: String, CaseIterable, Identifiable {
    case jingyuniang
    case xiaoyu
    case xinzhizhu
    case moodBall

    var isSprite: Bool { self != .moodBall }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moodBall: return "心情球"
        case .xiaoyu: return "小雨"
        case .xinzhizhu: return "新之助"
        case .jingyuniang: return "鲸鱼娘"
        }
    }
}

enum MoodBallShortcutAction: String, CaseIterable, Identifiable, Hashable {
    case inputMessage
    case newSession
    case selectWorkspace
    case openHarness
    case togglePetVisibility
    case openSettings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inputMessage: return "输入消息"
        case .newSession: return "新建会话"
        case .selectWorkspace: return "选择工作区"
        case .openHarness: return "打开 Harness"
        case .togglePetVisibility: return "显示 / 隐藏宠物"
        case .openSettings: return "打开设置"
        }
    }

    var defaultConfiguration: GlobalHotKeyConfiguration {
        switch self {
        case .inputMessage:
            return GlobalHotKeyConfiguration(isEnabled: true, keyCode: 45, modifiers: [.command]) // ⌘N
        case .newSession:
            return GlobalHotKeyConfiguration(isEnabled: true, keyCode: 45, modifiers: [.command, .shift]) // ⌘⇧N
        case .selectWorkspace:
            return GlobalHotKeyConfiguration(isEnabled: true, keyCode: 31, modifiers: [.command]) // ⌘O
        case .openHarness:
            return GlobalHotKeyConfiguration(isEnabled: true, keyCode: 31, modifiers: [.command, .shift]) // ⌘⇧O
        case .togglePetVisibility:
            return GlobalHotKeyConfiguration(isEnabled: true, keyCode: 35, modifiers: [.command, .shift]) // ⌘⇧P
        case .openSettings:
            return GlobalHotKeyConfiguration(isEnabled: true, keyCode: 43, modifiers: [.command]) // ⌘,
        }
    }
}

enum ClickThroughMode: String, CaseIterable, Identifiable {
    case hover
    case always
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hover: return "悬停时恢复响应"
        case .always: return "永远点击穿透"
        case .never: return "永不穿透"
        }
    }
}

enum EyeColor: String, CaseIterable, Identifiable {
    case white
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "白色"
        case .black: return "黑色"
        }
    }

    var color: Color {
        switch self {
        case .white: return .white
        case .black: return .black
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Shared pet settings. New values live under `moodball.*`; old `settings.*`
/// values are read as a compatibility fallback.
@MainActor
final class PetSettings: ObservableObject {
    static let shared = PetSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let skin = "moodball.skin"
        static let ballSize = "moodball.ballSize"
        static let breathingSpeed = "moodball.breathingSpeed"
        static let apiBase = "moodball.apiBase"
        static let pollInterval = "moodball.pollInterval"
        static let requestTimeout = "moodball.requestTimeout"
        static let clickThrough = "moodball.clickThrough"
        static let rememberPosition = "moodball.rememberPosition"
        static let showEyes = "moodball.showEyes"
        static let eyeColor = "moodball.eyeColor"
        static let showStatusBubble = "moodball.showStatusBubble"
        static let glowEnabled = "moodball.glowEnabled"
        static let lockPosition = "moodball.lockPosition"
        static let isPetVisible = "moodball.isPetVisible"
        static let positionX = "moodball.ballPositionX"
        static let positionY = "moodball.ballPositionY"
        static let globalHotKeyEnabled = "moodball.globalHotKeyEnabled"
        static let globalHotKeyKeyCode = "moodball.globalHotKeyKeyCode"
        static let globalHotKeyModifiers = "moodball.globalHotKeyModifiers"
        static let shortcutPrefix = "moodball.shortcut."
        static let moodColorPrefix = "moodball.moodColor."
    }

    private enum LegacyKey {
        static let isBallVisible = "moodball.isBallVisible"
        static let ballSize = "settings.ballSize"
        static let breathingSpeed = "settings.breathingSpeed"
        static let apiBase = "settings.apiBase"
        static let pollInterval = "settings.pollInterval"
        static let requestTimeout = "settings.requestTimeout"
        static let clickThrough = "settings.clickThrough"
        static let rememberPosition = "settings.rememberPosition"
        static let showEyes = "settings.showEyes"
        static let eyeColor = "settings.eyeColor"
        static let showStatusBubble = "settings.showStatusBubble"
        static let glowEnabled = "settings.glowEnabled"
        static let lockPosition = "settings.lockPosition"
        static let positionX = "ballPositionX"
        static let positionY = "ballPositionY"
        static let moodColorPrefix = "settings.moodColor."
    }

    @Published var skin: FloatingPetSkin {
        didSet { defaults.set(skin.rawValue, forKey: Key.skin) }
    }

    @Published var ballSize: CGFloat {
        didSet { defaults.set(Double(ballSize), forKey: Key.ballSize) }
    }

    @Published var breathingSpeed: Double {
        didSet { defaults.set(breathingSpeed, forKey: Key.breathingSpeed) }
    }

    @Published var showStatusBubble: Bool {
        didSet { defaults.set(showStatusBubble, forKey: Key.showStatusBubble) }
    }

    @Published var glowEnabled: Bool {
        didSet { defaults.set(glowEnabled, forKey: Key.glowEnabled) }
    }

    @Published var isPetVisible: Bool {
        didSet { defaults.set(isPetVisible, forKey: Key.isPetVisible) }
    }

    @Published var lockPosition: Bool {
        didSet { defaults.set(lockPosition, forKey: Key.lockPosition) }
    }

    @Published var showEyes: Bool {
        didSet { defaults.set(showEyes, forKey: Key.showEyes) }
    }

    @Published var eyeColor: EyeColor {
        didSet { defaults.set(eyeColor.rawValue, forKey: Key.eyeColor) }
    }

    @Published var apiBase: String {
        didSet { defaults.set(apiBase, forKey: Key.apiBase) }
    }

    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Key.pollInterval) }
    }

    @Published var requestTimeout: Double {
        didSet { defaults.set(requestTimeout, forKey: Key.requestTimeout) }
    }

    @Published var clickThroughMode: ClickThroughMode {
        didSet { defaults.set(clickThroughMode.rawValue, forKey: Key.clickThrough) }
    }

    @Published var rememberPosition: Bool {
        didSet { defaults.set(rememberPosition, forKey: Key.rememberPosition) }
    }

    @Published var globalHotKeyEnabled: Bool {
        didSet { defaults.set(globalHotKeyEnabled, forKey: Key.globalHotKeyEnabled) }
    }

    @Published var globalHotKeyKeyCode: UInt32 {
        didSet { defaults.set(Int(globalHotKeyKeyCode), forKey: Key.globalHotKeyKeyCode) }
    }

    @Published var globalHotKeyModifiers: UInt {
        didSet { defaults.set(Int(globalHotKeyModifiers), forKey: Key.globalHotKeyModifiers) }
    }

    @Published private(set) var shortcuts: [MoodBallShortcutAction: GlobalHotKeyConfiguration]

    /// Runtime-only feedback from the global shortcut registrar.
    @Published private(set) var globalHotKeyStatus: String?

    @Published private(set) var moodColors: [String: Color] = [:]

    @Published var disconnectedColor: Color {
        didSet { writeColor(disconnectedColor, key: Key.moodColorPrefix + "disconnected") }
    }

    var savedBallPosition: CGPoint? {
        get {
            guard let x = Self.number(defaults, for: Key.positionX, legacy: LegacyKey.positionX),
                  let y = Self.number(defaults, for: Key.positionY, legacy: LegacyKey.positionY) else { return nil }
            return CGPoint(x: x, y: y)
        }
        set {
            if let newValue {
                defaults.set(Double(newValue.x), forKey: Key.positionX)
                defaults.set(Double(newValue.y), forKey: Key.positionY)
            } else {
                defaults.removeObject(forKey: Key.positionX)
                defaults.removeObject(forKey: Key.positionY)
            }
        }
    }

    var globalHotKeyConfiguration: GlobalHotKeyConfiguration {
        GlobalHotKeyConfiguration(
            isEnabled: globalHotKeyEnabled,
            keyCode: globalHotKeyKeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: globalHotKeyModifiers)
        )
    }

    var globalHotKeyDisplayName: String {
        globalHotKeyConfiguration.displayName
    }

    func setGlobalHotKeyStatus(_ message: String?) {
        globalHotKeyStatus = message
    }

    func shortcutConfiguration(for action: MoodBallShortcutAction) -> GlobalHotKeyConfiguration {
        shortcuts[action] ?? action.defaultConfiguration
    }

    func setShortcutEnabled(_ enabled: Bool, for action: MoodBallShortcutAction) {
        var configuration = shortcutConfiguration(for: action)
        configuration.isEnabled = enabled
        setShortcutConfiguration(configuration, for: action)
    }

    func setShortcutKeyCode(_ keyCode: UInt32, for action: MoodBallShortcutAction) {
        var configuration = shortcutConfiguration(for: action)
        configuration.keyCode = keyCode
        setShortcutConfiguration(configuration, for: action)
    }

    func setShortcutModifiers(_ modifiers: UInt, for action: MoodBallShortcutAction) {
        var configuration = shortcutConfiguration(for: action)
        configuration.modifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        setShortcutConfiguration(configuration, for: action)
    }

    func resetShortcuts() {
        for action in MoodBallShortcutAction.allCases {
            setShortcutConfiguration(action.defaultConfiguration, for: action)
        }
    }

    func shortcutConflict(for action: MoodBallShortcutAction) -> String? {
        let configuration = shortcutConfiguration(for: action)
        guard configuration.isEnabled else { return nil }
        let conflicts = MoodBallShortcutAction.allCases.filter { other in
            other != action
                && shortcutConfiguration(for: other).isEnabled
                && shortcutConfiguration(for: other).keyCode == configuration.keyCode
                && shortcutConfiguration(for: other).modifiers == configuration.modifiers
        }
        guard !conflicts.isEmpty else { return nil }
        return "与 \(conflicts.map(\.label).joined(separator: "、")) 冲突，请换一个组合键"
    }

    private func setShortcutConfiguration(_ configuration: GlobalHotKeyConfiguration, for action: MoodBallShortcutAction) {
        shortcuts[action] = configuration
        let prefix = Key.shortcutPrefix + action.rawValue
        defaults.set(configuration.isEnabled, forKey: prefix + ".enabled")
        defaults.set(Int(configuration.keyCode), forKey: prefix + ".keyCode")
        defaults.set(Int(configuration.modifiers.rawValue), forKey: prefix + ".modifiers")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let clamp = { (value: Double, lower: Double, upper: Double) in min(max(value, lower), upper) }

        let savedSkin = defaults.string(forKey: Key.skin)
        let initialSkin = savedSkin.flatMap { FloatingPetSkin(rawValue: $0) } ?? .jingyuniang
        skin = initialSkin
        if savedSkin != initialSkin.rawValue {
            defaults.set(initialSkin.rawValue, forKey: Key.skin)
        }
        ballSize = CGFloat(clamp(Self.number(defaults, for: Key.ballSize, legacy: LegacyKey.ballSize) ?? 120, 60, 200))
        breathingSpeed = clamp(Self.number(defaults, for: Key.breathingSpeed, legacy: LegacyKey.breathingSpeed) ?? 2, 0.5, 5)
        apiBase = Self.string(defaults, for: Key.apiBase, legacy: LegacyKey.apiBase) ?? "http://127.0.0.1:3080"
        pollInterval = clamp(Self.number(defaults, for: Key.pollInterval, legacy: LegacyKey.pollInterval) ?? 0.7, 0.3, 5)
        requestTimeout = clamp(Self.number(defaults, for: Key.requestTimeout, legacy: LegacyKey.requestTimeout) ?? 2, 0.5, 5)
        clickThroughMode = ClickThroughMode(rawValue: Self.string(defaults, for: Key.clickThrough, legacy: LegacyKey.clickThrough) ?? "") ?? .hover
        rememberPosition = Self.bool(defaults, for: Key.rememberPosition, legacy: LegacyKey.rememberPosition) ?? true
        globalHotKeyEnabled = defaults.object(forKey: Key.globalHotKeyEnabled) == nil
            ? GlobalHotKeyConfiguration.default.isEnabled
            : defaults.bool(forKey: Key.globalHotKeyEnabled)
        globalHotKeyKeyCode = UInt32(Self.number(defaults, for: Key.globalHotKeyKeyCode, legacy: Key.globalHotKeyKeyCode)
            ?? Double(GlobalHotKeyConfiguration.default.keyCode))
        globalHotKeyModifiers = UInt(Self.number(defaults, for: Key.globalHotKeyModifiers, legacy: Key.globalHotKeyModifiers)
            ?? Double(GlobalHotKeyConfiguration.default.modifiers.rawValue))
        globalHotKeyStatus = nil

        var loadedShortcuts: [MoodBallShortcutAction: GlobalHotKeyConfiguration] = [:]
        for action in MoodBallShortcutAction.allCases {
            let prefix = Key.shortcutPrefix + action.rawValue
            let defaultValue = action.defaultConfiguration
            loadedShortcuts[action] = GlobalHotKeyConfiguration(
                isEnabled: defaults.object(forKey: prefix + ".enabled") == nil
                    ? defaultValue.isEnabled
                    : defaults.bool(forKey: prefix + ".enabled"),
                keyCode: UInt32(Self.number(defaults, for: prefix + ".keyCode", legacy: prefix + ".keyCode")
                    ?? Double(defaultValue.keyCode)),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(Self.number(
                    defaults,
                    for: prefix + ".modifiers",
                    legacy: prefix + ".modifiers"
                ) ?? Double(defaultValue.modifiers.rawValue)))
            )
        }
        shortcuts = loadedShortcuts

        showEyes = Self.bool(defaults, for: Key.showEyes, legacy: LegacyKey.showEyes) ?? true
        eyeColor = EyeColor(rawValue: Self.string(defaults, for: Key.eyeColor, legacy: LegacyKey.eyeColor) ?? "") ?? .black
        showStatusBubble = Self.bool(defaults, for: Key.showStatusBubble, legacy: LegacyKey.showStatusBubble) ?? true
        glowEnabled = Self.bool(defaults, for: Key.glowEnabled, legacy: LegacyKey.glowEnabled) ?? true
        lockPosition = Self.bool(defaults, for: Key.lockPosition, legacy: LegacyKey.lockPosition) ?? false
        isPetVisible = Self.bool(defaults, for: Key.isPetVisible, legacy: LegacyKey.isBallVisible) ?? true
        disconnectedColor = Color(hex: Self.hex(defaults, for: Key.moodColorPrefix + "disconnected", legacy: LegacyKey.moodColorPrefix + "disconnected") ?? disconnectedHex)

        var colors: [String: Color] = [:]
        for config in moodColorConfigs {
            let key = Key.moodColorPrefix + config.mood
            let legacy = LegacyKey.moodColorPrefix + config.mood
            colors[config.mood] = Color(hex: Self.hex(defaults, for: key, legacy: legacy) ?? config.defaultHex)
        }
        moodColors = colors
    }

    func setMoodColor(_ mood: String, _ color: Color) {
        moodColors[mood] = color
        writeColor(color, key: Key.moodColorPrefix + mood)
    }

    func resetMoodColors() {
        var colors: [String: Color] = [:]
        for config in moodColorConfigs {
            colors[config.mood] = Color(hex: config.defaultHex)
            defaults.removeObject(forKey: Key.moodColorPrefix + config.mood)
        }
        moodColors = colors
        disconnectedColor = Color(hex: disconnectedHex)
        defaults.removeObject(forKey: Key.moodColorPrefix + "disconnected")
    }

    func resetPositionRequested() {
        NotificationCenter.default.post(name: .waterballResetPosition, object: nil)
    }

    private static func storedValue(_ defaults: UserDefaults, for key: String, legacy: String) -> Any? {
        defaults.object(forKey: key) ?? defaults.object(forKey: legacy)
    }

    private static func number(_ defaults: UserDefaults, for key: String, legacy: String) -> Double? {
        if let number = storedValue(defaults, for: key, legacy: legacy) as? NSNumber { return number.doubleValue }
        if let string = storedValue(defaults, for: key, legacy: legacy) as? String { return Double(string) }
        return nil
    }

    private static func string(_ defaults: UserDefaults, for key: String, legacy: String) -> String? {
        if let string = storedValue(defaults, for: key, legacy: legacy) as? String { return string }
        if let number = storedValue(defaults, for: key, legacy: legacy) as? NSNumber { return number.stringValue }
        return nil
    }

    private static func bool(_ defaults: UserDefaults, for key: String, legacy: String) -> Bool? {
        guard storedValue(defaults, for: key, legacy: legacy) != nil else { return nil }
        return defaults.bool(forKey: defaults.object(forKey: key) != nil ? key : legacy)
    }

    private static func hex(_ defaults: UserDefaults, for key: String, legacy: String) -> UInt32? {
        if let string = defaults.object(forKey: key) as? String ?? defaults.object(forKey: legacy) as? String {
            return UInt32(string, radix: 16)
        }
        if let number = defaults.object(forKey: key) as? NSNumber ?? defaults.object(forKey: legacy) as? NSNumber {
            return number.uint32Value
        }
        return nil
    }

    private func writeColor(_ color: Color, key: String) {
        defaults.set(String(format: "%06X", colorToHex(color)), forKey: key)
    }
}

/// Compatibility name retained while downstream source adopts `PetSettings`.
typealias SettingsStore = PetSettings

extension Notification.Name {
    static let waterballResetPosition = Notification.Name("waterballResetPosition")
    static let waterballToggleSettings = Notification.Name("waterballToggleSettings")
}

func colorToHex(_ color: Color) -> UInt32 {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    let r = Int((resolved.redComponent * 255).rounded())
    let g = Int((resolved.greenComponent * 255).rounded())
    let b = Int((resolved.blueComponent * 255).rounded())
    return UInt32(r << 16 | g << 8 | b)
}
