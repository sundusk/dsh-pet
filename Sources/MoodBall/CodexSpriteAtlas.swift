import Foundation
import CoreGraphics

/// 保留 Codex 原图的帧序与尺寸，只映射 DSH 的状态语义。
struct CodexSpriteAtlas {
    static let resourceName = "XinzhizhuSprites"
    private let cells: [[CGImage]]
    private let idleFrameCount: Int

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
        cells[Self.row(for: animation)][animation.frameIndex(elapsed: elapsed, frameCount: animation == .idle ? idleFrameCount : nil)]
    }

    func dragFrame(for direction: XiaoyuDragDirection, elapsed: TimeInterval) -> CGImage? {
        cells[direction == .right ? 1 : 2][direction.frameIndex(elapsed: elapsed)]
    }
}
