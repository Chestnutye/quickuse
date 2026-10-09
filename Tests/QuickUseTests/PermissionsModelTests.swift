import SwiftUI
import XCTest
@testable import QuickUse

/// 模拟“控制某个 App”这类权限：目标没运行时 `check` 返回 nil，`prepare` 会启动它。
@MainActor
private final class FakeTarget {
    var running = false
    var status = PermissionStatus.granted
    var launches = 0

    var item: PermissionItem {
        PermissionItem(id: "fake", title: "fake", reason: "", icon: "gear", tint: .gray,
                       check: { self.running ? self.status : nil },
                       prepare: { self.launches += 1; self.running = true },
                       request: {}, openSettings: {})
    }
}

@MainActor
final class PermissionsModelTests: XCTestCase {
    func testLaunchesTargetOnlyWhenStatusUnknown() async {
        let target = FakeTarget()
        let model = PermissionsModel(items: [target.item])

        await model.refresh()
        XCTAssertEqual(target.launches, 1)
        XCTAssertEqual(model.statuses["fake"], .granted)

        // 目标 App 退出后再刷新（例如每次打开菜单）：不再启动它，沿用上次的结果。
        target.running = false
        for _ in 0..<5 { await model.refresh() }
        XCTAssertEqual(target.launches, 1)
        XCTAssertEqual(model.statuses["fake"], .granted)
        XCTAssertTrue(model.missingRequired.isEmpty)

        // 目标在运行时照常更新状态。
        target.running = true
        target.status = .denied
        await model.refresh()
        XCTAssertEqual(model.statuses["fake"], .denied)
        XCTAssertEqual(model.missingRequired.map(\.id), ["fake"])
    }

    func testUnknownWithoutPrepareIsNotDetermined() async {
        let item = PermissionItem(id: "x", title: "x", reason: "", icon: "gear", tint: .gray,
                                  check: { nil }, request: {}, openSettings: {})
        let model = PermissionsModel(items: [item])
        await model.refresh()
        XCTAssertEqual(model.statuses["x"], .notDetermined)
    }
}
