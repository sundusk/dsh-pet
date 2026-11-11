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

/// Shared rendering rule for the stopped status ball. The ball is pure black,
/// so dark configured eyes would disappear; the preview, export and live pet
/// must all use the same substitute.
enum StatusBallAppearance {
    static func eyeColor(for mood: String, configured: Color) -> Color {
        mood == "stopped" ? .white : configured
    }

    static func showsStoppedRing(for mood: String) -> Bool {
        mood == "stopped"
    }
}

// MARK: - 桌宠类型与通用设置

enum FloatingPetSkin: RawRepresentable, CaseIterable, Identifiable, Hashable {
    case jingyuniang
    case jingyuniangQ
    case xiaoyu
    case xinzhizhu
    case classic
    case custom(String)

    static let allCases: [Self] = [.jingyuniang, .jingyuniangQ, .xiaoyu, .xinzhizhu, .classic]

    init?(rawValue: String) {
        switch rawValue {
        case "jingyuniang": self = .jingyuniang
        case "jingyuniangQ": self = .jingyuniangQ
        case "xiaoyu": self = .xiaoyu
        case "xinzhizhu": self = .xinzhizhu
        case "classic": self = .classic
        default:
            guard rawValue.hasPrefix("custom:"),
                  let id = UUID(uuidString: String(rawValue.dropFirst(7))) else { return nil }
            self = .custom(id.uuidString.lowercased())
        }
    }

    var rawValue: String {
        switch self {
        case .jingyuniang: return "jingyuniang"
        case .jingyuniangQ: return "jingyuniangQ"
        case .xiaoyu: return "xiaoyu"
        case .xinzhizhu: return "xinzhizhu"
        case .classic: return "classic"
        case .custom(let id): return "custom:\(id)"
        }
    }

    var isSprite: Bool { self != .classic }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "心情球"
        case .xiaoyu: return "小雨"
        case .xinzhizhu: return "新之助"
        case .jingyuniang: return "鲸鱼娘"
        case .jingyuniangQ: return "鲸鱼娘Q版"
        case .custom: return "自定义宠物"
        }
    }
}

enum DSHPetShortcutAction: String, CaseIterable, Identifiable, Hashable {
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

/// Shared pet settings, persisted under the `dsh-pet.*` namespace.
@MainActor
final class PetSettings: ObservableObject {
    static let shared = PetSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let skin = "dsh-pet.skin"
        static let ballSize = "dsh-pet.ballSize"
        static let breathingSpeed = "dsh-pet.breathingSpeed"
        static let clickThrough = "dsh-pet.clickThrough"
        static let rememberPosition = "dsh-pet.rememberPosition"
        static let showEyes = "dsh-pet.showEyes"
        static let eyeColor = "dsh-pet.eyeColor"
        static let showStatusBubble = "dsh-pet.showStatusBubble"
        static let glowEnabled = "dsh-pet.glowEnabled"
        static let lockPosition = "dsh-pet.lockPosition"
        static let isPetVisible = "dsh-pet.isPetVisible"
        static let globalHotKeyEnabled = "dsh-pet.globalHotKeyEnabled"
        static let globalHotKeyKeyCode = "dsh-pet.globalHotKeyKeyCode"
        static let globalHotKeyModifiers = "dsh-pet.globalHotKeyModifiers"
        static let shortcutPrefix = "dsh-pet.shortcut."
        static let moodColorPrefix = "dsh-pet.moodColor."
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

    @Published private(set) var shortcuts: [DSHPetShortcutAction: GlobalHotKeyConfiguration]

    /// Runtime-only feedback from the global shortcut registrar.
    @Published private(set) var globalHotKeyStatus: String?

    @Published private(set) var moodColors: [String: Color] = [:]

    @Published var disconnectedColor: Color {
        didSet { writeColor(disconnectedColor, key: Key.moodColorPrefix + "disconnected") }
    }

    var globalHotKeyConfiguration: GlobalHotKeyConfiguration {
        GlobalHotKeyConfiguration(
            isEnabled: globalHotKeyEnabled,
            keyCode: globalHotKeyKeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: globalHotKeyModifiers)
        )
    }

    func setGlobalHotKeyStatus(_ message: String?) {
        globalHotKeyStatus = message
    }

    func shortcutConfiguration(for action: DSHPetShortcutAction) -> GlobalHotKeyConfiguration {
        shortcuts[action] ?? action.defaultConfiguration
    }

    func setShortcutEnabled(_ enabled: Bool, for action: DSHPetShortcutAction) {
        var configuration = shortcutConfiguration(for: action)
        configuration.isEnabled = enabled
        setShortcutConfiguration(configuration, for: action)
    }

    func setShortcutKeyCode(_ keyCode: UInt32, for action: DSHPetShortcutAction) {
        var configuration = shortcutConfiguration(for: action)
        configuration.keyCode = keyCode
        setShortcutConfiguration(configuration, for: action)
    }

    func setShortcutModifiers(_ modifiers: UInt, for action: DSHPetShortcutAction) {
        var configuration = shortcutConfiguration(for: action)
        configuration.modifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        setShortcutConfiguration(configuration, for: action)
    }

    func resetShortcuts() {
        for action in DSHPetShortcutAction.allCases {
            setShortcutConfiguration(action.defaultConfiguration, for: action)
        }
    }

    func shortcutConflict(for action: DSHPetShortcutAction) -> String? {
        let configuration = shortcutConfiguration(for: action)
        guard configuration.isEnabled else { return nil }
        let conflicts = DSHPetShortcutAction.allCases.filter { other in
            other != action
                && shortcutConfiguration(for: other).isEnabled
                && shortcutConfiguration(for: other).keyCode == configuration.keyCode
                && shortcutConfiguration(for: other).modifiers == configuration.modifiers
        }
        guard !conflicts.isEmpty else { return nil }
        return "与 \(conflicts.map(\.label).joined(separator: "、")) 冲突，请换一个组合键"
    }

    private func setShortcutConfiguration(_ configuration: GlobalHotKeyConfiguration, for action: DSHPetShortcutAction) {
        shortcuts[action] = configuration
        let prefix = Key.shortcutPrefix + action.rawValue
        defaults.set(configuration.isEnabled, forKey: prefix + ".enabled")
        defaults.set(Int(configuration.keyCode), forKey: prefix + ".keyCode")
        defaults.set(Int(configuration.modifiers.rawValue), forKey: prefix + ".modifiers")
    }

    init(defaults: UserDefaults = .standard, petLibrary: CustomPetLibrary? = nil) {
        self.defaults = defaults
        let petLibrary = petLibrary ?? .shared
        let clamp = { (value: Double, lower: Double, upper: Double) in min(max(value, lower), upper) }

        let savedSkin = defaults.string(forKey: Key.skin)
        var initialSkin = savedSkin.flatMap { FloatingPetSkin(rawValue: $0) } ?? .jingyuniang
        if case .custom = initialSkin, !petLibrary.pets.contains(where: { $0.skin == initialSkin }) {
            initialSkin = .jingyuniang
        }
        skin = initialSkin
        if savedSkin != initialSkin.rawValue {
            defaults.set(initialSkin.rawValue, forKey: Key.skin)
        }
        ballSize = CGFloat(clamp(Self.number(defaults, for: Key.ballSize) ?? 120, 60, 200))
        breathingSpeed = clamp(Self.number(defaults, for: Key.breathingSpeed) ?? 2, 0.5, 5)
        clickThroughMode = ClickThroughMode(rawValue: Self.string(defaults, for: Key.clickThrough) ?? "") ?? .hover
        rememberPosition = Self.bool(defaults, for: Key.rememberPosition) ?? true
        globalHotKeyEnabled = defaults.object(forKey: Key.globalHotKeyEnabled) == nil
            ? GlobalHotKeyConfiguration.default.isEnabled
            : defaults.bool(forKey: Key.globalHotKeyEnabled)
        globalHotKeyKeyCode = UInt32(Self.number(defaults, for: Key.globalHotKeyKeyCode)
            ?? Double(GlobalHotKeyConfiguration.default.keyCode))
        globalHotKeyModifiers = UInt(Self.number(defaults, for: Key.globalHotKeyModifiers)
            ?? Double(GlobalHotKeyConfiguration.default.modifiers.rawValue))
        globalHotKeyStatus = nil

        var loadedShortcuts: [DSHPetShortcutAction: GlobalHotKeyConfiguration] = [:]
        for action in DSHPetShortcutAction.allCases {
            let prefix = Key.shortcutPrefix + action.rawValue
            let defaultValue = action.defaultConfiguration
            loadedShortcuts[action] = GlobalHotKeyConfiguration(
                isEnabled: defaults.object(forKey: prefix + ".enabled") == nil
                    ? defaultValue.isEnabled
                    : defaults.bool(forKey: prefix + ".enabled"),
                keyCode: UInt32(Self.number(defaults, for: prefix + ".keyCode")
                    ?? Double(defaultValue.keyCode)),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(Self.number(
                    defaults,
                    for: prefix + ".modifiers"
                ) ?? Double(defaultValue.modifiers.rawValue)))
            )
        }
        shortcuts = loadedShortcuts

        showEyes = Self.bool(defaults, for: Key.showEyes) ?? true
        eyeColor = EyeColor(rawValue: Self.string(defaults, for: Key.eyeColor) ?? "") ?? .black
        showStatusBubble = Self.bool(defaults, for: Key.showStatusBubble) ?? true
        glowEnabled = Self.bool(defaults, for: Key.glowEnabled) ?? true
        lockPosition = Self.bool(defaults, for: Key.lockPosition) ?? false
        isPetVisible = Self.bool(defaults, for: Key.isPetVisible) ?? true
        disconnectedColor = Color(hex: Self.hex(defaults, for: Key.moodColorPrefix + "disconnected") ?? disconnectedHex)

        var colors: [String: Color] = [:]
        for config in moodColorConfigs {
            let key = Key.moodColorPrefix + config.mood
            colors[config.mood] = Color(hex: Self.hex(defaults, for: key) ?? config.defaultHex)
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

    private static func number(_ defaults: UserDefaults, for key: String) -> Double? {
        if let number = defaults.object(forKey: key) as? NSNumber { return number.doubleValue }
        if let string = defaults.object(forKey: key) as? String { return Double(string) }
        return nil
    }

    private static func string(_ defaults: UserDefaults, for key: String) -> String? {
        if let string = defaults.object(forKey: key) as? String { return string }
        if let number = defaults.object(forKey: key) as? NSNumber { return number.stringValue }
        return nil
    }

    private static func bool(_ defaults: UserDefaults, for key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    private static func hex(_ defaults: UserDefaults, for key: String) -> UInt32? {
        if let string = defaults.object(forKey: key) as? String {
            return UInt32(string, radix: 16)
        }
        if let number = defaults.object(forKey: key) as? NSNumber {
            return number.uint32Value
        }
        return nil
    }

    private func writeColor(_ color: Color, key: String) {
        defaults.set(String(format: "%06X", colorToHex(color)), forKey: key)
    }
}

extension Notification.Name {
    static let dshPetResetPosition = Notification.Name("dshPetResetPosition")
}

func colorToHex(_ color: Color) -> UInt32 {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    let r = Int((resolved.redComponent * 255).rounded())
    let g = Int((resolved.greenComponent * 255).rounded())
    let b = Int((resolved.blueComponent * 255).rounded())
    return UInt32(r << 16 | g << 8 | b)
}
