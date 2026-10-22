import SwiftUI

/// 设置面板：外观 / 颜色 / 行为 / 快捷键四个 Tab，顶部带实时预览小球。
struct SettingsPanelView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var tab: Tab = .appearance

    enum Tab: String, CaseIterable, Identifiable {
        case appearance = "外观"
        case colors = "颜色"
        case behavior = "行为"
        case shortcuts = "快捷键"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部实时预览（跟随当前设置的渲染）
            PreviewBall(settings: settings)
                // 预览区固定高度，底部对齐宠物并裁剪超出的光晕。
                .frame(height: 150, alignment: .bottom)
                .clipped()
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.05))

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                switch tab {
                case .appearance: AppearanceTab(settings: settings)
                case .colors: ColorsTab(settings: settings)
                case .behavior: BehaviorTab(settings: settings)
                case .shortcuts: ShortcutsTab(settings: settings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 420, height: 520)
    }
}

private enum SettingsLayout {
    static let shortcutLabelWidth: CGFloat = 112
    static let shortcutToggleWidth: CGFloat = 52
    static let shortcutRecorderWidth: CGFloat = 168
}

// MARK: - 实时预览

/// 预览用的小球：复用呼吸渲染（静止在一个相位，跟随设置的大小/颜色/速度）
private struct PreviewBall: View {
    @ObservedObject var settings: SettingsStore
    @State private var phase = false

    var body: some View {
        let d = settings.ballSize
        Group {
            if settings.skin.isSprite {
                XiaoyuSpriteView(
                    skin: settings.skin,
                    mood: "idle",
                    color: settings.moodColors["idle"] ?? Color(hex: 0x60a5fa),
                    size: d,
                    glowEnabled: settings.glowEnabled,
                    interactionTriggeredAt: nil,
                    dragDirection: nil
                )
            } else {
                moodBallPreview(diameter: d)
            }
        }
        .scaleEffect(phase ? 1.05 : 0.95)
        .opacity(phase ? 1.0 : 0.6)
        .animation(.easeInOut(duration: settings.breathingSpeed).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moodBallPreview(diameter d: CGFloat) -> some View {
        let color = Color(hex: 0x00FFFF)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [color, color.opacity(0.75)], center: .topLeading, startRadius: 0, endRadius: d))
                .frame(width: d, height: d)
                .shadow(color: color.opacity(0.8), radius: d * 0.16)
            if settings.showEyes {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                    let eyeScale = MoodBallView.blinkScale(at: timeline.date.timeIntervalSinceReferenceDate)
                    ZStack {
                        Ellipse()
                            .fill(settings.eyeColor.color)
                            .frame(width: d * 0.10, height: d * 0.183)
                            .offset(x: -d * 0.117, y: 0)
                            .scaleEffect(x: 1, y: eyeScale, anchor: .center)
                        Ellipse()
                            .fill(settings.eyeColor.color)
                            .frame(width: d * 0.10, height: d * 0.183)
                            .offset(x: d * 0.117, y: 0)
                            .scaleEffect(x: 1, y: eyeScale, anchor: .center)
                    }
                }
            }
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: d * 0.6))
                .frame(width: d * 0.82, height: d * 0.82)
                .blendMode(.screen)
        }
    }
}

// MARK: - 外观

private struct AppearanceTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("桌宠") {
                Picker("桌宠", selection: Binding(
                    get: { settings.skin },
                    set: { settings.skin = $0 }
                )) {
                    ForEach(FloatingPetSkin.allCases) { skin in
                        Text(skin.label).tag(skin)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            LabeledContent("桌宠大小") {
                HStack {
                    Slider(value: Binding(
                        get: { settings.ballSize },
                        set: { settings.ballSize = $0 }
                    ), in: 60...200, step: 4)
                    Text("\(Int(settings.ballSize)) px")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.skin == .moodBall {
                LabeledContent("呼吸速度") {
                HStack {
                    Slider(value: Binding(
                        get: { settings.breathingSpeed },
                        set: { settings.breathingSpeed = $0 }
                    ), in: 0.5...5, step: 0.1)
                    Text(String(format: "%.1fs", settings.breathingSpeed))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
                Text("周期越短呼吸越快。仅对心情球生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("显示眼睛", isOn: Binding(
                get: { settings.showEyes },
                set: { settings.showEyes = $0 }
            ))

                LabeledContent("眼睛颜色") {
                Picker("", selection: Binding(
                    get: { settings.eyeColor },
                    set: { settings.eyeColor = $0 }
                )) {
                    ForEach(EyeColor.allCases) { color in
                        Text(color.label).tag(color)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
                }
            }

            Toggle("显示气泡文字", isOn: Binding(
                get: { settings.showStatusBubble },
                set: { settings.showStatusBubble = $0 }
            ))
            Text("非空闲状态时在球上方显示漫画风状态提醒（正在思考中/工具调用…），空闲自动隐藏。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("发光", isOn: Binding(
                get: { settings.glowEnabled },
                set: { settings.glowEnabled = $0 }
            ))
            Text("关闭后球体不再显示彩色光晕与投影。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("重置位置到右下角") {
                NotificationCenter.default.post(name: .waterballResetPosition, object: nil)
            }

            Divider()
            Text("提示：直接拖动桌面上的球即可移动它，位置会被记住。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 颜色

private struct ColorsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("球始终跟随 DeepSeek 状态变色；下面的颜色可在契约基础上自定义。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(moodColorConfigs, id: \.mood) { cfg in
                HStack {
                    Text(cfg.label)
                        .frame(width: 64, alignment: .leading)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { settings.moodColors[cfg.mood] ?? Color(hex: cfg.defaultHex) },
                        set: { settings.setMoodColor(cfg.mood, $0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    Text(hexString(settings.moodColors[cfg.mood] ?? Color(hex: cfg.defaultHex)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Text("未连接灰")
                    .frame(width: 64, alignment: .leading)
                Spacer()
                ColorPicker("", selection: $settings.disconnectedColor, supportsOpacity: false)
                    .labelsHidden()
            }

            Button("恢复默认颜色") {
                settings.resetMoodColors()
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func hexString(_ color: Color) -> String {
        String(format: "#%06X", colorToHex(color))
    }
}

// MARK: - 行为

private struct BehaviorTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("API 地址") {
                TextField("http://127.0.0.1:3080", text: Binding(
                    get: { settings.apiBase },
                    set: { settings.apiBase = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }

            LabeledContent("轮询间隔") {
                HStack {
                    Slider(value: Binding(
                        get: { settings.pollInterval },
                        set: { settings.pollInterval = $0 }
                    ), in: 0.3...5, step: 0.1)
                    Text(String(format: "%.1fs", settings.pollInterval))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("请求超时") {
                HStack {
                    Slider(value: Binding(
                        get: { settings.requestTimeout },
                        set: { settings.requestTimeout = $0 }
                    ), in: 0.5...5, step: 0.5)
                    Text(String(format: "%.1fs", settings.requestTimeout))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("点击穿透") {
                Picker("", selection: Binding(
                    get: { settings.clickThroughMode },
                    set: { settings.clickThroughMode = $0 }
                )) {
                    ForEach(ClickThroughMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            Toggle("记住拖拽位置（重启恢复）", isOn: Binding(
                get: { settings.rememberPosition },
                set: { settings.rememberPosition = $0 }
            ))

            Toggle("锁定位置", isOn: Binding(
                get: { settings.lockPosition },
                set: { settings.lockPosition = $0 }
            ))
            Text("开启后不可拖拽移动小球（仍可单击打开快捷控制）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("修改 API 地址或轮询间隔会立即生效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            UpdateSection()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 快捷键

private struct ShortcutsTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var isRecordingHotKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置一个可在任意应用中唤起 DSH Pet 输入框的全局快捷键。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Text("全局快捷键")
                    .frame(width: SettingsLayout.shortcutLabelWidth, alignment: .leading)
                    .lineLimit(1)
                Toggle("启用", isOn: Binding(
                    get: { settings.globalHotKeyEnabled },
                    set: { settings.globalHotKeyEnabled = $0 }
                ))
                .toggleStyle(.checkbox)
                .frame(width: SettingsLayout.shortcutToggleWidth, alignment: .leading)
                Spacer(minLength: 8)
                HotKeyRecorderView(
                    keyCode: Binding(
                        get: { settings.globalHotKeyKeyCode },
                        set: { settings.globalHotKeyKeyCode = $0 }
                    ),
                    modifiers: Binding(
                        get: { settings.globalHotKeyModifiers },
                        set: { settings.globalHotKeyModifiers = $0 }
                    ),
                    isRecording: $isRecordingHotKey
                )
                .frame(width: SettingsLayout.shortcutRecorderWidth, height: 30)
            }

            Text(settings.globalHotKeyStatus ?? "在任意应用中按 \(settings.globalHotKeyDisplayName) 显示并聚焦输入框。重复按下不会清空草稿。")
                .font(.caption)
                .foregroundStyle(settings.globalHotKeyStatus == nil ? Color.secondary : Color.orange)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("功能快捷键")
                    .font(.headline.weight(.semibold))
                Text("下面的快捷键对应 DSH Pet 菜单中的功能；可以单独修改或关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(MoodBallShortcutAction.allCases) { action in
                    ShortcutEditorRow(action: action, settings: settings)
                    Divider()
                        .opacity(0.45)
                }
            }

            Button("恢复默认快捷键") {
                settings.resetShortcuts()
            }
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 5) {
                Text("使用方式")
                    .font(.headline.weight(.semibold))
                Label("按下快捷键：显示并聚焦输入框", systemImage: "keyboard")
                Label("输入框已打开时重复按下：保留当前草稿", systemImage: "arrow.clockwise")
                Label("按 Esc：收起输入框，不清空草稿", systemImage: "escape")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct ShortcutEditorRow: View {
    let action: MoodBallShortcutAction
    @ObservedObject var settings: SettingsStore
    @State private var isRecording = false

    private var configuration: GlobalHotKeyConfiguration {
        settings.shortcutConfiguration(for: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 12) {
                Text(action.label)
                    .frame(width: SettingsLayout.shortcutLabelWidth, alignment: .leading)
                    .lineLimit(1)
                Toggle("启用", isOn: Binding(
                    get: { configuration.isEnabled },
                    set: { settings.setShortcutEnabled($0, for: action) }
                ))
                .toggleStyle(.checkbox)
                .frame(width: SettingsLayout.shortcutToggleWidth, alignment: .leading)
                Spacer(minLength: 8)
                HotKeyRecorderView(
                    keyCode: Binding(
                        get: { configuration.keyCode },
                        set: { settings.setShortcutKeyCode($0, for: action) }
                    ),
                    modifiers: Binding(
                        get: { configuration.modifiers.rawValue },
                        set: { settings.setShortcutModifiers($0, for: action) }
                    ),
                    isRecording: $isRecording
                )
                .frame(width: SettingsLayout.shortcutRecorderWidth, height: 30)
            }

            if let conflict = settings.shortcutConflict(for: action) {
                Text(conflict)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if configuration.isEnabled && configuration.menuKeyEquivalent == nil {
                Text("此按键暂不支持菜单绑定")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - 版本与更新

/// 版本信息 + 检查更新（查询 GitHub Releases 最新版，对比本地 CFBundleShortVersionString）。
private struct UpdateSection: View {
    private enum UpdateState {
        case idle
        case checking
        case latest
        case available(UpdateChecker.ReleaseInfo)
        case failed
    }

    @State private var state: UpdateState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack {
                Text("当前版本")
                Spacer()
                Text(UpdateChecker.currentVersion)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("检查更新") {
                    check()
                }
                .disabled(isChecking)

                Spacer()

                switch state {
                case .idle:
                    Text("检查 GitHub Releases 是否有新版本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .checking:
                    Text("检查中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .latest:
                    Text("已是最新版本")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .available(let info):
                    Link("发现新版本 \(info.latestVersion) → 前往下载", destination: info.releaseURL)
                        .font(.caption)
                        .foregroundStyle(.blue)
                case .failed:
                    Text("检查失败，请检查网络后重试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
        .onAppear {
            if case .idle = state { check() }
        }
    }

    private var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    private func check() {
        state = .checking
        Task {
            if let info = await UpdateChecker.checkLatest() {
                state = info.updateAvailable ? .available(info) : .latest
            } else {
                state = .failed
            }
        }
    }
}
