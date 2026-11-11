import XCTest
@testable import DSHPet

final class SpriteRenderCadenceTests: XCTestCase {
    func testSpriteAnimationsRedrawAtTheirShortestFrame() {
        XCTAssertEqual(XiaoyuAnimation.renderInterval, 1.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(XiaoyuAnimation.idle.minimumFrameInterval, 0.12, accuracy: 0.0001)
        XCTAssertEqual(XiaoyuAnimation.waiting.minimumFrameInterval, 0.20, accuracy: 0.0001)
        XCTAssertEqual(XiaoyuAnimation.done.minimumFrameInterval, 0.12, accuracy: 0.0001)
        XCTAssertEqual(XiaoyuAnimation.wave.minimumFrameInterval, 0.14, accuracy: 0.0001)
        XCTAssertEqual(XiaoyuAnimation.disconnected.minimumFrameInterval, 1.0, accuracy: 0.0001)
        XCTAssertEqual(XiaoyuDragDirection.frameDuration, 0.08, accuracy: 0.0001)
        XCTAssertEqual(CodexSpriteAtlas.jingyuniangQIdleFrameDurations.min(), 0.08)
    }
}
