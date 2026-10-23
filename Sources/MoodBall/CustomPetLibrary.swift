import Foundation
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ImportedPet: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let spriteURL: URL

    var skin: FloatingPetSkin { .custom(id) }
}

struct ValidatedPetPackage {
    let displayName: String
    let description: String
    let atlas: CodexSpriteAtlas
    fileprivate let manifest: PetPackageManifest
    fileprivate let imageData: Data
    fileprivate let fingerprint: String
}

private struct PetPackageManifest: Codable {
    let id: String
    let displayName: String
    let description: String?
    let spriteVersionNumber: Int
    let spritesheetPath: String
}

enum CustomPetImportError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Imported assets belong to DSH Pet; original Codex packages are never modified.
@MainActor
final class CustomPetLibrary: ObservableObject {
    static let shared = CustomPetLibrary(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("DSH Pet/Pets", isDirectory: true))

    @Published private(set) var pets: [ImportedPet] = []
    @Published private(set) var loadError: String?
    let directory: URL
    private var atlases: [String: CodexSpriteAtlas] = [:]
    private var fingerprints: [String: String] = [:]

    init(directory: URL) {
        self.directory = directory
        do { try refresh() } catch { loadError = error.localizedDescription }
    }

    func displayName(for skin: FloatingPetSkin) -> String {
        pets.first(where: { $0.skin == skin })?.displayName ?? skin.label
    }

    func atlas(for skin: FloatingPetSkin) -> CodexSpriteAtlas? {
        guard case .custom(let id) = skin else { return nil }
        return atlases[id]
    }

    func validatePackage(at directory: URL) throws -> ValidatedPetPackage {
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CustomPetImportError.invalid("请选择包含 pet.json 的宠物文件夹。")
        }
        let manifestData = try readRegularFile(directory.appendingPathComponent("pet.json"), limit: 64 * 1024)
        let manifest: PetPackageManifest
        do { manifest = try JSONDecoder().decode(PetPackageManifest.self, from: manifestData) }
        catch { throw CustomPetImportError.invalid("pet.json 格式不正确，或缺少宠物名称、ID、图集路径与版本号。") }
        let name = manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !manifest.id.isEmpty, manifest.id.count <= 256,
              (manifest.description?.count ?? 0) <= 2000 else {
            throw CustomPetImportError.invalid("宠物名称或描述无效：名称最多 80 字，描述最多 2000 字。")
        }
        guard manifest.spriteVersionNumber == 2 else {
            throw CustomPetImportError.invalid("目前只支持 Codex v2 宠物包（spriteVersionNumber 为 2）。")
        }
        let path = manifest.spritesheetPath
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.hasPrefix("~"), !path.contains("\\") else {
            throw CustomPetImportError.invalid("图集必须是宠物文件夹内的相对路径。")
        }
        var imageURL = directory
        for component in components {
            imageURL.appendPathComponent(String(component))
            let values = try imageURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CustomPetImportError.invalid("宠物包不能通过符号链接引用外部文件。")
            }
        }
        guard ["png", "webp"].contains(imageURL.pathExtension.lowercased()) else {
            throw CustomPetImportError.invalid("宠物图集必须是 PNG 或 WebP 图片。")
        }
        let data = try readRegularFile(imageURL, limit: 20 * 1024 * 1024)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.webP.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 1536,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 2288 else {
            throw CustomPetImportError.invalid("请使用 1536 × 2288 像素的 Codex v2 图集（8 列 × 11 行）。")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo) else {
            throw CustomPetImportError.invalid("图集必须带有透明通道。")
        }
        let atlas = try CodexSpriteAtlas(importedImage: image)
        return ValidatedPetPackage(displayName: name, description: manifest.description ?? "", atlas: atlas,
            manifest: manifest, imageData: data, fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @discardableResult
    func importPet(from sourceDirectory: URL) throws -> ImportedPet {
        let package = try validatePackage(at: sourceDirectory)
        return try importPet(package)
    }

    @discardableResult
    func importPet(_ package: ValidatedPetPackage) throws -> ImportedPet {
        guard !fingerprints.values.contains(package.fingerprint) else {
            throw CustomPetImportError.invalid("这个宠物已经导入，可以直接在列表中使用。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let staging = directory.appendingPathComponent(".import-\(id)", isDirectory: true)
        let destination = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let imageName = "spritesheet.\((package.imageData.starts(with: [0x89, 0x50, 0x4e, 0x47])) ? "png" : "webp")"
        let manifest = PetPackageManifest(id: package.manifest.id, displayName: package.displayName,
            description: package.description, spriteVersionNumber: 2, spritesheetPath: imageName)
        try package.imageData.write(to: staging.appendingPathComponent(imageName), options: .atomic)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("pet.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: destination)
        let pet = ImportedPet(id: id, displayName: package.displayName, description: package.description,
            spriteURL: destination.appendingPathComponent(imageName))
        atlases[id] = package.atlas
        fingerprints[id] = package.fingerprint
        pets = (pets + [pet]).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return pet
    }

    func remove(_ pet: ImportedPet) throws {
        guard pets.contains(where: { $0.id == pet.id }), UUID(uuidString: pet.id) != nil else {
            throw CustomPetImportError.invalid("没有找到这个已导入的宠物。")
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(pet.id, isDirectory: true))
        atlases.removeValue(forKey: pet.id)
        fingerprints.removeValue(forKey: pet.id)
        pets.removeAll { $0.id == pet.id }
    }

    func refresh() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            atlases = [:]; fingerprints = [:]; pets = []; loadError = nil
            return
        }
        let folders = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var loaded: [ImportedPet] = []
        var loadedAtlases: [String: CodexSpriteAtlas] = [:]
        var loadedFingerprints: [String: String] = [:]
        var errors: [String] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            do {
                let package = try validatePackage(at: folder)
                let id = folder.lastPathComponent
                loaded.append(ImportedPet(id: id, displayName: package.displayName, description: package.description,
                    spriteURL: folder.appendingPathComponent(package.manifest.spritesheetPath)))
                loadedAtlases[id] = package.atlas
                loadedFingerprints[id] = package.fingerprint
            } catch { errors.append("\(folder.lastPathComponent)：\(error.localizedDescription)") }
        }
        atlases = loadedAtlases
        fingerprints = loadedFingerprints
        pets = loaded.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        loadError = errors.isEmpty ? nil : "部分宠物无法加载：\(errors.joined(separator: "；"))"
        if let loadError { throw CustomPetImportError.invalid(loadError) }
    }

    private func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CustomPetImportError.invalid("宠物包只能包含普通文件，不能使用符号链接。")
        }
        guard let size = values.fileSize, size > 0, size <= limit else {
            throw CustomPetImportError.invalid("宠物文件为空或过大：pet.json 不超过 64 KiB，图集不超过 20 MiB。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else {
            throw CustomPetImportError.invalid("宠物文件为空或超过大小限制。")
        }
        return data
    }
}
