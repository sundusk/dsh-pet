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
    private var statePreviewPanel: NSPanel?
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
            onOpenDesktopHarness: { [weak self] in self?.openDesktopHarnessIfRunning() }
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

    // MARK: - 菜单栏图标（NSStatusItem，非模板彩色渲染）

    /// 创建菜单栏常驻图标。
    /// 注意：SwiftUI 的 `MenuBarExtra` 会把 label 强制渲染成单色模板图片，
    /// mood 颜色会丢失（看起来就是个黑点/白点），所以这里改用 AppKit 的
    /// `NSStatusItem` + 自绘非模板图片，让圆球真正显示 mood 颜色。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

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
            action: .openHarness,
            title: "打开 Harness",
            selector: #selector(openHarnessFromMenu)
        ))
        menu.addItem(makeShortcutMenuItem(
            action: .openSettings,
            title: "设置…",
            selector: #selector(toggleSettingsPanel)
        ))
        menu.addItem(makeShortcutMenuItem(
            action: .statePreview,
            title: "状态展示…",
            selector: #selector(toggleStatePreviewPanel)
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

        // 颜色变化才重绘图片（轮询会高频触发 objectWillChange，避免每次都重建 NSImage）
        if lastIconColor != color {
            lastIconColor = color
            let image = Self.makeStatusIcon(color: color)
            item.button?.image = image
            item.button?.image?.isTemplate = false
            item.button?.imagePosition = .imageOnly
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

    /// 自绘菜单栏图标：mood 颜色圆球 + 两只镂空小圆点眼睛（非模板图片）。
    /// `isTemplate = false`：不参与系统的模板染色，按原样显示。
    private static func makeStatusIcon(color: Color, size: CGFloat = 22) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath()
            // 圆球
            path.appendOval(in: rect.insetBy(dx: size * 0.08, dy: size * 0.08))
            // 两只镂空竖向椭圆眼睛：even-odd 填充把椭圆挖成透明
            let eyeW = size * 0.10
            let eyeH = size * 0.20
            let eyeGap = size * 0.16
            let eyeY = rect.midY - eyeH / 2
            path.appendOval(in: CGRect(x: rect.midX - eyeGap - eyeW / 2, y: eyeY, width: eyeW, height: eyeH))
            path.appendOval(in: CGRect(x: rect.midX + eyeGap - eyeW / 2, y: eyeY, width: eyeW, height: eyeH))
            path.windingRule = .evenOdd
            NSColor(color).setFill()
            path.fill()
            return true
        }
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
        appMenu.addItem(makeShortcutMenuItem(
            action: .statePreview,
            title: "状态展示…",
            selector: #selector(toggleStatePreviewPanel)
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

    private func openDesktopHarnessIfRunning() {
        // Official DeepSeek Harness uses com.deepseek.dsh for releases and a
        // per-checkout com.deepseek.harness.dev.* ID for its development app.
        let app = NSWorkspace.shared.runningApplications.first { running in
            guard !running.isTerminated, let id = running.bundleIdentifier else { return false }
            return id == "com.deepseek.dsh" || id.hasPrefix("com.deepseek.harness.dev.")
        }
        guard let app,
              let bundleURL = app.bundleURL else { return }

        // Reopening the running Electron app triggers its single-instance or
        // activate handler, which restores a minimized or closed main window.
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                appLog.error("could not reopen desktop Harness: \(error.localizedDescription)")
            }
        }
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
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            p.title = "DSH Pet 设置"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: SettingsPanelView())
            p.center()
            settingsPanel = p
            panel = p
        }
        // 设置面板需要能输入（TextField 等），临时激活本 app
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        appLog.info("settings panel opened")
    }

    // MARK: - 状态展示面板（选状态看球，方便截图）

    @objc func toggleStatePreviewPanel() {
        if let statePreviewPanel, statePreviewPanel.isVisible {
            statePreviewPanel.orderOut(nil)
            return
        }
        // 与其他面板互斥
        if let settingsPanel, settingsPanel.isVisible { settingsPanel.orderOut(nil) }
        openStatePreviewPanel()
    }

    private func openStatePreviewPanel() {
        let panel: NSPanel
        if let existing = statePreviewPanel {
            panel = existing
        } else {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            p.title = "DSH Pet 状态展示"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: StatePreviewPanelView())
            p.center()
            statePreviewPanel = p
            panel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        appLog.info("state preview panel opened")
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
