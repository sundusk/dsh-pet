import AppKit
import SwiftUI

/// Settings page for importing and maintaining Codex v2 pet packages.
struct PetManagementPage: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var library: CustomPetLibrary

    @State private var pendingPackage: PendingPackage?
    @State private var petToDelete: ImportedPet?
    @State private var packagePreviewMood = "idle"
    @State private var message: String?
    @State private var messageIsError = false

    private struct PendingPackage {
        let package: ValidatedPetPackage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PetManagementHeader()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    petList.frame(width: 420, alignment: .leading)
                    Divider()
                    previewPanel.frame(width: 280, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 24) {
                    petList
                    previewPanel
                }
            }
        }
        .onAppear {
            ensureCurrentSkinAvailable()
            if let error = library.loadError { setMessage(error, isError: true) }
        }
        .onChange(of: library.pets) { ensureCurrentSkinAvailable() }
        .alert("删除宠物？", isPresented: Binding(
            get: { petToDelete != nil },
            set: { if !$0 { petToDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let pet = petToDelete { delete(pet) }
                petToDelete = nil
            }
            Button("取消", role: .cancel) { petToDelete = nil }
        } message: {
            Text("只会删除 DSH Pet 保存的副本，不会修改原始宠物包。")
        }
    }

    private var petList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PetManagementCard(title: "已导入的宠物") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            choosePackage()
                        } label: {
                            Label("导入宠物", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            refreshLibrary()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 8)

                    Text("选择包含 pet.json 的文件夹。也可以从 ~/.codex/pets 中选择已安装的 Codex 宠物。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)

                    Divider().opacity(0.45)

                    if library.pets.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("还没有导入宠物", systemImage: "pawprint")
                                .font(.headline)
                            Text("点击“导入宠物”选择一个兼容的 Codex v2 宠物包。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 24)
                    } else {
                        ForEach(library.pets) { pet in
                            ImportedPetRow(
                                pet: pet,
                                atlas: library.atlas(for: pet.skin),
                                isCurrent: settings.skin == pet.skin,
                                use: { settings.skin = pet.skin },
                                remove: { petToDelete = pet }
                            )
                            if pet.id != library.pets.last?.id { Divider().opacity(0.4) }
                        }
                    }

                    if let message {
                        Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(messageIsError ? Color.orange : Color.secondary)
                            .padding(.top, 12)
                    }
                }
            }
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入预览").font(.headline)
            VStack(spacing: 12) {
                if let pendingPackage {
                    PetPackagePreview(atlas: pendingPackage.package.atlas, mood: packagePreviewMood)
                        .frame(height: 190)
                    Picker("预览状态", selection: $packagePreviewMood) {
                        Text("空闲").tag("idle")
                        Text("思考中").tag("waiting")
                        Text("完成").tag("done")
                        Text("失败").tag("failed")
                        Text("挥手").tag("wave")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pendingPackage.package.displayName)
                            .font(.headline)
                        if !pendingPackage.package.description.isEmpty {
                            Text(pendingPackage.package.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("导入") { importPendingPackage() }
                            .buttonStyle(.borderedProminent)
                        Button("取消") { self.pendingPackage = nil }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: "pawprint.circle")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("选择宠物包后先在这里预览，再确认导入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250)
            .padding(14)
            .background(Color(red: 0.95, green: 0.955, blue: 0.965), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 宠物包"
        panel.message = "选择包含 pet.json 的文件夹"
        let codexPetsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
        panel.directoryURL = FileManager.default.fileExists(atPath: codexPetsDirectory.path)
            ? codexPetsDirectory
            : FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
        do {
            let package = try library.validatePackage(at: directory)
            pendingPackage = PendingPackage(package: package)
            packagePreviewMood = "idle"
            setMessage("已验证宠物包，可以预览后导入。", isError: false)
        } catch {
            pendingPackage = nil
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func importPendingPackage() {
        guard let pendingPackage else { return }
        do {
            let imported = try library.importPet(pendingPackage.package)
            self.pendingPackage = nil
            setMessage("已导入“\(imported.displayName)”；点击“使用”即可切换桌宠。", isError: false)
            ensureCurrentSkinAvailable()
        } catch {
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func refreshLibrary() {
        do {
            try library.refresh()
            ensureCurrentSkinAvailable()
            setMessage("宠物列表已刷新。", isError: false)
        } catch {
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func delete(_ pet: ImportedPet) {
        do {
            try library.remove(pet)
            ensureCurrentSkinAvailable()
            setMessage("已删除“\(pet.displayName)”的 App 副本。", isError: false)
        } catch {
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func ensureCurrentSkinAvailable() {
        guard case .custom = settings.skin else { return }
        if !library.pets.contains(where: { $0.skin == settings.skin }) {
            settings.skin = .jingyuniang
        }
    }

    private func setMessage(_ message: String, isError: Bool) {
        self.message = message
        messageIsError = isError
    }

    private func errorMessage(for error: Error) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? "无法处理这个宠物包，请检查文件夹内容。" : description
    }
}

private struct PetManagementHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("宠物管理").font(.system(size: 26, weight: .semibold))
            Text("导入兼容的 Codex 宠物包，管理 DSH Pet 中可用的桌宠。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 24)
    }
}

private struct PetManagementCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 12)
            content
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: 0.5)
        }
    }
}

private struct ImportedPetRow: View {
    let pet: ImportedPet
    let atlas: CodexSpriteAtlas?
    let isCurrent: Bool
    let use: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let atlas {
                PetPackagePreview(atlas: atlas, mood: "idle")
                    .frame(width: 48, height: 58)
            } else {
                Image(systemName: "pawprint")
                    .frame(width: 48, height: 58)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(pet.displayName)
                if !pet.description.isEmpty {
                    Text(pet.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if isCurrent {
                    Text("当前使用中").font(.caption2).foregroundStyle(.blue)
                }
            }
            Spacer(minLength: 6)
            if !isCurrent {
                Button("使用", action: use).buttonStyle(.bordered).controlSize(.small)
            }
            Button("删除", action: remove)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .controlSize(.small)
                .accessibilityLabel("删除 \(pet.displayName)")
        }
        .padding(.vertical, 9)
    }
}

private struct PetPackagePreview: View {
    let atlas: CodexSpriteAtlas
    let mood: String
    @State private var startedAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: XiaoyuAnimation.renderInterval, paused: reduceMotion)) { timeline in
            let animation = mood == "wave" ? XiaoyuAnimation.wave : XiaoyuAnimation.animation(for: mood)
            if let frame = atlas.frame(for: animation, elapsed: reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt)) {
                Image(decorative: frame, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.circle")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: mood) { startedAt = Date() }
    }
}
