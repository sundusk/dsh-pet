import AppKit
import SwiftUI
import Combine
import QuartzCore
import os

private let appLog = Logger(subsystem: "com.sundusk.moodball", category: "app")

/// 置顶悬浮窗：透明、无边框、不抢焦点、点击穿透。
/// 鼠标移入球体范围时恢复响应（可拖拽），移出后再次穿透。
/// 拖拽由 SwiftUI 手势驱动（见 MoodBallView），位置持久化到 UserDefaults。
final class MoodBallPanel: NSPanel {
    /// 供 SwiftUI 拖拽手势引用当前悬浮窗
    static weak var current: MoodBallPanel?

    /// 拖拽进行中（悬停检测据此保持响应，避免拖到一半变成点击穿透）
    var isDragging = false
    var onRightClick: ((NSPoint) -> Void)?

    private enum PositionKeys {
        static let x = "moodball.ballPositionX"
        static let y = "moodball.ballPositionY"
        static let legacyX = "ballPositionX"
        static let legacyY = "ballPositionY"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }

    /// 尝试恢复上次拖拽保存的位置；仅当设置允许且窗口中心仍在某个屏幕可视区内才生效
    @discardableResult
    func restoreSavedPosition() -> Bool {
        guard SettingsStore.shared.rememberPosition else { return false }
        let defaults = UserDefaults.standard
        let x = (defaults.object(forKey: PositionKeys.x) as? NSNumber
            ?? defaults.object(forKey: PositionKeys.legacyX) as? NSNumber)?.doubleValue
        let y = (defaults.object(forKey: PositionKeys.y) as? NSNumber
            ?? defaults.object(forKey: PositionKeys.legacyY) as? NSNumber)?.doubleValue
        guard let x, let y else { return false }
        // 用「窗口中心」判断而非整窗相交：避免显示器变化后只留一截在屏边、球心在屏外
        let center = NSPoint(x: x + self.frame.width / 2, y: y + self.frame.height / 2)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard visibleFrames.contains(where: { $0.contains(center) }) else { return false }
        setFrameOrigin(NSPoint(x: x, y: y))
        return true
    }

    /// 拖拽结束时保存当前位置（受「记住位置」设置控制）
    func persistPosition() {
        guard SettingsStore.shared.rememberPosition else { return }
        UserDefaults.standard.set(Double(frame.origin.x), forKey: PositionKeys.x)
        UserDefaults.standard.set(Double(frame.origin.y), forKey: PositionKeys.y)
        appLog.info("persistPosition -> \(Int(self.frame.origin.x)),\(Int(self.frame.origin.y))")
    }
}

/// Separate control surface below the pet. Keeping it in its own panel means
/// expanding the composer never changes the pet window's drag anchor or size.
final class MoodBallComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

final class MoodBallTaskPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class PetContextPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PetContextView: View {
    let hidePet: () -> Void

    var body: some View {
        Button(action: hidePet) {
            Text("隐藏宠物")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 88, height: 32)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.42, alpha: 0.76)),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("隐藏宠物")
        .frame(width: 104, height: 48)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MoodBallModel.shared
    private var panel: MoodBallPanel?
    private var composerPanel: MoodBallComposerPanel?
    private var taskPanel: MoodBallTaskPanel?
    private var petContextPanel: PetContextPanel?
    private var petContextMonitors: [Any] = []
    private var settingsPanel: NSPanel?
    private var hoverMonitors: [Any] = []
    private var visibilitySink: AnyCancellable?
    private var settingsSink: AnyCancellable?
    private var bubbleSink: AnyCancellable?
    private var composerSink: AnyCancellable?
    private var taskPanelSink: AnyCancellable?
    private var commandSink: AnyCancellable?
    private var hotKeySink: AnyCancellable?
    private var resignObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var statusSink: AnyCancellable?
    private var statusHeaderItem: NSMenuItem?
    private var togglePetMenuItem: NSMenuItem?
    private var shortcutMenuItems: [MoodBallShortcutAction: [NSMenuItem]] = [:]
    private var lastIconColor: Color?
    private let globalHotKeyManager = GlobalHotKeyManager()
    private var taskPanelEventMonitors: [Any] = []
    private var isTaskPanelClosing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫：若已有同 Bundle ID 的实例在运行，本实例立即退出。
        // （从 Spotlight/访达重复点击，或从不同路径副本启动时，防止出现多个悬浮球）
        if Self.hasExistingInstance() {
            appLog.info("detected existing instance, quitting")
            NSApp.terminate(nil)
            return
        }

        // 纯菜单栏应用：不占 Dock
        NSApp.setActivationPolicy(.accessory)

        // 菜单栏彩色图标（NSStatusItem 非模板渲染）+ 标准主菜单
        setupStatusItem()
        setupMainMenu()

        setupPanel()
        setupPetContextPanel()
        setupComposerPanel()
        setupTaskPanel()
        setupGlobalHotKey()
        model.start()
        startHoverMonitor()
        observeVisibility()
        observeSettings()
        observeBubble()
        observeComposer()
        // 显示器增删/分辨率变化时，把球收回可视区（避免被 macOS 甩到屏幕外）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 设置面板「重置位置」请求
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetPositionRequested),
            name: .waterballResetPosition,
            object: nil
        )
        // 菜单栏「设置…」请求
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleSettingsPanelNotification),
            name: .waterballToggleSettings,
            object: nil
        )
        appLog.info("didFinishLaunching done")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        for monitor in hoverMonitors {
            NSEvent.removeMonitor(monitor)
        }
        hoverMonitors = []
        bubbleSink?.cancel()
        bubbleSink = nil
        statusSink?.cancel()
        statusSink = nil
        composerSink?.cancel()
        composerSink = nil
        taskPanelSink?.cancel()
        taskPanelSink = nil
        commandSink?.cancel()
        commandSink = nil
        hotKeySink?.cancel()
        hotKeySink = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        removeTaskPanelEventMonitors()
        dismissPetContext()
        model.closeTaskPanel()
    }

    func applicationWillHide(_ notification: Notification) {
        model.closeTaskPanel()
        model.collapseComposer()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsPanel()
        return true
    }

    // MARK: - 悬浮窗

    private func setupPanel() {
        let width = MoodBallView.panelWidth(
            for: SettingsStore.shared.skin,
            size: SettingsStore.shared.ballSize,
            glowEnabled: SettingsStore.shared.glowEnabled,
            showBubble: showStatusBubble
        )
        let height = MoodBallView.panelHeight(
            for: SettingsStore.shared.skin,
            size: SettingsStore.shared.ballSize,
            glowEnabled: SettingsStore.shared.glowEnabled,
            showBubble: showStatusBubble
        )
        let panel = MoodBallPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating                       // 置顶
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true               // 默认点击穿透（悬停时由 updateHover 恢复响应）
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.onRightClick = { [weak self] point in
            self?.showPetContext(at: point)
        }

        let hosting = NSHostingView(rootView: MoodBallView(
            model: model,
            settings: SettingsStore.shared,
            onOpenHarness: { [weak self] in self?.model.openHarness() }
        ))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        // 优先恢复上次拖拽位置，否则放屏幕右下角
        if !panel.restoreSavedPosition() {
            positionAtBottomRight(panel)
        }
        MoodBallPanel.current = panel
        if SettingsStore.shared.isPetVisible {
            panel.orderFrontRegardless()
        }
        self.panel = panel
    }

    private func setupPetContextPanel() {
        let context = PetContextPanel(
            contentRect: NSRect(x: 0, y: 0, width: 104, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        context.isOpaque = false
        context.backgroundColor = .clear
        context.hasShadow = false
        context.level = .floating
        context.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        context.isReleasedWhenClosed = false
        context.hidesOnDeactivate = false
        context.isExcludedFromWindowsMenu = true
        context.contentView = NSHostingView(rootView: PetContextView { [weak self] in
            self?.dismissPetContext()
            SettingsStore.shared.isPetVisible = false
        })
        petContextPanel = context
    }

    private func showPetContext(at point: NSPoint) {
        guard let context = petContextPanel else { return }
        let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = context.frame.size
        let origin = NSPoint(
            x: min(max(point.x + 8, visible.minX), visible.maxX - size.width),
            y: min(max(point.y - size.height - 8, visible.minY), visible.maxY - size.height)
        )
        context.setFrameOrigin(origin)
        context.orderFrontRegardless()
        installPetContextMonitors()
    }

    private func dismissPetContext() {
        petContextPanel?.orderOut(nil)
        for monitor in petContextMonitors { NSEvent.removeMonitor(monitor) }
        petContextMonitors.removeAll()
    }

    private func installPetContextMonitors() {
        guard petContextMonitors.isEmpty else { return }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissPetContext()
                return nil
            }
            if event.type != .keyDown, event.window !== self.petContextPanel {
                self.dismissPetContext()
            }
            return event
        }) {
            petContextMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissPetContext() }
        }) {
            petContextMonitors.append(global)
        }
    }

    private func setupComposerPanel() {
        let p = MoodBallComposerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 18),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        let hosting = NSHostingView(rootView: MoodBallComposerView(model: model, command: model.commandClient))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        self.composerPanel = p
        updateComposerPanel()
    }

    private func setupTaskPanel() {
        let p = MoodBallTaskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        let hosting = NSHostingView(rootView: MoodBallTaskPanelView(model: model, command: model.commandClient))
        hosting.wantsLayer = true
        p.contentView = hosting
        p.onCancel = { [weak self] in self?.model.closeTaskPanel() }
        self.taskPanel = p
    }

    private func positionAtBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let inset: CGFloat = 16
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width - inset,
            y: screen.visibleFrame.minY + inset
        )
        panel.setFrameOrigin(origin)
        appLog.info("positionAtBottomRight -> \(Int(origin.x)),\(Int(origin.y)) on visibleFrame \(Int(screen.visibleFrame.minX)),\(Int(screen.visibleFrame.minY)) \(Int(screen.visibleFrame.width))x\(Int(screen.visibleFrame.height))")
    }

    @objc private func screenParametersChanged() {
        guard let panel, panel.isVisible else { return }
        // 显示器增删/分辨率变化后，若窗口中心不在任何屏幕的可视区内
        // （可能只留一截在屏边、球心已甩到无屏幕区域，导致拖不到），
        // 就把球收回鼠标所在屏的右下角。
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let centerOnScreen = visibleFrames.contains { $0.contains(center) }
        if !centerOnScreen {
            positionAtBottomRight(panel)
            appLog.info("screen changed: ball center off-screen, repositioned to bottom-right")
        }
        updateComposerPanel()
        updateTaskPanel()
    }

    @objc private func resetPositionRequested() {
        guard let panel else { return }
        positionAtBottomRight(panel)
    }

    @objc private func toggleSettingsPanelNotification() {
        toggleSettingsPanel()
    }

    // MARK: - 设置联动

    private func observeSettings() {
        // 皮肤、尺寸或光晕变化时更新窗口；底部锚点保持不动。
        settingsSink = Publishers.CombineLatest3(
            SettingsStore.shared.$ballSize,
            SettingsStore.shared.$skin,
            SettingsStore.shared.$glowEnabled
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] newSize, skin, glowEnabled in
                guard let self, let panel = self.panel else { return }
                let showBubble = self.showStatusBubble
                panel.setFrame(self.panelFrame(
                    ballSize: newSize, skin: skin, glowEnabled: glowEnabled, showBubble: showBubble
                ), display: true)
                self.updateComposerPanel()
                self.updateHover()
            }
    }

    // MARK: - 状态气泡（面板增高联动）

    /// 当前是否显示状态气泡（mood 非空闲且设置开关打开）
    private var showStatusBubble: Bool {
        model.bubbleText != nil && SettingsStore.shared.showStatusBubble
    }

    /// 按可见内容计算面板大小，保留宠物的水平中心和底部位置。
    private func panelFrame(
        ballSize d: CGFloat, skin: FloatingPetSkin, glowEnabled: Bool, showBubble: Bool
    ) -> NSRect {
        let w = MoodBallView.panelWidth(for: skin, size: d, glowEnabled: glowEnabled, showBubble: showBubble)
        let h = MoodBallView.panelHeight(for: skin, size: d, glowEnabled: glowEnabled, showBubble: showBubble)
        let old = panel?.frame ?? NSRect(x: 0, y: 0, width: w, height: h)
        let ballCenterX = old.midX
        return NSRect(x: ballCenterX - w / 2, y: old.minY, width: w, height: h)
    }

    private func observeBubble() {
        // mood 变化（气泡显隐）或设置开关变化 → 增高/缩回面板顶部
        let moodChanges: AnyPublisher<Void, Never> = model.$mood
            .map { _ in () as Void }
            .eraseToAnyPublisher()
        let bubbleSetting: AnyPublisher<Void, Never> = SettingsStore.shared.$showStatusBubble
            .map { _ in () as Void }
            .eraseToAnyPublisher()
        bubbleSink = Publishers.MergeMany(moodChanges, bubbleSetting)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel else { return }
                let showBubble = self.showStatusBubble
                let frame = self.panelFrame(
                    ballSize: SettingsStore.shared.ballSize,
                    skin: SettingsStore.shared.skin,
                    glowEnabled: SettingsStore.shared.glowEnabled,
                    showBubble: showBubble
                )
                if !frame.equalTo(panel.frame) {
                    panel.setFrame(frame, display: true)
                    appLog.info("panel frame -> \(Int(frame.width))x\(Int(frame.height)) bubble=\(showBubble)")
                }
            }
    }

    // MARK: - 悬停检测（穿透 ↔ 可拖拽）

    private func startHoverMonitor() {
        // 事件驱动：鼠标移动/拖拽时才检测，鼠标不动时零唤醒（取代固定频率轮询定时器）。
        // 本地监视器：本 app 活跃时（拖拽中、设置面板开着）触发；
        // 全局监视器：其它 app 前台时触发（球默认点击穿透，鼠标事件不派发给本 app，
        //   只有全局监视器能看到光标移动）。
        // 全局监视器回调在后台线程，统一跳回主线程再更新。
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateHover()
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHover()
            }
        }
        hoverMonitors = [local, global].compactMap { $0 }
    }

    private func updateHover() {
        let settings = SettingsStore.shared
        guard panel?.isVisible == true else { return }
        let mouse = NSEvent.mouseLocation
        let d = settings.ballSize
        let petFrame: NSRect?
        if let panel, panel.isVisible {
            if settings.skin.isSprite {
                // Codex 宠物保留完整单格的交互宽度，小雨沿用原来的贴合区域。
                let petWidth = d * (settings.skin == .xiaoyu ? 0.75 : 192.0 / 208.0)
                petFrame = NSRect(
                    x: panel.frame.midX - petWidth / 2,
                    y: panel.frame.minY,
                    width: petWidth,
                    height: d * 1.10
                )
            } else {
                petFrame = NSRect(x: panel.frame.midX - d, y: panel.frame.minY + d / 2, width: d * 2, height: d)
            }
        } else {
            petFrame = nil
        }
        let insidePet: Bool
        if settings.skin.isSprite {
            insidePet = petFrame?.insetBy(dx: -8, dy: -4).contains(mouse) == true
        } else if let panel, panel.isVisible {
            let ballCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY + d)
            insidePet = hypot(mouse.x - ballCenter.x, mouse.y - ballCenter.y) <= d
        } else {
            insidePet = false
        }

        if settings.clickThroughMode != .always,
            model.barPhase != .composer {
            let controlFrame = composerPanel?.frame.insetBy(dx: -14, dy: -18)
            let insideTaskPanel = taskPanel?.isVisible == true && taskPanel?.frame.contains(mouse) == true
            model.setComposerHovering(
                insidePet
                    || controlFrame?.contains(mouse) == true
                    || insideTaskPanel
            )
        }
        updateComposerPanel()

        guard let panel, panel.isVisible else { return }
        switch settings.clickThroughMode {
        case .always:
            // 永远穿透：常驻忽略鼠标事件（不可拖拽）
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
        case .never:
            // 永不穿透：常驻响应（无穿透）
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        case .hover:
            // 气泡和透明光晕不参与宠物拖拽命中。
            let shouldIgnore = !panel.isDragging && !insidePet
            if panel.ignoresMouseEvents != shouldIgnore {
                panel.ignoresMouseEvents = shouldIgnore
                appLog.info("hover -> ignoresMouseEvents=\(shouldIgnore)")
            }
        }
    }

    // MARK: - 输入控件面板

    private func observeComposer() {
        composerSink = Publishers.CombineLatest(model.$barPhase, model.$composerInputHeight)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateComposerPanel()
            }
        taskPanelSink = model.$taskPanelMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateComposerPanel()
                self?.updateTaskPanel()
                self?.updateHover()
            }
        commandSink = model.commandClient.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateComposerPanel()
                    self?.updateTaskPanel()
                }
            }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.model.barPhase == .composer else { return }
                self.model.collapseComposer()
            }
        }
    }

    private func updateComposerPanel() {
        guard let composerPanel else { return }
        let settings = SettingsStore.shared
        guard settings.isPetVisible else {
            composerPanel.orderOut(nil)
            model.closeTaskPanel()
            return
        }

        let size = Self.composerPanelSize(
            for: model.barPhase,
            expandedComposerSize: expandedComposerSize
        )
        composerPanel.setFrame(composerFrame(size: size), display: true)
        if model.barPhase == .composer {
            composerPanel.ignoresMouseEvents = false
        } else {
            composerPanel.ignoresMouseEvents = settings.clickThroughMode != .never
                && model.barPhase != .hovering
        }
        composerPanel.orderFrontRegardless()
    }

    private var expandedComposerSize: NSSize {
        NSSize(
            width: 340,
            height: MoodBallComposerView.expandedComposerHeight(
                inputHeight: model.composerInputHeight,
                showsStatusLine: model.commandClient.showsComposerStatusLine
            )
        )
    }

    static func composerPanelSize(
        for phase: MoodBallBarPhase,
        expandedComposerSize: NSSize
    ) -> NSSize {
        if phase == .composer { return expandedComposerSize }
        if phase == .hovering {
            return NSSize(
                width: MoodBallComposerView.expandedBarPanelWidth,
                height: MoodBallComposerView.expandedBarPanelHeight
            )
        }
        return NSSize(
            width: MoodBallComposerView.restingPanelWidth,
            height: MoodBallComposerView.restingPanelHeight
        )
    }

    private func updateTaskPanel() {
        guard let taskPanel else { return }
        let shouldShow = SettingsStore.shared.isPetVisible
            && model.taskPanelMode != .closed
        guard shouldShow else {
            removeTaskPanelEventMonitors()
            taskPanel.ignoresMouseEvents = true
            guard taskPanel.isVisible else {
                taskPanel.alphaValue = 1
                isTaskPanelClosing = false
                return
            }
            guard !isTaskPanelClosing,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                if !isTaskPanelClosing {
                    taskPanel.orderOut(nil)
                    taskPanel.alphaValue = 1
                }
                return
            }
            isTaskPanelClosing = true
            if let layer = taskPanel.contentView?.layer {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0
                scale.toValue = 0.96
                scale.duration = 0.15
                scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                layer.add(scale, forKey: "moodball.taskPanel.closeScale")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                taskPanel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak taskPanel] in
                Task { @MainActor in
                    guard let self, let taskPanel else { return }
                    self.isTaskPanelClosing = false
                    if self.model.taskPanelMode == .closed || !SettingsStore.shared.isPetVisible {
                        taskPanel.orderOut(nil)
                    }
                    taskPanel.alphaValue = 1
                }
            }
            return
        }

        isTaskPanelClosing = false
        let wasVisible = taskPanel.isVisible
        let shouldAnimateOpening = !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let size = NSSize(width: 340, height: 340)
        taskPanel.setFrame(taskPanelFrame(size: size), display: true)
        taskPanel.ignoresMouseEvents = false
        taskPanel.alphaValue = shouldAnimateOpening ? 0 : 1
        taskPanel.orderFrontRegardless()
        installTaskPanelEventMonitors()

        guard shouldAnimateOpening else { return }
        if let layer = taskPanel.contentView?.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.duration = 0.2
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            layer.add(scale, forKey: "moodball.taskPanel.scale")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            taskPanel.animator().alphaValue = 1
        }
    }

    private func taskPanelFrame(size: NSSize) -> NSRect {
        guard let anchor = composerPanel?.frame else { return NSRect(origin: .zero, size: size) }
        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(anchorCenter) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 6
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        let belowY = anchor.minY - size.height - gap
        let aboveY = anchor.maxY + gap
        let y = belowY >= visible.minY + 4
            ? belowY
            : min(aboveY, visible.maxY - size.height - 4)
        return NSRect(x: x, y: max(visible.minY + 4, y), width: size.width, height: size.height)
    }

    private func installTaskPanelEventMonitors() {
        guard taskPanelEventMonitors.isEmpty else { return }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in self.model.closeTaskPanel() }
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                Task { @MainActor in self.closeTaskPanelIfClickIsOutside() }
            }
            return event
        }) {
            taskPanelEventMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeTaskPanelIfClickIsOutside() }
        }) {
            taskPanelEventMonitors.append(global)
        }
    }

    private func removeTaskPanelEventMonitors() {
        for monitor in taskPanelEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        taskPanelEventMonitors.removeAll()
    }

    private func closeTaskPanelIfClickIsOutside() {
        guard model.taskPanelMode != .closed else { return }
        let point = NSEvent.mouseLocation
        let visibleFrames = [panel, composerPanel, taskPanel]
            .compactMap { candidate -> NSRect? in
                guard let candidate, candidate.isVisible else { return nil }
                return candidate.frame
            }
        if !visibleFrames.contains(where: { $0.contains(point) }) {
            model.closeTaskPanel()
        }
    }

    private func composerFrame(size: NSSize) -> NSRect {
        guard let panel else { return NSRect(origin: .zero, size: size) }
        let centerX = panel.frame.midX
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: centerX, y: panel.frame.midY)) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The idle capsule visually belongs to the pet's feet. Expanded
        // surfaces retain a small breathing gap, while idle sits flush below.
        let petControlGap: CGFloat = model.barPhase == .resting ? 0 : 4
        let x = min(max(centerX - size.width / 2, visible.minX + petControlGap), visible.maxX - size.width - petControlGap)
        let belowY = panel.frame.minY - size.height - petControlGap
        let y: CGFloat
        if belowY >= visible.minY + petControlGap {
            y = belowY
        } else {
            // When there is no room below, sit above the visible pet (whose
            // sprite is bottom-anchored), not above the transparent hit area.
            y = min(
                panel.frame.minY + SettingsStore.shared.ballSize + petControlGap,
                visible.maxY - size.height - petControlGap
            )
        }
        return clampedComposerFrame(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    private func clampedComposerFrame(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        let inset: CGFloat = 4
        let x = min(max(frame.minX, visible.minX + inset), max(visible.minX + inset, visible.maxX - frame.width - inset))
        let y = min(max(frame.minY, visible.minY + inset), max(visible.minY + inset, visible.maxY - frame.height - inset))
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    // MARK: - 宠物显示状态

    private func observeVisibility() {
        visibilitySink = SettingsStore.shared.$isPetVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if !visible { self.model.closeTaskPanel() }
                if visible {
                    if let panel = self.panel, !panel.isVisible {
                        panel.orderFrontRegardless()
                    }
                } else {
                    self.dismissPetContext()
                    self.panel?.orderOut(nil)
                }
                self.updateComposerPanel()
                self.updateTaskPanel()
                self.updateHover()
                appLog.info("display surfaces: visible=\(visible, privacy: .public)")
            }
    }

    // MARK: - 菜单栏图标

    /// 创建菜单栏常驻图标。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = Self.makeStatusIcon()
        item.button?.imagePosition = .imageOnly

        // 菜单内容：状态行 + 显示/隐藏 + 设置… + 退出（与旧 MenuBarContent 一致）
        let menu = NSMenu()

        statusHeaderItem = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        statusHeaderItem?.isEnabled = false
        menu.addItem(statusHeaderItem!)

        menu.addItem(.separator())

        togglePetMenuItem = makeShortcutMenuItem(
            action: .togglePetVisibility,
            title: SettingsStore.shared.isPetVisible ? "隐藏宠物" : "显示宠物",
            selector: #selector(togglePetVisibility)
        )
        menu.addItem(togglePetMenuItem!)

        menu.addItem(makeShortcutMenuItem(
            action: .openSettings,
            title: "设置…",
            selector: #selector(toggleSettingsPanel)
        ))

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu

        // mood 颜色 / 球显隐 / 状态文案变化 → 刷新图标与菜单
        statusSink = Publishers.Merge(model.objectWillChange, SettingsStore.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 在属性写入前发出，推迟到下一轮再读，保证拿到新值
                Task { @MainActor [weak self] in
                    self?.refreshStatusItem()
                }
            }
        refreshStatusItem() // 初始绘制
    }

    /// 用最新状态刷新菜单栏图标与菜单文案。
    private func refreshStatusItem() {
        guard let item = statusItem else { return }
        let color = model.color

        // The template glyph stays fixed; only the menu's state dot changes color.
        if lastIconColor != color {
            lastIconColor = color
            statusHeaderItem?.image = Self.makeColoredDot(color: color, size: 10)
        }

        item.button?.toolTip = model.statusText
        item.button?.setAccessibilityLabel(model.statusText)
        statusHeaderItem?.title = model.statusText
        togglePetMenuItem?.title = SettingsStore.shared.isPetVisible ? "隐藏宠物" : "显示宠物"
        applyMenuShortcuts()
    }

    private func makeShortcutMenuItem(
        action: MoodBallShortcutAction,
        title: String,
        selector: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        shortcutMenuItems[action, default: []].append(item)
        return item
    }

    private func applyMenuShortcuts() {
        let settings = SettingsStore.shared
        for action in MoodBallShortcutAction.allCases {
            let configuration = settings.shortcutConfiguration(for: action)
            let keyEquivalent = configuration.isEnabled && settings.shortcutConflict(for: action) == nil
                ? configuration.menuKeyEquivalent
                : nil
            let modifierMask = configuration.modifiers.intersection([.command, .option, .control, .shift])
            for item in shortcutMenuItems[action, default: []] {
                item.keyEquivalent = keyEquivalent ?? ""
                item.keyEquivalentModifierMask = keyEquivalent == nil ? [] : modifierMask
            }
        }
    }

    @objc private func togglePetVisibility() {
        SettingsStore.shared.isPetVisible.toggle()
    }

    // MARK: - 全局快捷键

    private func setupGlobalHotKey() {
        globalHotKeyManager.onTrigger = { [weak self] in
            Task { @MainActor [weak self] in
                self?.showComposerFromGlobalHotKey()
            }
        }
        hotKeySink = Publishers.CombineLatest3(
            SettingsStore.shared.$globalHotKeyEnabled,
            SettingsStore.shared.$globalHotKeyKeyCode,
            SettingsStore.shared.$globalHotKeyModifiers
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in
            self?.applyGlobalHotKeyConfiguration()
        }
        applyGlobalHotKeyConfiguration()
    }

    private func applyGlobalHotKeyConfiguration() {
        let settings = SettingsStore.shared
        let result = globalHotKeyManager.update(settings.globalHotKeyConfiguration)
        switch result {
        case .success:
            settings.setGlobalHotKeyStatus(nil)
        case .failure(let error):
            settings.setGlobalHotKeyStatus(error.localizedDescription + "；已保留上一次有效快捷键")
        }
    }

    private func showComposerFromGlobalHotKey() {
        // Show the selected display mode before focusing its composer.
        if !SettingsStore.shared.isPetVisible {
            SettingsStore.shared.isPetVisible = true
        }
        model.openComposer(focus: true)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, let composerPanel = self.composerPanel else { return }
            composerPanel.makeKeyAndOrderFront(nil)
        }
    }

    /// Official DeepSeek Harness FishLogo geometry (MIT); see ThirdPartyNotices.txt.
    /// Source blob: 8621f17273c0d192feb14a988816c8052360b908
    static func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 22.9168, y: 1.43018))
            path.curve(to: NSPoint(x: 22.4223, y: 1.65519), controlPoint1: NSPoint(x: 22.6713, y: 1.31018), controlPoint2: NSPoint(x: 22.5658, y: 1.53918))
            path.curve(to: NSPoint(x: 22.2903, y: 1.78669), controlPoint1: NSPoint(x: 22.3733, y: 1.69269), controlPoint2: NSPoint(x: 22.3318, y: 1.74169))
            path.curve(to: NSPoint(x: 20.9657, y: 2.39121), controlPoint1: NSPoint(x: 21.9317, y: 2.1697), controlPoint2: NSPoint(x: 21.5127, y: 2.42121))
            path.curve(to: NSPoint(x: 18.8787, y: 3.20973), controlPoint1: NSPoint(x: 20.1657, y: 2.34621), controlPoint2: NSPoint(x: 19.4827, y: 2.59771))
            path.curve(to: NSPoint(x: 17.6746, y: 1.71569), controlPoint1: NSPoint(x: 18.7502, y: 2.45521), controlPoint2: NSPoint(x: 18.3236, y: 2.0047))
            path.curve(to: NSPoint(x: 16.7536, y: 1.08867), controlPoint1: NSPoint(x: 17.3351, y: 1.56568), controlPoint2: NSPoint(x: 16.9916, y: 1.41518))
            path.curve(to: NSPoint(x: 16.4591, y: 0.341647), controlPoint1: NSPoint(x: 16.5876, y: 0.856163), controlPoint2: NSPoint(x: 16.5421, y: 0.597155))
            path.curve(to: NSPoint(x: 16.1761, y: 0.00363739), controlPoint1: NSPoint(x: 16.4061, y: 0.187643), controlPoint2: NSPoint(x: 16.3536, y: 0.0301382))
            path.curve(to: NSPoint(x: 15.8326, y: 0.270145), controlPoint1: NSPoint(x: 15.9836, y: -0.0263635), controlPoint2: NSPoint(x: 15.9081, y: 0.135141))
            path.curve(to: NSPoint(x: 15.4251, y: 2.0462), controlPoint1: NSPoint(x: 15.5306, y: 0.822162), controlPoint2: NSPoint(x: 15.4136, y: 1.43018))
            path.curve(to: NSPoint(x: 17.1991, y: 5.3203), controlPoint1: NSPoint(x: 15.4516, y: 3.43174), controlPoint2: NSPoint(x: 16.0366, y: 4.53527))
            path.curve(to: NSPoint(x: 17.3236, y: 5.63181), controlPoint1: NSPoint(x: 17.3311, y: 5.4103), controlPoint2: NSPoint(x: 17.3651, y: 5.5003))
            path.curve(to: NSPoint(x: 17.0671, y: 6.43533), controlPoint1: NSPoint(x: 17.2441, y: 5.90231), controlPoint2: NSPoint(x: 17.1501, y: 6.16482))
            path.curve(to: NSPoint(x: 16.7501, y: 6.57033), controlPoint1: NSPoint(x: 17.0141, y: 6.60784), controlPoint2: NSPoint(x: 16.9351, y: 6.64584))
            path.curve(to: NSPoint(x: 15.074, y: 5.4328), controlPoint1: NSPoint(x: 16.1121, y: 6.30383), controlPoint2: NSPoint(x: 15.5611, y: 5.90931))
            path.curve(to: NSPoint(x: 12.568, y: 3.05973), controlPoint1: NSPoint(x: 14.2475, y: 4.63328), controlPoint2: NSPoint(x: 13.5, y: 3.75075))
            path.curve(to: NSPoint(x: 11.9034, y: 2.60522), controlPoint1: NSPoint(x: 12.349, y: 2.89822), controlPoint2: NSPoint(x: 12.13, y: 2.74822))
            path.curve(to: NSPoint(x: 12.277, y: 0.833162), controlPoint1: NSPoint(x: 10.9524, y: 1.68169), controlPoint2: NSPoint(x: 12.028, y: 0.923165))
            path.curve(to: NSPoint(x: 11.5259, y: 0.42015), controlPoint1: NSPoint(x: 12.5375, y: 0.739159), controlPoint2: NSPoint(x: 12.3675, y: 0.41615))
            path.curve(to: NSPoint(x: 8.93286, y: 1.08117), controlPoint1: NSPoint(x: 10.6844, y: 0.42365), controlPoint2: NSPoint(x: 9.91439, y: 0.705658))
            path.curve(to: NSPoint(x: 8.48384, y: 1.21267), controlPoint1: NSPoint(x: 8.78935, y: 1.13767), controlPoint2: NSPoint(x: 8.63835, y: 1.17867))
            path.curve(to: NSPoint(x: 5.70226, y: 1.11517), controlPoint1: NSPoint(x: 7.59332, y: 1.04367), controlPoint2: NSPoint(x: 6.66829, y: 1.00617))
            path.curve(to: NSPoint(x: 1.36213, y: 3.64575), controlPoint1: NSPoint(x: 3.88321, y: 1.31768), controlPoint2: NSPoint(x: 2.43016, y: 2.1777))
            path.curve(to: NSPoint(x: 0.146595, y: 9.50642), controlPoint1: NSPoint(x: 0.0790928, y: 5.4103), controlPoint2: NSPoint(x: -0.222916, y: 7.41536))
            path.curve(to: NSPoint(x: 3.38869, y: 14.9616), controlPoint1: NSPoint(x: 0.535106, y: 11.7105), controlPoint2: NSPoint(x: 1.66014, y: 13.535))
            path.curve(to: NSPoint(x: 9.60138, y: 17.0266), controlPoint1: NSPoint(x: 5.18125, y: 16.4406), controlPoint2: NSPoint(x: 7.24581, y: 17.1657))
            path.curve(to: NSPoint(x: 14.421, y: 15.2321), controlPoint1: NSPoint(x: 11.0319, y: 16.9441), controlPoint2: NSPoint(x: 12.6245, y: 16.7526))
            path.curve(to: NSPoint(x: 16.1381, y: 15.6151), controlPoint1: NSPoint(x: 14.874, y: 15.4576), controlPoint2: NSPoint(x: 15.3496, y: 15.5476))
            path.curve(to: NSPoint(x: 17.7836, y: 15.4911), controlPoint1: NSPoint(x: 16.7456, y: 15.6716), controlPoint2: NSPoint(x: 17.3306, y: 15.5851))
            path.curve(to: NSPoint(x: 18.1876, y: 14.5636), controlPoint1: NSPoint(x: 18.4931, y: 15.3411), controlPoint2: NSPoint(x: 18.4441, y: 14.6841))
            path.curve(to: NSPoint(x: 16.1496, y: 13.67), controlPoint1: NSPoint(x: 16.1081, y: 13.595), controlPoint2: NSPoint(x: 16.5646, y: 13.9891))
            path.curve(to: NSPoint(x: 19.3182, y: 7.17235), controlPoint1: NSPoint(x: 17.2061, y: 12.42), controlPoint2: NSPoint(x: 18.8202, y: 10.1979))
            path.curve(to: NSPoint(x: 19.4222, y: 6.09732), controlPoint1: NSPoint(x: 19.3672, y: 6.83834), controlPoint2: NSPoint(x: 19.4297, y: 6.36783))
            path.curve(to: NSPoint(x: 19.6447, y: 5.84931), controlPoint1: NSPoint(x: 19.4182, y: 5.93231), controlPoint2: NSPoint(x: 19.4562, y: 5.86831))
            path.curve(to: NSPoint(x: 21.1357, y: 5.3913), controlPoint1: NSPoint(x: 20.1657, y: 5.78931), controlPoint2: NSPoint(x: 20.6712, y: 5.64681))
            path.curve(to: NSPoint(x: 23.1548, y: 1.9972), controlPoint1: NSPoint(x: 22.4833, y: 4.65528), controlPoint2: NSPoint(x: 23.0268, y: 3.44624))
            path.curve(to: NSPoint(x: 22.9168, y: 1.43018), controlPoint1: NSPoint(x: 23.1738, y: 1.77569), controlPoint2: NSPoint(x: 23.1508, y: 1.54668))
            path.close()
            path.move(to: NSPoint(x: 11.1749, y: 14.4736))
            path.curve(to: NSPoint(x: 7.77832, y: 12.39), controlPoint1: NSPoint(x: 9.15936, y: 12.889), controlPoint2: NSPoint(x: 8.18184, y: 12.3675))
            path.curve(to: NSPoint(x: 7.55182, y: 13.126), controlPoint1: NSPoint(x: 7.40081, y: 12.4125), controlPoint2: NSPoint(x: 7.46881, y: 12.8445))
            path.curve(to: NSPoint(x: 7.91033, y: 13.8396), controlPoint1: NSPoint(x: 7.63882, y: 13.404), controlPoint2: NSPoint(x: 7.75182, y: 13.5955))
            path.curve(to: NSPoint(x: 7.80083, y: 14.4216), controlPoint1: NSPoint(x: 8.01983, y: 14.0011), controlPoint2: NSPoint(x: 8.09533, y: 14.2411))
            path.curve(to: NSPoint(x: 5.97027, y: 14.2601), controlPoint1: NSPoint(x: 7.15181, y: 14.8231), controlPoint2: NSPoint(x: 6.02327, y: 14.2866))
            path.curve(to: NSPoint(x: 2.78467, y: 11.069), controlPoint1: NSPoint(x: 4.65673, y: 13.4865), controlPoint2: NSPoint(x: 3.5587, y: 12.4655))
            path.curve(to: NSPoint(x: 1.53164, y: 6.74384), controlPoint1: NSPoint(x: 2.03715, y: 9.72493), controlPoint2: NSPoint(x: 1.60314, y: 8.28289))
            path.curve(to: NSPoint(x: 1.99215, y: 6.17332), controlPoint1: NSPoint(x: 1.51264, y: 6.37233), controlPoint2: NSPoint(x: 1.62214, y: 6.24082))
            path.curve(to: NSPoint(x: 3.46769, y: 6.13582), controlPoint1: NSPoint(x: 2.47916, y: 6.08332), controlPoint2: NSPoint(x: 2.98118, y: 6.06432))
            path.curve(to: NSPoint(x: 8.74385, y: 8.8129), controlPoint1: NSPoint(x: 5.52476, y: 6.43633), controlPoint2: NSPoint(x: 7.27581, y: 7.35586))
            path.curve(to: NSPoint(x: 10.8689, y: 11.6025), controlPoint1: NSPoint(x: 9.58188, y: 9.64243), controlPoint2: NSPoint(x: 10.2159, y: 10.634))
            path.curve(to: NSPoint(x: 13.262, y: 14.4146), controlPoint1: NSPoint(x: 11.5634, y: 12.631), controlPoint2: NSPoint(x: 12.3105, y: 13.611))
            path.curve(to: NSPoint(x: 14.1225, y: 15.0681), controlPoint1: NSPoint(x: 13.598, y: 14.6961), controlPoint2: NSPoint(x: 13.866, y: 14.9101))
            path.curve(to: NSPoint(x: 11.1749, y: 14.4746), controlPoint1: NSPoint(x: 13.349, y: 15.1546), controlPoint2: NSPoint(x: 12.058, y: 15.1731))
            path.line(to: NSPoint(x: 11.1749, y: 14.4736))
            path.close()
            path.move(to: NSPoint(x: 12.141, y: 8.25988))
            path.curve(to: NSPoint(x: 12.439, y: 7.96338), controlPoint1: NSPoint(x: 12.141, y: 8.09488), controlPoint2: NSPoint(x: 12.273, y: 7.96338))
            path.curve(to: NSPoint(x: 12.541, y: 7.98188), controlPoint1: NSPoint(x: 12.4765, y: 7.96338), controlPoint2: NSPoint(x: 12.5105, y: 7.97088))
            path.curve(to: NSPoint(x: 12.6505, y: 8.05338), controlPoint1: NSPoint(x: 12.5825, y: 7.99688), controlPoint2: NSPoint(x: 12.6205, y: 8.01938))
            path.curve(to: NSPoint(x: 12.7335, y: 8.25988), controlPoint1: NSPoint(x: 12.7035, y: 8.10588), controlPoint2: NSPoint(x: 12.7335, y: 8.18088))
            path.curve(to: NSPoint(x: 12.4355, y: 8.55639), controlPoint1: NSPoint(x: 12.7335, y: 8.42489), controlPoint2: NSPoint(x: 12.6015, y: 8.55639))
            path.curve(to: NSPoint(x: 12.141, y: 8.25988), controlPoint1: NSPoint(x: 12.2695, y: 8.55639), controlPoint2: NSPoint(x: 12.141, y: 8.42489))
            path.close()
            path.move(to: NSPoint(x: 15.1415, y: 9.79893))
            path.curve(to: NSPoint(x: 14.5715, y: 9.95294), controlPoint1: NSPoint(x: 14.949, y: 9.87793), controlPoint2: NSPoint(x: 14.7565, y: 9.94544))
            path.curve(to: NSPoint(x: 13.8015, y: 9.70893), controlPoint1: NSPoint(x: 14.2845, y: 9.96794), controlPoint2: NSPoint(x: 13.9715, y: 9.85143))
            path.curve(to: NSPoint(x: 13.2695, y: 8.97691), controlPoint1: NSPoint(x: 13.5375, y: 9.48742), controlPoint2: NSPoint(x: 13.3485, y: 9.36342))
            path.curve(to: NSPoint(x: 13.2845, y: 8.40989), controlPoint1: NSPoint(x: 13.2355, y: 8.8119), controlPoint2: NSPoint(x: 13.2545, y: 8.55639))
            path.curve(to: NSPoint(x: 13.0545, y: 7.70787), controlPoint1: NSPoint(x: 13.3525, y: 8.09438), controlPoint2: NSPoint(x: 13.277, y: 7.89187))
            path.curve(to: NSPoint(x: 12.39, y: 7.51636), controlPoint1: NSPoint(x: 12.8735, y: 7.55786), controlPoint2: NSPoint(x: 12.643, y: 7.51636))
            path.curve(to: NSPoint(x: 12.1445, y: 7.44136), controlPoint1: NSPoint(x: 12.2955, y: 7.51636), controlPoint2: NSPoint(x: 12.209, y: 7.47486))
            path.curve(to: NSPoint(x: 12.035, y: 7.09585), controlPoint1: NSPoint(x: 12.039, y: 7.38886), controlPoint2: NSPoint(x: 11.9519, y: 7.25735))
            path.curve(to: NSPoint(x: 12.22, y: 6.89334), controlPoint1: NSPoint(x: 12.0615, y: 7.04335), controlPoint2: NSPoint(x: 12.19, y: 6.91584))
            path.curve(to: NSPoint(x: 13.326, y: 6.90834), controlPoint1: NSPoint(x: 12.5635, y: 6.69784), controlPoint2: NSPoint(x: 12.9595, y: 6.76184))
            path.curve(to: NSPoint(x: 14.292, y: 7.66287), controlPoint1: NSPoint(x: 13.6655, y: 7.04735), controlPoint2: NSPoint(x: 13.9225, y: 7.30236))
            path.curve(to: NSPoint(x: 14.9525, y: 8.54539), controlPoint1: NSPoint(x: 14.6695, y: 8.09838), controlPoint2: NSPoint(x: 14.7375, y: 8.21838))
            path.curve(to: NSPoint(x: 15.3831, y: 9.36392), controlPoint1: NSPoint(x: 15.1225, y: 8.8009), controlPoint2: NSPoint(x: 15.277, y: 9.06341))
            path.curve(to: NSPoint(x: 15.1415, y: 9.79893), controlPoint1: NSPoint(x: 15.4471, y: 9.55142), controlPoint2: NSPoint(x: 15.3641, y: 9.70493))
            path.close()
            let scale = (rect.width - 2) / 23.16
            var transform = AffineTransform()
            transform.translate(x: rect.midX - 23.16 * scale / 2, y: rect.midY + 17.04 * scale / 2)
            transform.scale(x: scale, y: -scale)
            path.transform(using: transform)
            path.windingRule = .nonZero
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 菜单头部的状态色点：纯色实心圆，颜色跟随 mood。
    private static func makeColoredDot(color: Color, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.12, dy: size * 0.12)).fill()
            return true
        }
    }

    // MARK: - 主菜单（手动补齐，替代 SwiftUI 自动生成的菜单）

    /// 无 SwiftUI App 场景后手动建立标准主菜单：
    /// 保证「设置…（⌘,）」与文本输入框的剪切/复制/粘贴等快捷键可用。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DSH Pet", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(makeShortcutMenuItem(
            action: .inputMessage,
            title: "输入消息",
            selector: #selector(inputMessageFromMenu)
        ))
        appMenu.addItem(makeShortcutMenuItem(
            action: .newSession,
            title: "新建会话",
            selector: #selector(newSessionFromMenu)
        ))
        appMenu.addItem(makeShortcutMenuItem(
            action: .selectWorkspace,
            title: "选择工作区",
            selector: #selector(selectWorkspaceFromMenu)
        ))
        appMenu.addItem(makeShortcutMenuItem(
            action: .openHarness,
            title: "打开 Harness",
            selector: #selector(openHarnessFromMenu)
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(makeShortcutMenuItem(
            action: .openSettings,
            title: "设置…",
            selector: #selector(toggleSettingsPanel)
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
        applyMenuShortcuts()
    }

    // MARK: - Harness 输入入口

    @objc private func inputMessageFromMenu() {
        showComposerFromGlobalHotKey()
    }

    @objc private func newSessionFromMenu() {
        model.startNewSession()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectWorkspaceFromMenu() {
        model.openComposer()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHarnessFromMenu() {
        model.openHarness()
    }

    // MARK: - 设置面板

    /// 打开/关闭设置面板（菜单栏「设置…」）
    @objc func toggleSettingsPanel() {
        if let settingsPanel, settingsPanel.isVisible {
            settingsPanel.orderOut(nil)
            return
        }
        openSettingsPanel()
    }

    private func openSettingsPanel() {
        let panel: NSPanel
        if let existing = settingsPanel {
            panel = existing
        } else {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1060, height: 530),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            p.title = "DSH Pet 设置"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentMinSize = NSSize(width: 980, height: 520)
            p.appearance = NSAppearance(named: .aqua)
            p.setFrameAutosaveName("DSHPetSettingsSidebar")
            p.contentView = NSHostingView(rootView: SettingsPanelView(model: model))
            p.center()
            settingsPanel = p
            panel = p
        }
        // 设置面板需要能输入（TextField 等），临时激活本 app
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        appLog.info("settings panel opened")
    }

    /// 是否已有同 Bundle ID 的其它实例在运行（用于单实例守卫）。
    /// 找到任一其它实例即返回 true。
    static func hasExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID }
        return !others.isEmpty
    }
}
