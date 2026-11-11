import SwiftUI
import XCTest
@testable import DSHPet

final class BubbleAndStatusPresentationTests: XCTestCase {
    func testBubbleDoubleTapOpensTaskPageAndFallsBackToHarness() {
        let task = DSHPetBubblePresentation(
            style: .task,
            title: "任务",
            detail: nil,
            pageNumber: 2,
            stackDepth: 1,
            interactive: true,
            taskID: "session-1"
        )
        let aggregate = DSHPetBubblePresentation(
            style: .aggregate,
            title: "2 个任务",
            detail: nil,
            pageNumber: 1,
            stackDepth: 1,
            interactive: true,
            taskID: nil
        )
        let legacy = DSHPetBubblePresentation(
            style: .single,
            title: "搞定啦",
            detail: nil,
            pageNumber: nil,
            stackDepth: 0,
            interactive: false,
            taskID: nil
        )

        XCTAssertEqual(task.doubleTapAction, .openTask("session-1"))
        XCTAssertEqual(aggregate.doubleTapAction, .openHarness)
        XCTAssertEqual(legacy.doubleTapAction, .openHarness)
    }

    func testStoppedBallUsesWhiteEyesAndRing() {
        XCTAssertEqual(colorToHex(StatusBallAppearance.eyeColor(for: "stopped", configured: .black)), 0xFFFFFF)
        XCTAssertEqual(colorToHex(StatusBallAppearance.eyeColor(for: "idle", configured: .black)), 0x000000)
        XCTAssertTrue(StatusBallAppearance.showsStoppedRing(for: "stopped"))
        XCTAssertFalse(StatusBallAppearance.showsStoppedRing(for: "idle"))
    }
}
