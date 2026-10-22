import SwiftUI
import XCTest
@testable import MoodBall

@MainActor
final class PetPreviewTests: XCTestCase {
    func testResizingKeepsPreviewCenteredAndClearOfControls() throws {
        let suite = "MoodBallTests.PetPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PetSettings(defaults: defaults)
        // Render an asset-free pet; SwiftPM test bundles do not contain the sprite atlases.
        settings.skin = .moodBall
        settings.glowEnabled = false
        settings.showStatusBubble = true
        for mood in ["idle", "waiting"] {
            var centers: [CGFloat] = []
            for size: CGFloat in [60, 128, 192, 200] {
                settings.ballSize = size
                let renderer = ImageRenderer(content: PetPreview(settings: settings, mood: mood)
                    .frame(width: 272, height: 218))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let bounds = try petBounds(in: image)
                centers.append(bounds.midY)
                XCTAssertEqual(bounds.width, bounds.height, accuracy: 2,
                               "The round pet must fit without its bottom being clipped at size \(size)")
                XCTAssertEqual(bounds.midX, 136, accuracy: 6)
            }
            XCTAssertLessThan(try XCTUnwrap(centers.max()) - XCTUnwrap(centers.min()), 6,
                              "Changing size must not move the preview's center")
        }
    }

    private func petBounds(in image: CGImage) throws -> CGRect {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let channels = pixels[index...index + 2]
                if pixels[index + 3] > 80 && Int(channels.max()!) - Int(channels.min()!) > 20 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "Expected the pet to render")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
