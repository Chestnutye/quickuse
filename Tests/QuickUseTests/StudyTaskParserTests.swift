import XCTest
@testable import QuickUse

final class StudyTaskParserTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/FoF-Week1-笔记_中文.md")

    private func parse(_ lines: [String]) -> [StudyTask] {
        StudyTaskParser.parse(lines: lines, file: file)
    }

    func testParsesFieldsAndCourse() throws {
        let task = try XCTUnwrap(parse([
            "- [ ] **打印 PV 表**：下周上课带来，见 [[Time value of money|货币时间价值]] ⏫ 📅 2026-10-16 🆔 FoF-W1-24",
        ]).first)
        XCTAssertEqual(task.course, "FoF")
        XCTAssertEqual(task.week, 1)
        XCTAssertEqual(task.title, "打印 PV 表")
        XCTAssertEqual(task.detail, "下周上课带来，见 货币时间价值")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.due, DateComponents(year: 2026, month: 10, day: 16))
        XCTAssertEqual(task.id, "FoF-W1-24")
        XCTAssertFalse(task.isDone)
        XCTAssertEqual(task.reminderTitle, "[FoF] 打印 PV 表")
    }

    func testIgnoresPlainListsAndCodeBlocks() {
        let tasks = parse([
            "- 不是待办",
            "```tasks",
            "- [ ] 代码块里的不算",
            "```",
            "  * [x] 缩进的已完成 ✅ 2026-10-12",
        ])
        XCTAssertEqual(tasks.map(\.title), ["缩进的已完成"])
        XCTAssertEqual(tasks.first?.line, 4)
        XCTAssertEqual(tasks.first?.isDone, true)
    }

    func testLongTitleIsTruncatedAndKeptInDetail() throws {
        let long = String(repeating: "很长的待办", count: 12)
        let task = try XCTUnwrap(parse(["- [ ] \(long)"]).first)
        XCTAssertTrue(task.title.hasSuffix("…"))
        XCTAssertEqual(task.title.count, 41)
        XCTAssertEqual(task.detail, long)
    }

    func testSetDoneAddsAndRemovesDoneDate() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let line = "- [ ] **熟悉 STATA** ⏫ 📅 2026-10-16 🆔 QM-W1-25"
        let done = StudyTaskParser.setDone(line, true, on: date)
        XCTAssertEqual(done, "- [x] **熟悉 STATA** ⏫ 📅 2026-10-16 🆔 QM-W1-25 ✅ 2026-10-12")
        XCTAssertEqual(StudyTaskParser.setDone(done, false), line)
    }

    func testAddIDKeepsLineParseable() throws {
        let line = StudyTaskParser.addID("- [ ] 读第 1 章 🔼  ", "FoF-W1-abcde")
        XCTAssertEqual(line, "- [ ] 读第 1 章 🔼 🆔 FoF-W1-abcde")
        let task = try XCTUnwrap(parse([line]).first)
        XCTAssertEqual(task.id, "FoF-W1-abcde")
        XCTAssertEqual(task.title, "读第 1 章")
        XCTAssertEqual(task.priority, .medium)
    }

    func testReadsIDFromReminderNotes() {
        XCTAssertEqual(StudyTaskParser.id(inNotes: "下周上课带来\nID: FoF-W1-24 · FoF-Week1-笔记_中文"), "FoF-W1-24")
        XCTAssertNil(StudyTaskParser.id(inNotes: "没有编号"))
        XCTAssertNil(StudyTaskParser.id(inNotes: nil))
    }

    func testMetaSignatureChangesWithDueDate() throws {
        let a = try XCTUnwrap(parse(["- [ ] 交作业 📅 2026-10-16"]).first)
        let b = try XCTUnwrap(parse(["- [ ] 交作业 📅 2026-10-17"]).first)
        let c = try XCTUnwrap(parse(["- [x] 交作业 📅 2026-10-16 ✅ 2026-10-15"]).first)
        XCTAssertNotEqual(a.metaSignature, b.metaSignature)
        XCTAssertEqual(a.metaSignature, c.metaSignature, "勾选状态不算内容变化")
    }
}
