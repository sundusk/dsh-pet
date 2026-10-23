import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import MoodBall

@MainActor
final class CustomPetLibraryTests: XCTestCase {
    func testImportCopiesPackageSoSourceCanBeRemovedAndRefreshed() throws {
        let root = try temporaryDirectory()
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let source = try makePackage(at: sourceRoot)
        let library = CustomPetLibrary(directory: libraryRoot)

        let imported = try library.importPet(from: source)
        XCTAssertEqual(library.pets.count, 1)
        XCTAssertEqual(library.pets.first?.id, imported.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.spriteURL.path))
        XCTAssertNotNil(library.atlas(for: imported.skin))

        try FileManager.default.removeItem(at: source)
        let restarted = CustomPetLibrary(directory: libraryRoot)
        try restarted.refresh()

        let reloaded = try XCTUnwrap(restarted.pets.first)
        XCTAssertEqual(reloaded.id, imported.id)
        XCTAssertEqual(restarted.displayName(for: reloaded.skin), "测试宠物")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.spriteURL.path))
        XCTAssertNotNil(restarted.atlas(for: reloaded.skin))
    }

    func testRefreshPersistsImportedPetAcrossLibraryRestart() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(at: root.appendingPathComponent("source", isDirectory: true))
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)

        let library = CustomPetLibrary(directory: libraryRoot)
        let imported = try library.importPet(from: source)
        let restarted = CustomPetLibrary(directory: libraryRoot)
        try restarted.refresh()

        let loaded = try XCTUnwrap(restarted.pets.first)
        XCTAssertEqual(loaded.id, imported.id)
        XCTAssertEqual(loaded.displayName, imported.displayName)
        XCTAssertEqual(loaded.description, imported.description)
        XCTAssertEqual(loaded.skin.rawValue, imported.skin.rawValue)
    }

    func testDuplicateImportDoesNotOverwriteExistingCopy() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(at: root.appendingPathComponent("source", isDirectory: true))
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))

        let imported = try library.importPet(from: source)
        let originalBytes = try Data(contentsOf: imported.spriteURL)

        XCTAssertThrowsError(try library.importPet(from: source))
        XCTAssertEqual(library.pets.count, 1)
        XCTAssertEqual(try Data(contentsOf: imported.spriteURL), originalBytes)
    }

    func testRemoveDeletesOnlyAppCopyAndKeepsSourcePackage() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(at: root.appendingPathComponent("source", isDirectory: true))
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let imported = try library.importPet(from: source)

        try library.remove(imported)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.spriteURL.path))
        XCTAssertTrue(library.pets.isEmpty)
    }

    func testValidatePackageAcceptsCodexV2AtlasAndMetadata() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(
            at: root.appendingPathComponent("source", isDirectory: true),
            id: "fixture-id",
            displayName: "自定义鲸鱼",
            description: "用于测试的桌宠"
        )
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))

        let validated = try library.validatePackage(at: source)

        XCTAssertEqual(validated.displayName, "自定义鲸鱼")
        XCTAssertEqual(validated.description, "用于测试的桌宠")
        XCTAssertNotNil(validated.atlas.frame(for: .idle, elapsed: 0))
        XCTAssertTrue(samePixels(
            try XCTUnwrap(validated.atlas.frame(for: .disconnected, elapsed: 0)),
            try XCTUnwrap(validated.atlas.frame(for: .disconnected, elapsed: 5))
        ))
    }

    func testValidatePackageAllowsOptionalDescription() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(
            at: root.appendingPathComponent("source", isDirectory: true),
            description: nil
        )
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))

        let validated = try library.validatePackage(at: source)

        XCTAssertEqual(validated.displayName, "测试宠物")
        XCTAssertEqual(validated.description, "")
        XCTAssertNotNil(validated.atlas.frame(for: .idle, elapsed: 0))
    }

    func testValidatePackageRejectsMissingMetadataOrSpriteFile() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(at: root.appendingPathComponent("source", isDirectory: true))
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        try FileManager.default.removeItem(at: source.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try library.validatePackage(at: source))

        let missingSprite = try makePackage(
            at: root.appendingPathComponent("missing", isDirectory: true),
            spritesheetPath: "missing.webp",
            copyAtlas: false
        )
        XCTAssertThrowsError(try library.validatePackage(at: missingSprite))
    }

    func testValidatePackageRejectsUnsupportedVersionCorruptImageAndWrongDimensions() throws {
        let root = try temporaryDirectory()
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))

        let wrongVersion = try makePackage(
            at: root.appendingPathComponent("wrong-version", isDirectory: true),
            spriteVersionNumber: 1
        )
        XCTAssertThrowsError(try library.validatePackage(at: wrongVersion))

        let corrupt = try makePackage(
            at: root.appendingPathComponent("corrupt", isDirectory: true),
            atlasData: Data("not an image".utf8)
        )
        XCTAssertThrowsError(try library.validatePackage(at: corrupt))

        let wrongDimensions = try makePackage(
            at: root.appendingPathComponent("wrong-dimensions", isDirectory: true),
            spritesheetPath: "spritesheet.png",
            atlasData: try pngData(width: 100, height: 100, alpha: 255)
        )
        XCTAssertThrowsError(try library.validatePackage(at: wrongDimensions))
    }

    func testValidatePackageRejectsTransparentAtlasWithNoRequiredFirstFrameContent() throws {
        let root = try temporaryDirectory()
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let blank = try makePackage(
            at: root.appendingPathComponent("blank", isDirectory: true),
            spritesheetPath: "spritesheet.png",
            atlasData: try pngData(width: 1536, height: 2288, alpha: 0)
        )

        XCTAssertThrowsError(try library.validatePackage(at: blank))
    }

    func testValidatePackageRejectsPathEscapeAndSymbolicLink() throws {
        let root = try temporaryDirectory()
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let escaped = try makePackage(
            at: root.appendingPathComponent("escaped", isDirectory: true),
            spritesheetPath: "../outside.webp",
            copyAtlas: false
        )
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.webp"))
        XCTAssertThrowsError(try library.validatePackage(at: escaped))

        let symlink = try makePackage(
            at: root.appendingPathComponent("symlink", isDirectory: true),
            spritesheetPath: "spritesheet.webp",
            copyAtlas: false
        )
        try FileManager.default.createSymbolicLink(
            at: symlink.appendingPathComponent("spritesheet.webp"),
            withDestinationURL: xinzhizhuAtlasURL()
        )
        XCTAssertThrowsError(try library.validatePackage(at: symlink))

        let absolute = try makePackage(
            at: root.appendingPathComponent("absolute", isDirectory: true),
            spritesheetPath: "/tmp/outside.webp",
            copyAtlas: false
        )
        XCTAssertThrowsError(try library.validatePackage(at: absolute))

        let manifestSource = try makePackage(
            at: root.appendingPathComponent("manifest-source", isDirectory: true)
        ).appendingPathComponent("pet.json")
        let manifestSymlink = try makePackage(
            at: root.appendingPathComponent("manifest-symlink", isDirectory: true),
            copyAtlas: false
        )
        try FileManager.default.removeItem(at: manifestSymlink.appendingPathComponent("pet.json"))
        try FileManager.default.createSymbolicLink(
            at: manifestSymlink.appendingPathComponent("pet.json"),
            withDestinationURL: manifestSource
        )
        XCTAssertThrowsError(try library.validatePackage(at: manifestSymlink))
    }

    func testValidatePackageRejectsOversizedSpriteFile() throws {
        let root = try temporaryDirectory()
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let oversized = try makePackage(
            at: root.appendingPathComponent("oversized", isDirectory: true),
            spritesheetPath: "spritesheet.webp",
            atlasData: Data(repeating: 0, count: 20 * 1024 * 1024 + 1)
        )

        XCTAssertThrowsError(try library.validatePackage(at: oversized))
    }

    func testCustomSkinRawValueRoundTripsAndInvalidSelectionFallsBack() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(at: root.appendingPathComponent("source", isDirectory: true))
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let imported = try library.importPet(from: source)

        let skin = imported.skin
        XCTAssertTrue(skin.rawValue.hasPrefix("custom:"))
        XCTAssertEqual(FloatingPetSkin(rawValue: skin.rawValue), skin)

        let defaults = try temporaryDefaults()
        let settings = PetSettings(defaults: defaults, petLibrary: library)
        settings.skin = skin
        XCTAssertEqual(defaults.string(forKey: "moodball.skin"), skin.rawValue)

        let restarted = PetSettings(defaults: defaults, petLibrary: library)
        XCTAssertEqual(restarted.skin, skin)

        try library.remove(imported)
        let afterRemoval = PetSettings(defaults: defaults, petLibrary: library)
        XCTAssertEqual(afterRemoval.skin, .jingyuniang)
        XCTAssertEqual(defaults.string(forKey: "moodball.skin"), FloatingPetSkin.jingyuniang.rawValue)

        defaults.set("custom:missing", forKey: "moodball.skin")
        let invalid = PetSettings(defaults: defaults, petLibrary: library)
        XCTAssertEqual(invalid.skin, .jingyuniang)
        XCTAssertEqual(defaults.string(forKey: "moodball.skin"), FloatingPetSkin.jingyuniang.rawValue)
    }

    func testImportedStandardAtlasUsesSixIdleFramesWithoutReadingEmptyCells() throws {
        let root = try temporaryDirectory()
        let source = try makePackage(
            at: root.appendingPathComponent("source", isDirectory: true),
            spritesheetPath: "spritesheet.png",
            atlasData: try sixFrameIdleAtlasData()
        )
        let library = CustomPetLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let imported = try library.importPet(from: source)
        let atlas = try XCTUnwrap(library.atlas(for: imported.skin))

        let idleDurations = Array(XiaoyuAnimation.idle.frameDurations.prefix(6))
        let idleDuration = idleDurations.reduce(0, +)
        var elapsed: TimeInterval = 0
        for duration in idleDurations {
            let frame = try XCTUnwrap(atlas.frame(for: .idle, elapsed: elapsed + duration / 2))
            XCTAssertTrue(hasVisiblePixels(frame))
            elapsed += duration
        }
        let wrapped = try XCTUnwrap(atlas.frame(for: .idle, elapsed: idleDuration + 0.001))
        XCTAssertTrue(hasVisiblePixels(wrapped))
        XCTAssertTrue(samePixels(wrapped, try XCTUnwrap(atlas.frame(for: .idle, elapsed: 0.001))))
    }

    private func makePackage(
        at package: URL,
        id: String = "fixture-\(UUID().uuidString)",
        displayName: String = "测试宠物",
        description: String? = "导入测试",
        spriteVersionNumber: Int = 2,
        spritesheetPath: String = "spritesheet.webp",
        atlasData: Data? = nil,
        copyAtlas: Bool = true
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        var metadata: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "spriteVersionNumber": spriteVersionNumber,
            "spritesheetPath": spritesheetPath,
        ]
        if let description { metadata["description"] = description }
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try json.write(to: package.appendingPathComponent("pet.json"), options: .atomic)

        guard copyAtlas || atlasData != nil else { return package }
        let atlasURL = package.appendingPathComponent(spritesheetPath)
        try fileManager.createDirectory(at: atlasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let atlasData {
            try atlasData.write(to: atlasURL, options: .atomic)
        } else {
            try fileManager.copyItem(at: xinzhizhuAtlasURL(), to: atlasURL)
        }
        return package
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodBallCustomPet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suiteName = "MoodBallTests.CustomPetSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func xinzhizhuAtlasURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Pet/Xinzhizhu/XinzhizhuSprites.webp")
    }

    private func pngData(width: Int, height: Int, alpha: UInt8) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let pixels = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        for index in stride(from: 3, to: byteCount, by: 4) {
            pixels.storeBytes(of: alpha, toByteOffset: index, as: UInt8.self)
        }
        let context = try XCTUnwrap(CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let outputDestination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(outputDestination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(outputDestination))
        return output as Data
    }

    private func sixFrameIdleAtlasData() throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(xinzhizhuAtlasURL() as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let cells = try XiaoyuSpriteAtlas.decodeCells(image: image, rows: 11)
        let width = 1536
        let height = 2288
        let pixels = UnsafeMutableRawPointer.allocate(
            byteCount: width * height * 4,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGImage cropping uses the top row for row 0; flip the bitmap context
        // so the reassembled PNG preserves the source atlas row order.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for row in 0..<11 {
            for column in 0..<8 where !(row == 0 && column >= 6) {
                context.draw(
                    cells[row][column],
                    in: CGRect(x: column * 192, y: row * 208, width: 192, height: 208)
                )
            }
        }
        let outputImage = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, outputImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func hasVisiblePixels(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    private func samePixels(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        var left = [UInt8](repeating: 0, count: lhs.width * lhs.height * 4)
        var right = [UInt8](repeating: 0, count: rhs.width * rhs.height * 4)
        guard let leftContext = CGContext(
            data: &left,
            width: lhs.width,
            height: lhs.height,
            bitsPerComponent: 8,
            bytesPerRow: lhs.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let rightContext = CGContext(
            data: &right,
            width: rhs.width,
            height: rhs.height,
            bitsPerComponent: 8,
            bytesPerRow: rhs.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        leftContext.draw(lhs, in: CGRect(x: 0, y: 0, width: lhs.width, height: lhs.height))
        rightContext.draw(rhs, in: CGRect(x: 0, y: 0, width: rhs.width, height: rhs.height))
        return left == right
    }
}
