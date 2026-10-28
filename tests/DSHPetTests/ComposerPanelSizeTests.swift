import AppKit
import XCTest
@testable import DSHPet

@MainActor
final class ComposerPanelSizeTests: XCTestCase {
    func testComposerPanelSizesFollowBarPhase() {
        let composerSize = NSSize(width: 340, height: 106)
        let resting = AppDelegate.composerPanelSize(
            for: .resting, expandedComposerSize: composerSize
        )
        let hovering = AppDelegate.composerPanelSize(
            for: .hovering, expandedComposerSize: composerSize
        )

        XCTAssertEqual(resting.width, DSHPetComposerView.restingPanelWidth)
        XCTAssertEqual(resting.height, DSHPetComposerView.restingPanelHeight)
        XCTAssertEqual(hovering.width, DSHPetComposerView.expandedBarPanelWidth)
        XCTAssertEqual(hovering.height, DSHPetComposerView.expandedBarPanelHeight)
        XCTAssertEqual(
            AppDelegate.composerPanelSize(
                for: .composer, expandedComposerSize: composerSize
            ),
            composerSize
        )
    }
}
