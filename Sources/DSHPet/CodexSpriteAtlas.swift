import Foundation
import CoreGraphics

/// 保留 Codex 原图的帧序与尺寸，只映射 DSH 的状态语义。
struct CodexSpriteAtlas {
    static let resourceName = "XinzhizhuSprites"
    private let cells: [[CGImage]]
    private let idleFrameCount: Int
    private var importedFrameCounts: [Int]?

    init(
        resourceName: String = Self.resourceName,
        fileExtension: String = "webp",
        idleFrameCount: Int = 7,
        bundle: Bundle = .main
    ) throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: fileExtension) else {
            throw XiaoyuSpriteAtlasError.missingResource
        }
        try self.init(resourceURL: url, idleFrameCount: idleFrameCount)
    }

    init(resourceURL: URL, idleFrameCount: Int = 7) throws {
        precondition((1...8).contains(idleFrameCount))
        self.idleFrameCount = idleFrameCount
        cells = try XiaoyuSpriteAtlas.decodeCells(resourceURL: resourceURL, rows: 11)
    }

    init(importedImage: CGImage) throws {
        // Decode compressed atlases once before cropping; each frame then shares bitmap storage.
        guard let context = CGContext(data: nil, width: importedImage.width, height: importedImage.height,
            bitsPerComponent: 8, bytesPerRow: importedImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XiaoyuSpriteAtlasError.unreadableImage
        }
        context.draw(importedImage, in: CGRect(x: 0, y: 0, width: importedImage.width, height: importedImage.height))
        guard let decodedImage = context.makeImage() else { throw XiaoyuSpriteAtlasError.unreadableImage }
        cells = try XiaoyuSpriteAtlas.decodeCells(image: decodedImage, rows: 11)
        idleFrameCount = 6
        var counts: [Int] = []
        for row in cells {
            let occupied = row.map(Self.hasVisiblePixels)
            guard let last = occupied.lastIndex(of: true), occupied.prefix(last + 1).allSatisfy({ $0 }) else {
                throw CustomPetImportError.invalid("图集中有缺失或不连续的动作帧。")
            }
            counts.append(last + 1)
        }
        guard counts[1] == 8, counts[2] == 8 else {
            throw CustomPetImportError.invalid("左右移动动作必须各包含 8 帧。")
        }
        importedFrameCounts = counts
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    static func row(for animation: XiaoyuAnimation) -> Int {
        switch animation {
        case .disconnected, .idle: return 0
        case .waiting: return 7
        case .authorizing, .questioning: return 6
        case .done: return 4
        case .failed: return 5
        case .wave: return 3
        }
    }

    func frame(for animation: XiaoyuAnimation, elapsed: TimeInterval) -> CGImage? {
        let row = Self.row(for: animation)
        let count = animation == .disconnected ? 1
            : importedFrameCounts?[row] ?? (animation == .idle ? idleFrameCount : animation.frameDurations.count)
        return cells[row][animation.frameIndex(elapsed: elapsed, frameCount: count)]
    }

    func dragFrame(for direction: XiaoyuDragDirection, elapsed: TimeInterval) -> CGImage? {
        cells[direction == .right ? 1 : 2][direction.frameIndex(elapsed: elapsed)]
    }
}
