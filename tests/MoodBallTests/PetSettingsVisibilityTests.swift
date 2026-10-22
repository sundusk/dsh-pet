import XCTest
@testable import MoodBall

@MainActor
final class PetSettingsVisibilityTests: XCTestCase {
    func testFloatingPetSkinOrderPutsJingyuniangFirst() {
        XCTAssertEqual(
            FloatingPetSkin.allCases,
            [.jingyuniang, .xiaoyu, .xinzhizhu, .moodBall]
        )
    }

    func testFirstInstallDefaultsToJingyuniangAndPersistsAcrossRestart() {
        let suite = "MoodBallTests.PetSettingsDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = PetSettings(defaults: defaults)
        XCTAssertEqual(firstLaunch.skin, .jingyuniang)
        XCTAssertEqual(defaults.string(forKey: "moodball.skin"), FloatingPetSkin.jingyuniang.rawValue)

        firstLaunch.skin = .xinzhizhu
        let restart = PetSettings(defaults: defaults)
        XCTAssertEqual(restart.skin, .xinzhizhu)
    }

    func testExistingValidSkinIsNotOverwrittenAndInvalidSkinFallsBackToJingyuniang() {
        let savedSuite = "MoodBallTests.PetSettingsSaved.\(UUID().uuidString)"
        let savedDefaults = UserDefaults(suiteName: savedSuite)!
        defer { savedDefaults.removePersistentDomain(forName: savedSuite) }
        savedDefaults.set(FloatingPetSkin.xiaoyu.rawValue, forKey: "moodball.skin")

        XCTAssertEqual(PetSettings(defaults: savedDefaults).skin, .xiaoyu)
        XCTAssertEqual(savedDefaults.string(forKey: "moodball.skin"), FloatingPetSkin.xiaoyu.rawValue)

        let invalidSuite = "MoodBallTests.PetSettingsInvalid.\(UUID().uuidString)"
        let invalidDefaults = UserDefaults(suiteName: invalidSuite)!
        defer { invalidDefaults.removePersistentDomain(forName: invalidSuite) }
        invalidDefaults.set("unknown-pet", forKey: "moodball.skin")

        XCTAssertEqual(PetSettings(defaults: invalidDefaults).skin, .jingyuniang)
        XCTAssertEqual(invalidDefaults.string(forKey: "moodball.skin"), FloatingPetSkin.jingyuniang.rawValue)
    }

    func testXiaoyuUsesWorkingAnimationForToolCalls() {
        XCTAssertEqual(XiaoyuAnimation.animation(for: "jumping"), .waiting)
    }

    func testPetVisibilityMigratesAndCanBeShownAgain() {
        let suite = "MoodBallTests.PetVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "moodball.isBallVisible")

        let settings = PetSettings(defaults: defaults)
        XCTAssertFalse(settings.isPetVisible)

        settings.isPetVisible = true
        XCTAssertTrue(defaults.bool(forKey: "moodball.isPetVisible"))
        XCTAssertFalse(MoodBallShortcutAction.allCases.map(\.rawValue).contains("toggleBallVisibility"))
    }
}
