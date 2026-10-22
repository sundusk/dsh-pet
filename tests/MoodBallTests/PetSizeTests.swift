import SwiftUI
import XCTest
@testable import MoodBall

@MainActor
final class PetSizeTests: XCTestCase {
    func testDesktopPetUsesSizeSettingsWithoutAnAgentUpdate() throws {
        let suite = "MoodBallTests.PetSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PetSettings(defaults: defaults)
        settings.skin = .jingyuniang
        settings.glowEnabled = false
        settings.showStatusBubble = false
        let model = MoodBallModel()
        let view = MoodBallView(model: model, settings: settings, onOpenDesktopHarness: {})

        for size: CGFloat in [60, 108, 200] {
            settings.ballSize = size
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(CGFloat(image.width), (size * 0.95).rounded(.up), accuracy: 1)
            XCTAssertEqual(CGFloat(image.height), (size * 1.10).rounded(.up), accuracy: 1)
        }
    }
}
