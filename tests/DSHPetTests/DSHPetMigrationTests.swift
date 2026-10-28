import XCTest
@testable import DSHPet

final class DSHPetMigrationTests: XCTestCase {
    func testLegacyKeysCopyIntoDSHPetNamespaceWithoutDeletingSource() throws {
        let suite = "DSHPetMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("xiaoyu", forKey: "moodball.skin")
        defaults.set(140.0, forKey: "settings.ballSize")
        defaults.set(12.0, forKey: "ballPositionX")
        DSHPetMigration.migrate(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "dsh-pet.skin"), "xiaoyu")
        XCTAssertEqual(defaults.string(forKey: "moodball.skin"), "xiaoyu")
        XCTAssertEqual(defaults.double(forKey: "settings.ballSize"), 140.0)
        XCTAssertEqual(defaults.double(forKey: "ballPositionX"), 12.0)
    }

    func testLegacyBundleDomainMigratesVisibilityAndPreservesNewValues() throws {
        let oldSuite = "DSHPetMigrationTests.Legacy.\(UUID().uuidString)"
        let newSuite = "DSHPetMigrationTests.Current.\(UUID().uuidString)"
        let oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        let newDefaults = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        defer {
            oldDefaults.removePersistentDomain(forName: oldSuite)
            newDefaults.removePersistentDomain(forName: newSuite)
        }

        oldDefaults.set(false, forKey: "moodball.isBallVisible")
        oldDefaults.set(140.0, forKey: "settings.ballSize")
        newDefaults.set(true, forKey: "dsh-pet.isPetVisible")
        DSHPetMigration.migrate(from: oldDefaults, to: newDefaults)

        XCTAssertEqual(newDefaults.bool(forKey: "dsh-pet.isBallVisible"), false)
        XCTAssertEqual(newDefaults.double(forKey: "settings.ballSize"), 140.0)
        XCTAssertTrue(newDefaults.bool(forKey: "dsh-pet.isPetVisible"))
        XCTAssertFalse(oldDefaults.bool(forKey: "moodball.isBallVisible"))
    }
}
