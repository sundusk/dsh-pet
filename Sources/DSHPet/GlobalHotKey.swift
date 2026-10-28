import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

private let hotKeyLog = Logger(subsystem: "com.sundusk.dsh-pet", category: "hot-key")

/// A user-configurable global keyboard shortcut.
///
/// Carbon's global hot-key API is used instead of a global key event monitor:
/// it does not require Accessibility permission and does not consume another
/// application's key event when registration fails.
struct GlobalHotKeyConfiguration: Equatable {
    var isEnabled: Bool
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let `default` = GlobalHotKeyConfiguration(
        isEnabled: true,
        keyCode: 49, // Space
        modifiers: [.option]
    )

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayName: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + Self.keyName(for: keyCode)
    }

    /// The base key string accepted by an AppKit menu item.
    var menuKeyEquivalent: String? {
        Self.menuKeyEquivalents[keyCode]
    }

    private static let menuKeyEquivalents: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y",
        17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
            17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J",
            39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
            47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
            55: "⌘", 56: "⇧", 57: "Caps Lock", 58: "⌥", 59: "⌃", 122: "F1", 120: "F2",
            99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[keyCode] ?? "键\(keyCode)"
    }
}

enum GlobalHotKeyRegistrationError: LocalizedError {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandler(let status):
            return "快捷键服务初始化失败（错误码 \(status)）"
        case .registration(let status) where status == -9878:
            return "这个快捷键已被其他应用占用，请换一个组合键"
        case .registration(let status):
            return "快捷键注册失败（错误码 \(status)）"
        }
    }
}

/// Owns one Carbon global hot-key registration for DSHPet.
final class GlobalHotKeyManager {
    private let signature: OSType = 0x4D42414C // MBAL
    private let hotKeyID = EventHotKeyID(signature: 0x4D42414C, id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activeConfiguration: GlobalHotKeyConfiguration?

    var onTrigger: (() -> Void)?

    init() {
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func update(_ configuration: GlobalHotKeyConfiguration) -> Result<Void, Error> {
        let previous = activeConfiguration
        unregister()

        guard configuration.isEnabled else { return .success(()) }

        do {
            try register(configuration)
            activeConfiguration = configuration
            return .success(())
        } catch {
            // Keep the last valid shortcut alive while the user fixes a
            // conflicting edit in Settings.
            if let previous {
                try? register(previous)
                activeConfiguration = previous
            }
            return .failure(error)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return manager.handle(event)
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        if status != noErr {
            hotKeyLog.error("InstallEventHandler failed: \(status)")
        }
    }

    private func register(_ configuration: GlobalHotKeyConfiguration) throws {
        guard eventHandlerRef != nil else {
            throw GlobalHotKeyRegistrationError.eventHandler(-1)
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw GlobalHotKeyRegistrationError.registration(status)
        }
        hotKeyRef = ref
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        activeConfiguration = nil
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr, receivedID.signature == signature else { return noErr }
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?()
        }
        return noErr
    }
}

/// A compact native key recorder used by the Settings panel.
struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt
    @Binding var isRecording: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> HotKeyRecorderControl {
        let view = HotKeyRecorderControl()
        context.coordinator.attach(to: view)
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderControl, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: nsView)
        nsView.keyCode = keyCode
        nsView.modifiers = modifiers
        nsView.isRecording = isRecording
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var parent: HotKeyRecorderView

        init(_ parent: HotKeyRecorderView) {
            self.parent = parent
        }

        func attach(to view: HotKeyRecorderControl) {
            view.onStartRecording = { [weak self] in
                self?.parent.isRecording = true
            }
            view.onCancel = { [weak self] in
                self?.parent.isRecording = false
            }
            view.onCapture = { [weak self] keyCode, modifiers in
                guard let self else { return }
                self.parent.keyCode = keyCode
                self.parent.modifiers = modifiers
                self.parent.isRecording = false
            }
        }
    }
}

final class HotKeyRecorderControl: NSView {
    var keyCode: UInt32 = GlobalHotKeyConfiguration.default.keyCode
    var modifiers: UInt = GlobalHotKeyConfiguration.default.modifiers.rawValue
    var isRecording = false
    var onStartRecording: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCapture: ((UInt32, UInt) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onStartRecording?()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        let relevantFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        guard !relevantFlags.isEmpty else {
            NSSound.beep()
            return
        }
        onCapture?(UInt32(event.keyCode), relevantFlags.rawValue)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let fill = isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let stroke = isRecording ? NSColor.controlAccentColor : NSColor.separatorColor
        stroke.setStroke()
        let border = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        border.lineWidth = isRecording ? 1.5 : 0.8
        border.stroke()

        let title = isRecording
            ? "请按组合键（Esc 取消）"
            : GlobalHotKeyConfiguration(
                isEnabled: true,
                keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: modifiers)
            ).displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(
                x: bounds.midX - textSize.width / 2,
                y: bounds.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }
}
