import AppKit
import XCTest
@testable import MoodBall

@MainActor
final class StatusIconTests: XCTestCase {
    func testWhaleUsesAnAdaptiveTemplateWithTransparentBackground() throws {
        let icon = AppDelegate.makeStatusIcon()
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 22, height: 22))
        let image = try XCTUnwrap(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var filledPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                if alpha > 0.5 { filledPixels += 1 }
                if x == 0 || y == 0 || x == bitmap.pixelsWide - 1 || y == bitmap.pixelsHigh - 1 {
                    XCTAssertLessThan(alpha, 0.1, "Glyph must leave a transparent margin")
                }
            }
        }
        let area = bitmap.pixelsWide * bitmap.pixelsHigh
        XCTAssertGreaterThan(filledPixels, area / 5)
        XCTAssertLessThan(filledPixels, area / 2)
    }
}
