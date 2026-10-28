import CoreGraphics
import XCTest
@testable import DSHPet

@MainActor
final class XinzhizhuSpriteTests: XCTestCase {
    func testJingyuniangUsesItsSixFrameIdleAndOriginalActionRows() throws {
        XCTAssertEqual(FloatingPetSkin.jingyuniang.label, "鲸鱼娘")
        XCTAssertTrue(FloatingPetSkin.jingyuniang.isSprite)
        try assertSixFrameIdleAndOriginalActionRows(at: xinzhizhuAtlasURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Jingyuniang/JingyuniangSprites.png"))
    }

    func testJingyuniangQUsesItsSixFrameIdleAndOriginalActionRows() throws {
        let directory = xinzhizhuAtlasURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JingyuniangQ")
        let library = CustomPetLibrary(directory: directory.appendingPathComponent("unused"))
        let package = try library.validatePackage(at: directory)
        XCTAssertEqual(package.displayName, "鲸鱼娘Q版")
        try assertSixFrameIdleAndOriginalActionRows(at: directory.appendingPathComponent("JingyuniangQSprites.webp"))
    }

    private func assertSixFrameIdleAndOriginalActionRows(at url: URL) throws {
        let atlas = try CodexSpriteAtlas(resourceURL: url, idleFrameCount: 6)
        let source = try XiaoyuSpriteAtlas.decodeCells(resourceURL: url, rows: 11)
        for animation in XiaoyuAnimation.allCases {
            let durations = animation == .idle
                ? Array(animation.frameDurations.prefix(6)) : animation.frameDurations
            var elapsed: TimeInterval = 0
            for (index, duration) in durations.enumerated() {
                let frame = try XCTUnwrap(atlas.frame(for: animation, elapsed: elapsed + duration / 2))
                XCTAssertTrue(samePixels(frame, source[CodexSpriteAtlas.row(for: animation)][index]))
                let pixels = try XCTUnwrap(rgbaPixels(frame))
                XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
                elapsed += duration
            }
            let end = try XCTUnwrap(atlas.frame(for: animation, elapsed: elapsed + 0.001))
            let expected = animation.playback == .onceThenHold ? durations.count - 1 : 0
            XCTAssertTrue(samePixels(end, source[CodexSpriteAtlas.row(for: animation)][expected]))
            XCTAssertTrue(samePixels(
                try XCTUnwrap(atlas.frame(for: animation, elapsed: -1)),
                source[CodexSpriteAtlas.row(for: animation)][0]
            ))
        }
        for direction in XiaoyuDragDirection.allCases {
            for index in 0..<XiaoyuDragDirection.frameCount {
                let elapsed = (Double(index) + 0.5) * XiaoyuDragDirection.frameDuration
                let frame = try XCTUnwrap(atlas.dragFrame(for: direction, elapsed: elapsed))
                XCTAssertTrue(samePixels(frame, source[direction == .right ? 1 : 2][index]))
            }
        }
    }

    func testXinzhizhuIsListedAsSpritePet() {
        XCTAssertEqual(FloatingPetSkin.xinzhizhu.label, "新之助")
        XCTAssertTrue(FloatingPetSkin.xinzhizhu.isSprite)
        XCTAssertFalse(FloatingPetSkin.classic.isSprite)
        XCTAssertTrue(FloatingPetSkin.xiaoyu.isSprite)
    }

    func testXinzhizhuAtlasContainsEveryAnimationFrameAtExpectedCellSize() throws {
        let atlas = try CodexSpriteAtlas(resourceURL: xinzhizhuAtlasURL())
        let source = try XiaoyuSpriteAtlas.decodeCells(resourceURL: xinzhizhuAtlasURL(), rows: 11)

        for animation in XiaoyuAnimation.allCases {
            var elapsed: TimeInterval = 0
            for (index, duration) in animation.frameDurations.enumerated() {
                let frame = try XCTUnwrap(atlas.frame(for: animation, elapsed: elapsed + duration / 2))
                XCTAssertEqual(frame.width, 192, animation.rawValue)
                XCTAssertEqual(frame.height, 208, animation.rawValue)
                XCTAssertTrue(
                    samePixels(frame, source[CodexSpriteAtlas.row(for: animation)][index]),
                    "\(animation.rawValue) frame \(index)"
                )
                elapsed += duration
            }
        }
    }

    func testXinzhizhuAtlasClampsNegativeElapsedToFirstFrame() throws {
        let atlas = try CodexSpriteAtlas(resourceURL: xinzhizhuAtlasURL())

        for animation in XiaoyuAnimation.allCases {
            let first = try XCTUnwrap(atlas.frame(for: animation, elapsed: 0))
            let negative = try XCTUnwrap(atlas.frame(for: animation, elapsed: -1))
            XCTAssertTrue(samePixels(first, negative), animation.rawValue)
        }

        for direction in XiaoyuDragDirection.allCases {
            let first = try XCTUnwrap(atlas.dragFrame(for: direction, elapsed: 0))
            let negative = try XCTUnwrap(atlas.dragFrame(for: direction, elapsed: -1))
            XCTAssertTrue(samePixels(first, negative), "\(direction)")
        }
    }

    func testXinzhizhuIdleLoopsAtItsAnimationDuration() throws {
        let atlas = try CodexSpriteAtlas(resourceURL: xinzhizhuAtlasURL())
        XCTAssertEqual(XiaoyuAnimation.idle.frameDurations.count, 7)
        let duration = XiaoyuAnimation.idle.frameDurations.reduce(0, +)
        let first = try XCTUnwrap(atlas.frame(for: .idle, elapsed: 0))
        let wrapped = try XCTUnwrap(atlas.frame(for: .idle, elapsed: duration))

        XCTAssertTrue(samePixels(first, wrapped))
    }

    func testXinzhizhuFailedAnimationHoldsItsLastFrame() throws {
        let atlas = try CodexSpriteAtlas(resourceURL: xinzhizhuAtlasURL())
        let duration = XiaoyuAnimation.failed.frameDurations.reduce(0, +)
        let last = try XCTUnwrap(atlas.frame(for: .failed, elapsed: duration - 0.001))
        let held = try XCTUnwrap(atlas.frame(for: .failed, elapsed: duration + 1))

        XCTAssertTrue(samePixels(last, held))
    }

    func testXinzhizhuAnimationRowsMatchTheAtlasContract() {
        XCTAssertEqual(CodexSpriteAtlas.row(for: .disconnected), 0)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .idle), 0)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .waiting), 7)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .authorizing), 6)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .questioning), 6)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .done), 4)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .failed), 5)
        XCTAssertEqual(CodexSpriteAtlas.row(for: .wave), 3)
    }

    func testXinzhizhuDragRowsMatchTheAtlasContract() throws {
        let atlas = try CodexSpriteAtlas(resourceURL: xinzhizhuAtlasURL())
        let source = try XiaoyuSpriteAtlas.decodeCells(resourceURL: xinzhizhuAtlasURL(), rows: 11)
        let right = try XCTUnwrap(atlas.dragFrame(for: .right, elapsed: 0))
        let left = try XCTUnwrap(atlas.dragFrame(for: .left, elapsed: 0))

        XCTAssertTrue(samePixels(right, source[1][0]))
        XCTAssertTrue(samePixels(left, source[2][0]))
        XCTAssertFalse(samePixels(right, left))
    }

    private func xinzhizhuAtlasURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Pet/Xinzhizhu/XinzhizhuSprites.webp")
    }

    private func samePixels(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard let left = rgbaPixels(lhs), let right = rgbaPixels(rhs) else { return false }
        return left == right
    }

    private func rgbaPixels(_ image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let byteCount = width * height * 4
        let pixels = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { pixels.deallocate() }
        guard let context = CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes: pixels, count: byteCount)
    }
}
