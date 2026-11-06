import XCTest
@testable import DSHPet

final class ActivitySummaryTests: XCTestCase {
    func testSingleTaskKeepsTheExistingMoodLabels() {
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "authorizing", taskCount: 1), "等待你的授权")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "jumping", taskCount: 1), "工具调用")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "idle", taskCount: 1), "空闲")
    }

    func testMultipleTasksUseThePrimaryMoodAndTheTotalCount() {
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "jumping", taskCount: 2), "2 个任务进行中")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "waiting", taskCount: 2), "2 个任务进行中")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "authorizing", taskCount: 2), "2 个任务等待操作")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "questioning", taskCount: 2), "2 个任务等待操作")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "failed", taskCount: 3), "3 个任务出错了")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "done", taskCount: 2), "2 个任务已完成")
        XCTAssertEqual(MoodColorMap.aggregateLabel(for: "stopped", taskCount: 2), "2 个任务已停止")
    }
}
