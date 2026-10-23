import SwiftUI

/// Native macOS settings window for DSH Pet.
///
/// The view deliberately keeps the settings model as the source of truth. The
/// preview only selects which real state to display; it does not create a
/// second, mock settings model.
struct SettingsPanelView: View {
    @ObservedObject var model: MoodBallModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var connections: HarnessConnectionManager
    @ObservedObject private var petLibrary: CustomPetLibrary
    @State private var page: SettingsPage = .appearance

    init(model: MoodBallModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: SettingsStore.shared)
        _connections = ObservedObject(wrappedValue: model.harnessConnections)
        _petLibrary = ObservedObject(wrappedValue: CustomPetLibrary.shared)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: $page, model: model)
            Divider()
            ScrollView {
                pageView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(32)
            }
            .background(Color.white)
        }
        .frame(minWidth: 980, idealWidth: 1060, minHeight: 520, idealHeight: 530)
        .preferredColorScheme(.light)
        .tint(.blue)
        .environment(\.controlActiveState, .active)
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .appearance: AppearanceSettingsPage(settings: settings, library: petLibrary)
        case .interaction: InteractionSettingsPage(settings: settings)
        case .shortcuts: ShortcutsSettingsPage(settings: settings)
        case .petManagement: PetManagementPage(settings: settings, library: petLibrary)
        case .connection: HarnessConnectionSettingsPage(model: model, connections: connections, commandClient: model.commandClient, settings: settings)
        case .about: AboutSettingsPage()
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance = "桌宠外观"
    case interaction = "交互与提醒"
    case shortcuts = "快捷键"
    case petManagement = "宠物管理"
    case connection = "Harness 连接"
    case about = "关于与更新"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .interaction: return "hand.tap"
        case .shortcuts: return "command"
        case .petManagement: return "pawprint"
        case .connection: return "point.3.connected.trianglepath.dotted"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    @ObservedObject var model: MoodBallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    JingyuniangAvatar().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DSH Pet").font(.headline.weight(.semibold))
                        Text("你的桌面伙伴").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 22)

            VStack(spacing: 3) {
                ForEach(SettingsPage.allCases) { item in
                    if item == .connection {
                        Divider().padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsSidebarButtonStyle(selected: page == item))
                }
            }
            .padding(.horizontal, 10)

            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(model.connected ? "已连接" : "未连接")
                        .font(.caption.weight(.medium))
                }
                Text(model.connected ? "连接 · \(model.transportKind.rawValue)" : "等待 Harness 连接")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("DSH Pet \(UpdateChecker.currentVersion)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .frame(width: 200)
        .background(Color(red: 0.89, green: 0.915, blue: 0.945))
    }
}

private struct JingyuniangAvatar: View {
    private static let atlas = try? CodexSpriteAtlas(
        resourceName: "JingyuniangSprites", fileExtension: "png", idleFrameCount: 6
    )

    var body: some View {
        GeometryReader { geometry in
            if let frame = Self.atlas?.frame(for: .idle, elapsed: 0) {
                Image(decorative: frame, scale: 1)
                    .resizable().interpolation(.none).scaledToFit()
                    .frame(width: geometry.size.width * 2.1, height: geometry.size.height * 2.3)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(selected ? Color.white : .primary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(selected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let bottomPadding: CGFloat

    init(title: String, subtitle: String, bottomPadding: CGFloat = 24) {
        self.title = title
        self.subtitle = subtitle
        self.bottomPadding = bottomPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.bottom, bottomPadding)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String?
    let verticalPadding: CGFloat
    @ViewBuilder let content: Content

    init(title: String? = nil, verticalPadding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.title = title
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { Text(title).font(.headline).padding(.bottom, 12) }
            content
        }
        .padding(.vertical, verticalPadding)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: 0.5)
        }
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            content
        }
    }
}

private struct ToggleSettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 14)
    }
}

private struct PetSelectionButton: View {
    let skin: FloatingPetSkin
    let title: String
    let selected: Bool
    let action: () -> Void

    init(skin: FloatingPetSkin, title: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.skin = skin
        self.title = title ?? skin.label
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var library: CustomPetLibrary
    @State private var previewMood = "idle"
    @State private var showingColors = false
    @State private var showingMoodBallDetails = false
    @State private var showingStatePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: "桌宠外观", subtitle: "让桌面伙伴更合你的习惯。")

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    appearanceControls.frame(width: 440)
                    Divider().padding(.horizontal, 18)
                    appearancePreview
                        .frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 0) {
                    appearanceControls
                    appearancePreview
                }
            }

        }
        .sheet(isPresented: $showingColors) {
            StatusColorsSheet(settings: settings)
        }
        .sheet(isPresented: $showingMoodBallDetails) {
            MoodBallDetailsSheet(settings: settings)
        }
        .sheet(isPresented: $showingStatePreview) {
            StatePreviewSheet(settings: settings, skin: settings.skin, mood: previewMood)
        }
    }

    @ViewBuilder
    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择桌宠").font(.headline)
                .padding(.bottom, 10)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(FloatingPetSkin.allCases) { skin in
                    PetSelectionButton(skin: skin, selected: settings.skin == skin) {
                        settings.skin = skin
                    }
                }
                ForEach(library.pets) { pet in
                    PetSelectionButton(skin: pet.skin, title: pet.displayName, selected: settings.skin == pet.skin) {
                        settings.skin = pet.skin
                    }
                }
            }
            .padding(.bottom, 16)

            Divider()
            SettingRow("桌宠大小") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { settings.ballSize },
                        set: { settings.ballSize = ($0 / 4).rounded() * 4 }
                    ), in: 60...200)
                    TextField("", text: Binding(
                        get: { String(Int(settings.ballSize)) },
                        set: { if let value = Double($0) { settings.ballSize = min(max(CGFloat(value), 60), 200) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    Text("px").foregroundStyle(.secondary)
                }
                .frame(width: 310)
            }
            .padding(.vertical, 15)

            Divider()
            ToggleSettingRow(title: "显示状态气泡", detail: "在思考、等待操作和完成时显示提醒。", isOn: $settings.showStatusBubble)
            Divider()
            ToggleSettingRow(title: "桌宠发光", detail: "为桌宠添加随状态变化的柔和光晕。", isOn: $settings.glowEnabled)
            Divider()

            Button {
                showingColors = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("状态配色")
                        Text("调整气泡与光晕的状态颜色。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(moodColorConfigs.prefix(5), id: \.mood) { config in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(settings.moodColors[config.mood] ?? Color(hex: config.defaultHex))
                                .frame(width: 18, height: 18)
                                .padding(3)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.18)) }
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 15)

            if settings.skin == .moodBall {
                Divider()
                Button {
                    showingMoodBallDetails = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("心情球专属设置")
                            Text("眼睛、颜色与呼吸速度")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 15)
            }

            Divider()
            Label("更改会自动保存", systemImage: "checkmark.square.fill")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var appearancePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("效果预览").font(.headline)
                Spacer()
                Button("放大 / 导出…") { showingStatePreview = true }
                    .buttonStyle(.link).font(.caption)
            }
            VStack(spacing: 12) {
                PetPreview(settings: settings, library: library, mood: previewMood)
                    .frame(height: 218).frame(maxWidth: .infinity)
                Picker("预览状态", selection: $previewMood) {
                    ForEach(moodColorConfigs, id: \.mood) { config in Text(config.label).tag(config.mood) }
                    Text("未连接").tag("disconnected")
                }
                .labelsHidden().frame(width: 160)
                Text("仅预览，不影响正在运行的任务。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("重置桌宠位置") {
                    NotificationCenter.default.post(name: .waterballResetPosition, object: nil)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .background(Color(red: 0.95, green: 0.955, blue: 0.965), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct PetPreview: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var library: CustomPetLibrary
    let mood: String
    @State private var phase = false
    private var previewColor: Color { settings.moodColors[mood] ?? settings.disconnectedColor }

    init(settings: SettingsStore, mood: String) {
        self.init(settings: settings, library: .shared, mood: mood)
    }

    init(settings: SettingsStore, library: CustomPetLibrary, mood: String) {
        _settings = ObservedObject(wrappedValue: settings)
        _library = ObservedObject(wrappedValue: library)
        self.mood = mood
    }

    var body: some View {
        GeometryReader { geometry in
            let bubbleHeight: CGFloat = settings.showStatusBubble && mood != "idle" ? 34 : 0
            let heightFactor: CGFloat = settings.skin.isSprite ? (settings.glowEnabled ? 1.55 : 1.10) : 1
            let widthFactor: CGFloat = settings.skin.isSprite && settings.glowEnabled ? 1.55 : 1
            let previewSize = min(settings.ballSize, min(
                max(1, geometry.size.height - bubbleHeight) / (heightFactor * 1.02),
                max(1, geometry.size.width - 20) / (widthFactor * 1.02)
            ))
            let customAvailable: Bool = {
                if case .custom = settings.skin {
                    return library.atlas(for: settings.skin) != nil
                }
                return true
            }()

            VStack(spacing: 4) {
                if settings.showStatusBubble {
                    let label = mood == "disconnected" ? "未连接" : moodColorConfigs.first(where: { $0.mood == mood })?.label
                    if let label, mood != "idle" {
                        Text(label).font(.caption.weight(.medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(.thinMaterial, in: Capsule())
                            .frame(height: 30)
                    }
                }
                Group {
                    if settings.skin.isSprite && customAvailable {
                        XiaoyuSpriteView(skin: settings.skin, mood: mood, color: previewColor, size: previewSize, glowEnabled: settings.glowEnabled, interactionTriggeredAt: nil, dragDirection: nil)
                    } else {
                        MoodBallPreview(settings: settings, color: previewColor, diameter: previewSize)
                    }
                }
                // Center the pet itself; its glow canvas is taller and bottom-aligned.
                .frame(width: previewSize, height: previewSize, alignment: .bottom)
                .scaleEffect(phase ? 1.02 : 0.98)
                .animation(.easeInOut(duration: settings.breathingSpeed).repeatForever(autoreverses: true), value: phase)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { phase = true }
    }
}

private struct MoodBallPreview: View {
    @ObservedObject var settings: SettingsStore
    let color: Color
    let diameter: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color, color.opacity(0.7)], center: .topLeading, startRadius: 0, endRadius: diameter))
                .frame(width: diameter, height: diameter)
                .shadow(color: settings.glowEnabled ? color.opacity(0.8) : .clear, radius: diameter * 0.16)
            if settings.showEyes {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                    let eyeScale = MoodBallView.blinkScale(at: timeline.date.timeIntervalSinceReferenceDate)
                    HStack(spacing: diameter * 0.13) {
                        Capsule().fill(settings.eyeColor.color).frame(width: diameter * 0.1, height: diameter * 0.18)
                        Capsule().fill(settings.eyeColor.color).frame(width: diameter * 0.1, height: diameter * 0.18)
                    }
                    .scaleEffect(y: eyeScale, anchor: .center)
                }
            }
            Circle().fill(RadialGradient(colors: [.white.opacity(0.6), .clear], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: diameter * 0.6))
                .frame(width: diameter * 0.82, height: diameter * 0.82).blendMode(.screen)
        }
    }
}

// MARK: - Interaction and colours

private struct InteractionSettingsPage: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: "交互与提醒", subtitle: "让桌宠随时可用，也不过分打扰。", bottomPadding: 14)
            SettingsCard(title: "鼠标交互", verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    WideControlRow(title: "点击穿透", detail: "平时让鼠标穿过，移到桌宠上时可恢复交互。") {
                        Picker("点击穿透", selection: $settings.clickThroughMode) {
                            ForEach(ClickThroughMode.allCases) { mode in Text(mode.label).tag(mode) }
                        }.labelsHidden().frame(width: 200)
                    }
                    Divider().opacity(0.45)
                    WideToggleRow(title: "显示桌宠", detail: "同时显示桌宠和下方操作栏。", isOn: $settings.isPetVisible)
                }
            }
            SettingsCard(title: "位置", verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    WideToggleRow(title: "记住拖拽位置", detail: "下次启动时恢复上次停留的位置。", isOn: $settings.rememberPosition)
                    Divider().opacity(0.45)
                    WideToggleRow(title: "锁定位置", detail: "关闭拖拽移动，保留其他桌宠交互。", isOn: $settings.lockPosition)
                    Divider().opacity(0.45)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("恢复默认位置")
                            Text("将桌宠移回屏幕右下角。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重置位置") {
                            NotificationCenter.default.post(name: .waterballResetPosition, object: nil)
                        }
                    }
                    .padding(.vertical, 13)
                }
            }
            SettingsCard(title: "状态提醒", verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 24))
                            .foregroundStyle(.primary)
                            .frame(width: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("通过桌宠气泡和任务卡片了解进度")
                            Text("需要授权、回答或任务完成时，可以从桌宠查看状态。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("可在“桌宠外观”中调整")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("状态提醒会跟随 Harness 状态显示；状态颜色和气泡开关可在“桌宠外观”中调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WideToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 10)
    }
}

private struct WideControlRow<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    init(title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            content
        }
        .padding(.vertical, 10)
    }
}

private struct ColorSettingRow: View {
    let config: MoodColorConfig
    @ObservedObject var settings: SettingsStore
    var body: some View {
        HStack {
            Text(config.label); Spacer()
            ColorPicker(config.label, selection: Binding(get: { settings.moodColors[config.mood] ?? Color(hex: config.defaultHex) }, set: { settings.setMoodColor(config.mood, $0) }), supportsOpacity: false).labelsHidden()
            Text(String(format: "#%06X", colorToHex(settings.moodColors[config.mood] ?? Color(hex: config.defaultHex)))).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 68, alignment: .trailing)
        }.padding(.vertical, 7)
    }
}

private struct StatusColorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("状态配色").font(.title2.weight(.semibold))
                    Text("自定义气泡与光晕在不同状态下的颜色。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(moodColorConfigs, id: \.mood) { config in
                        ColorSettingRow(config: config, settings: settings)
                        if config.mood != moodColorConfigs.last?.mood { Divider().opacity(0.4) }
                    }
                    Divider().padding(.vertical, 5)
                    HStack {
                        Text("未连接")
                        Spacer()
                        ColorPicker("未连接颜色", selection: $settings.disconnectedColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    .padding(.vertical, 9)
                    Button("恢复默认颜色") { settings.resetMoodColors() }
                        .controlSize(.small).padding(.top, 12)
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(width: 390, height: 480)
        .preferredColorScheme(.light)
    }
}

private struct MoodBallDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("心情球专属设置").font(.title2.weight(.semibold))
                    Text("仅影响心情球桌宠。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.bottom, 18)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                SettingRow("呼吸速度", detail: "周期越短，呼吸越快") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.breathingSpeed, in: 0.5...5, step: 0.1)
                        Text(String(format: "%.1fs", settings.breathingSpeed))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                    .frame(width: 230)
                }
                ToggleSettingRow(title: "显示眼睛", detail: "在心情球上显示呼吸与眨眼。", isOn: $settings.showEyes)
                SettingRow("眼睛颜色") {
                    Picker("眼睛颜色", selection: $settings.eyeColor) {
                        ForEach(EyeColor.allCases) { color in Text(color.label).tag(color) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                }
            }
            .padding(.top, 18)
            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 270)
        .preferredColorScheme(.light)
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsPage: View {
    @ObservedObject var settings: SettingsStore
    @State private var recordingGlobal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: "快捷键", subtitle: "分清全局唤起与菜单操作，避免快捷键互相打扰。", bottomPadding: 14)
            SettingsCard(title: "全局唤起", verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("显示并聚焦输入框")
                            Text("在任意应用中使用；重复按下保留当前草稿。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        HotKeyRecorderView(keyCode: $settings.globalHotKeyKeyCode, modifiers: $settings.globalHotKeyModifiers, isRecording: $recordingGlobal)
                            .frame(width: 205, height: 30)
                        Toggle("启用", isOn: $settings.globalHotKeyEnabled)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    .padding(.vertical, 8)
                    HStack(spacing: 7) {
                        Image(systemName: settings.globalHotKeyStatus == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(settings.globalHotKeyStatus ?? "已成功注册")
                    }
                    .font(.caption)
                    .foregroundStyle(settings.globalHotKeyStatus == nil ? Color.green : Color.orange)
                }
            }
            SettingsCard(title: "菜单快捷键", verticalPadding: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("用于 DSH Pet 菜单操作，不会注册为系统全局快捷键。")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    HStack {
                        Text("操作").frame(maxWidth: .infinity, alignment: .leading)
                        Text("快捷键").frame(width: 205, alignment: .leading)
                        Text("启用").frame(width: 48, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    ForEach(MoodBallShortcutAction.allCases) { action in
                        ShortcutEditorRow(action: action, settings: settings)
                        Divider().opacity(0.4)
                    }
                    HStack {
                        Button("恢复默认快捷键") { settings.resetShortcuts() }.controlSize(.small)
                        Text("点击按键区域可重新录入；冲突时会显示原因。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

private struct ShortcutEditorRow: View {
    let action: MoodBallShortcutAction
    @ObservedObject var settings: SettingsStore
    @State private var recording = false
    private var configuration: GlobalHotKeyConfiguration { settings.shortcutConfiguration(for: action) }
    var body: some View {
        HStack(spacing: 16) {
            Text(action.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            HotKeyRecorderView(keyCode: Binding(get: { configuration.keyCode }, set: { settings.setShortcutKeyCode($0, for: action) }), modifiers: Binding(get: { configuration.modifiers.rawValue }, set: { settings.setShortcutModifiers($0, for: action) }), isRecording: $recording).frame(width: 190, height: 24)
            Toggle("启用", isOn: Binding(get: { configuration.isEnabled }, set: { settings.setShortcutEnabled($0, for: action) }))
                .labelsHidden().toggleStyle(.switch).frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .overlay(alignment: .bottomLeading) {
            if let conflict = settings.shortcutConflict(for: action) {
                Text(conflict).font(.caption2).foregroundStyle(.orange).offset(y: 13)
            }
        }
        .padding(.bottom, settings.shortcutConflict(for: action) == nil ? 0 : 10)
    }
}

// MARK: - Harness connection

private struct HarnessConnectionSettingsPage: View {
    @ObservedObject var model: MoodBallModel
    @ObservedObject var connections: HarnessConnectionManager
    @ObservedObject var commandClient: MoodBallCommandClient
    @ObservedObject var settings: SettingsStore

    private var targetBinding: Binding<String> { Binding(get: { connections.selectionID }, set: { model.selectHarnessTarget($0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: "Harness 连接", subtitle: "先确认连接来源，再检查桌宠能够使用的功能。")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard(title: "当前连接") {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingRow("连接目标", detail: "自动识别；首次检测到多个实例时请选择目标") {
                                Picker("连接目标", selection: targetBinding) {
                                    Text("自动识别").tag("auto")
                                    ForEach(connections.instances) { instance in
                                        Text(instance.displayName).tag(instance.id)
                                    }
                                    if connections.selectionID != "auto",
                                       !connections.instances.contains(where: { $0.id == connections.selectionID }) {
                                        Text("选定目标（未运行）").tag(connections.selectionID)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 245)
                            }
                            Divider().opacity(0.45)
                            HStack(spacing: 12) {
                                Image(systemName: connectionIcon).font(.system(size: 26)).frame(width: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connectionDetail).font(.headline)
                                    Text(model.connected ? "通过当前通道通信" : "尚未建立可用连接")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ConnectionStatusDot(connected: model.connected)
                                Text(model.connected ? "已连接" : "未连接")
                                    .foregroundStyle(model.connected ? Color.primary : Color.secondary)
                            }
                            .padding(.vertical, 10)
                            Divider().opacity(0.45)
                            ConnectionFactRow(label: "状态通道", value: model.connected ? "可用" : "不可用")
                            Divider().opacity(0.45)
                            ConnectionFactRow(label: "消息通道", value: commandConnectionLabel)
                            Divider().opacity(0.45)
                            ConnectionFactRow(label: "连接方式", value: model.transportKind.rawValue)
                            HStack(spacing: 10) {
                                Button { model.openHarness() } label: {
                                    Label(openButtonTitle, systemImage: "arrow.up.right.square")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).disabled(connections.isDiscovering)
                                Button { model.refreshHarnessConnections() } label: {
                                    Label(connections.isDiscovering ? "扫描中…" : "重新检测", systemImage: "arrow.clockwise")
                                }
                                .disabled(connections.isDiscovering)
                            }
                            .padding(.top, 14)
                            if let message = connections.message {
                                Label(message, systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                            }
                            if let error = connections.openingError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange).padding(.top, 5)
                            }
                        }
                    }
                    SettingsCard {
                        DisclosureGroup("高级兼容设置") {
                            VStack(alignment: .leading, spacing: 14) {
                                SettingRow("API 地址", detail: "仅在旧版兼容轮询连接中生效") {
                                    TextField("http://127.0.0.1:3080", text: $settings.apiBase)
                                        .textFieldStyle(.roundedBorder).frame(width: 215)
                                }
                                SettingRow("轮询间隔", detail: "仅在旧版兼容轮询连接中生效") {
                                    HStack(spacing: 8) {
                                        Slider(value: $settings.pollInterval, in: 0.3...5, step: 0.1)
                                        Text(String(format: "%.1fs", settings.pollInterval))
                                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                    }.frame(width: 215)
                                }
                                SettingRow("请求超时", detail: "仅在旧版兼容轮询连接中生效") {
                                    HStack(spacing: 8) {
                                        Slider(value: $settings.requestTimeout, in: 0.5...5, step: 0.5)
                                        Text(String(format: "%.1fs", settings.requestTimeout))
                                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                    }.frame(width: 215)
                                }
                                Text("新版桌面版或桥接实例的连接参数由实例自身提供。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 12)
                        }
                    }
                    .padding(.top, 14)
                }
                .frame(width: 440, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    SettingsCard(title: "功能检查") {
                        VStack(alignment: .leading, spacing: 0) {
                            CapabilityStatusRow(icon: "list.bullet.rectangle", title: "任务状态", detail: "接收思考、等待操作与完成状态", available: model.connected)
                            Divider().opacity(0.45)
                            CapabilityStatusRow(icon: "paperplane", title: "发送消息", detail: "发送到选定工作区和会话", available: commandClient.capabilitiesAvailable)
                            if model.connected && connections.effectiveInstance == nil && connections.instances.isEmpty {
                                Text("当前旧版桥接仅提供状态读取，发送消息已禁用。")
                                    .font(.caption).foregroundStyle(.orange).padding(.top, 10)
                            }
                        }
                    }
                    SettingsCard(title: "遇到连接问题？") {
                        VStack(alignment: .leading, spacing: 9) {
                            ConnectionHelpStep(number: "1", text: "确认 Harness 正在运行")
                            ConnectionHelpStep(number: "2", text: "确认桥接插件已安装并启用")
                            ConnectionHelpStep(number: "3", text: "仅状态可用时，检查消息通道")
                            Text("连接状态来自当前通道，不会修改 Harness 的模型或插件设置。")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                        }
                    }
                    .padding(.top, 14)
                }
                .frame(width: 290, alignment: .leading)
            }
        }
    }

    private var connectionIcon: String {
        switch connections.effectiveInstance?.kind.rawValue {
        case "desktop": return "desktopcomputer"
        case "web": return "globe"
        default: return model.connected ? "point.3.connected.trianglepath.dotted" : "questionmark.circle"
        }
    }

    private var connectionDetail: String {
        if let instance = connections.effectiveInstance { return instance.displayName }
        if model.connected { return "旧版桥接 · 来源未知" }
        return "等待发现 Harness 实例"
    }
    private var commandConnectionLabel: String {
        switch commandClient.connection { case .connected: return "已连接"; case .connecting: return "连接中"; case .disconnected: return "未连接" }
    }
    private var openButtonTitle: String {
        switch connections.effectiveInstance?.kind.rawValue { case "desktop": return "打开桌面版 Harness"; case "web": return "打开网页版 Harness"; default: return "打开 Harness" }
    }
}

private struct ConnectionStatusDot: View {
    let connected: Bool
    var body: some View { Circle().fill(connected ? Color.green : Color.secondary.opacity(0.45)).frame(width: 10, height: 10) }
}

private struct ConnectionFactRow: View {
    let label: String
    let value: String
    var body: some View { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospaced() } }
}

private struct CapabilityStatusRow: View {
    let icon: String
    let title: String
    let detail: String
    let available: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 23)).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Color.green : Color.orange)
            Text(available ? "可用" : "待验证")
                .foregroundStyle(available ? Color.primary : Color.secondary)
        }
        .padding(.vertical, 12)
    }
}

private struct ConnectionHelpStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 23)
                .background(Color.secondary.opacity(0.14), in: Circle())
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - About and updates

private struct AboutSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: "关于与更新", subtitle: "查看版本、获取更新与使用帮助。")
            SettingsCard {
                HStack(spacing: 16) {
                    XiaoyuSpriteView(
                        skin: .jingyuniang,
                        mood: "idle",
                        color: Color(hex: 0x60a5fa),
                        size: 58,
                        glowEnabled: false,
                        interactionTriggeredAt: nil,
                        dragDirection: nil
                    )
                    .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DSH Pet").font(.title2.weight(.semibold))
                        Text("DeepSeek Harness 的 macOS 桌面伴侣").foregroundStyle(.secondary)
                        Text("查看任务状态，接收提醒，随时发送消息。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .top, spacing: 24) {
                UpdateSection().frame(width: 440)
                Divider()
                SettingsCard(title: "帮助与反馈") {
                    VStack(alignment: .leading, spacing: 0) {
                        AboutLinkRow(title: "使用说明", detail: "安装、连接与桌宠操作", icon: "doc.text", url: URL(string: "https://github.com/sundusk/dsh-pet#readme")!)
                        Divider().opacity(0.45)
                        AboutLinkRow(title: "项目主页", detail: "查看源码与项目介绍", icon: "arrow.up.right.square", url: URL(string: "https://github.com/sundusk/dsh-pet")!)
                        Divider().opacity(0.45)
                        AboutLinkRow(title: "反馈问题", detail: "提交问题与改进建议", icon: "bubble.left", url: URL(string: "https://github.com/sundusk/dsh-pet/issues")!)
                    }
                }
                .frame(width: 290)
            }
            .padding(.top, 18)
        }
    }
}

private struct AboutLinkRow: View {
    let title: String
    let detail: String
    let icon: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22)).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 12)
    }
}

private struct UpdateSection: View {
    private enum UpdateState { case idle, checking, latest, available(UpdateChecker.ReleaseInfo), failed }
    @State private var state: UpdateState = .idle
    var body: some View {
        SettingsCard(title: "版本与更新") {
            VStack(alignment: .leading, spacing: 0) {
                AboutValueRow(label: "当前版本", value: UpdateChecker.currentVersion)
                Divider().opacity(0.45)
                AboutValueRow(label: "更新来源", value: "GitHub Releases")
                Divider().opacity(0.45)
                AboutValueRow(label: "检查状态", value: statusText)
                HStack(spacing: 10) {
                    Button(isChecking ? "检查中…" : "检查更新") { check() }
                        .buttonStyle(.borderedProminent).disabled(isChecking)
                    Link("查看版本记录", destination: UpdateChecker.releasesPageURL)
                        .buttonStyle(.bordered)
                }
                .padding(.top, 15)
                Text("检查更新只查询版本信息；发现新版本后可前往下载页面。更新不会自动下载或安装。")
                    .font(.caption).foregroundStyle(statusColor).padding(.top, 10)
            }
        }
        .onAppear { if case .idle = state { check() } }
    }
    private var isChecking: Bool { if case .checking = state { return true }; return false }
    private var statusText: String {
        switch state { case .idle: return "检查 GitHub Releases 是否有新版本"; case .checking: return "正在检查 GitHub Releases…"; case .latest: return "已是最新版本"; case .available(let info): return "发现新版本 \(info.latestVersion)"; case .failed: return "检查失败，请检查网络后重试" }
    }
    private var statusColor: Color {
        switch state { case .latest: return .green; case .available: return .blue; case .failed: return .orange; default: return .secondary }
    }
    private func check() {
        state = .checking
        Task {
            if let info = await UpdateChecker.checkLatest() { state = info.updateAvailable ? .available(info) : .latest } else { state = .failed }
        }
    }
}

private struct AboutValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}
