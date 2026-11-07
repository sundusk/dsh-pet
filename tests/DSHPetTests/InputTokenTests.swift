import XCTest
@testable import DSHPet

final class InputTokenTests: XCTestCase {
    func testFileAndSkillAtCursor() {
        let text = "请看 @\"目录 名/图 和 $ignored"
        let cursor = ("请看 @\"目录 名/图" as NSString).length
        let token = DSHPetInputToken.find(in: text, selection: NSRange(location: cursor, length: 0))
        XCTAssertEqual(token?.kind, .file)
        XCTAssertEqual(token?.query, "目录 名/图")
        XCTAssertEqual((text as NSString).substring(with: token!.range), "@\"目录 名/图")

        let skill = "你好 $review"
        XCTAssertEqual(DSHPetInputToken.find(in: skill, selection: NSRange(location: (skill as NSString).length, length: 0))?.query, "review")
    }

    func testEmailAndSelectedTextDoNotTrigger() {
        let email = "name@example.com"
        XCTAssertNil(DSHPetInputToken.find(in: email, selection: NSRange(location: (email as NSString).length, length: 0)))
        XCTAssertNil(DSHPetInputToken.find(in: "@file", selection: NSRange(location: 1, length: 1)))
        XCTAssertNil(DSHPetInputToken.find(in: "@\"closed\"", selection: NSRange(location: 9, length: 0)))
    }

    func testSkillSelectionReplacesPreviousPrefixWithoutLosingText() {
        let text = "/old 你好 $new world"
        let cursor = ("/old 你好 $new" as NSString).length
        let token = DSHPetInputToken.find(in: text, selection: NSRange(location: cursor, length: 0))!
        let edit = DSHPetInputEdit.apply(to: text, token: token, insertion: "/new ", previousSkill: "/old ")
        XCTAssertEqual(edit.text, "/new 你好  world")
        XCTAssertEqual((edit.text as NSString).substring(to: edit.cursor), "/new 你好 ")
    }

    func testSkillSelectionPreservesEditedPrefixAndFileKeepsUnicode() {
        let text = "/edited 内容 $skill"
        let token = DSHPetInputToken.find(in: text, selection: NSRange(location: (text as NSString).length, length: 0))!
        let edit = DSHPetInputEdit.apply(to: text, token: token, insertion: "/skill ", previousSkill: "/old ")
        XCTAssertEqual(edit.text, "/skill /edited 内容 ")

        let input = "@图😀后"
        let fileToken = DSHPetInputToken.find(in: input, selection: NSRange(location: 2, length: 0))!
        let file = DSHPetInputEdit.apply(to: input, token: fileToken, insertion: "@图片", previousSkill: nil)
        XCTAssertEqual(file.text, "@图片 😀后")
    }
}
