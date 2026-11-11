import XCTest
@testable import DSHPet

@MainActor
final class PetSettingsVisibilityTests: XCTestCase {
    func testFloatingPetSkinOrderPutsJingyuniangFirst() {
        XCTAssertEqual(
            FloatingPetSkin.allCases,
            [.jingyuniang, .jingyuniangQ, .xiaoyu, .xinzhizhu, .classic]
        )
    }

    func testJingyuniangQSelectionPersistsAcrossRestart() throws {
        let suite = "DSHPetTests.JingyuniangQ.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(FloatingPetSkin.jingyuniangQ.label, "鲸鱼娘Q版")
        XCTAssertTrue(FloatingPetSkin.jingyuniangQ.isSprite)
        XCTAssertEqual(FloatingPetSkin(rawValue: FloatingPetSkin.jingyuniangQ.rawValue), .jingyuniangQ)
        let settings = PetSettings(defaults: defaults)
        settings.skin = .jingyuniangQ
        XCTAssertEqual(PetSettings(defaults: defaults).skin, .jingyuniangQ)
    }

    func testFirstInstallDefaultsToJingyuniangAndPersistsAcrossRestart() {
        let suite = "DSHPetTests.PetSettingsDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = PetSettings(defaults: defaults)
        XCTAssertEqual(firstLaunch.skin, .jingyuniang)
        XCTAssertEqual(defaults.string(forKey: "dsh-pet.skin"), FloatingPetSkin.jingyuniang.rawValue)

        firstLaunch.skin = .xinzhizhu
        let restart = PetSettings(defaults: defaults)
        XCTAssertEqual(restart.skin, .xinzhizhu)
    }

    func testExistingValidSkinIsNotOverwrittenAndInvalidSkinFallsBackToJingyuniang() {
        let savedSuite = "DSHPetTests.PetSettingsSaved.\(UUID().uuidString)"
        let savedDefaults = UserDefaults(suiteName: savedSuite)!
        defer { savedDefaults.removePersistentDomain(forName: savedSuite) }
        savedDefaults.set(FloatingPetSkin.xiaoyu.rawValue, forKey: "dsh-pet.skin")

        XCTAssertEqual(PetSettings(defaults: savedDefaults).skin, .xiaoyu)
        XCTAssertEqual(savedDefaults.string(forKey: "dsh-pet.skin"), FloatingPetSkin.xiaoyu.rawValue)

        let invalidSuite = "DSHPetTests.PetSettingsInvalid.\(UUID().uuidString)"
        let invalidDefaults = UserDefaults(suiteName: invalidSuite)!
        defer { invalidDefaults.removePersistentDomain(forName: invalidSuite) }
        invalidDefaults.set("unknown-pet", forKey: "dsh-pet.skin")

        XCTAssertEqual(PetSettings(defaults: invalidDefaults).skin, .jingyuniang)
        XCTAssertEqual(invalidDefaults.string(forKey: "dsh-pet.skin"), FloatingPetSkin.jingyuniang.rawValue)
    }

    func testResetMoodColorsRestoresDefaults() throws {
        let suite = "DSHPetTests.MoodColorReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("FF0000", forKey: "dsh-pet.moodColor.idle")

        let settings = PetSettings(defaults: defaults)
        XCTAssertEqual(colorToHex(try XCTUnwrap(settings.moodColors["idle"])), 0xFF0000)

        settings.resetMoodColors()
        XCTAssertEqual(colorToHex(try XCTUnwrap(settings.moodColors["idle"])), 0x60A5FA)
        XCTAssertNil(defaults.string(forKey: "dsh-pet.moodColor.idle"))
        XCTAssertEqual(colorToHex(try XCTUnwrap(PetSettings(defaults: defaults).moodColors["idle"])), 0x60A5FA)
    }

    func testXiaoyuUsesWorkingAnimationForToolCalls() {
        XCTAssertEqual(XiaoyuAnimation.animation(for: "jumping"), .waiting)
        XCTAssertEqual(XiaoyuAnimation.animation(for: "stopped"), .failed)
    }

    func testPetVisibilityPersistsAndCanBeShownAgain() {
        let suite = "DSHPetTests.PetVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "dsh-pet.isPetVisible")

        let settings = PetSettings(defaults: defaults)
        XCTAssertFalse(settings.isPetVisible)

        settings.isPetVisible = true
        XCTAssertTrue(defaults.bool(forKey: "dsh-pet.isPetVisible"))
    }
}
