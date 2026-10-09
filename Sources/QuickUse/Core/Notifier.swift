import AppKit
@preconcurrency import UserNotifications

/// 系统通知，带防抖，避免短时间内连续操作刷出一堆通知。
///
/// 同一类别（`Category`）的通知按以下规则处理：
/// - 防抖（debounce）：收到后等 `quietInterval` 秒，期间又有新通知就重新计时，安静下来才发送。
/// - 最长等待（max wait）：从这一批第一条算起最多等 `maxWait` 秒，到点立即发送，避免一直被推迟。
/// - 合并（coalesce）：一批里的多条合成一条；`latestOnly` 的类别只发最后一条（例如 Wi‑Fi 只关心最终结果）。
/// - 覆盖（replace）：同类别通知使用固定 identifier，新通知替换通知中心里的旧通知，不会堆积。
///
/// 分类开关保存在 UserDefaults，`GeneralSettingsView` 里可调。
@MainActor
enum Notifier {
    enum Category: String, CaseIterable {
        case wifi = "notify.wifi"
        case automation = "notify.automation"

        var title: String {
            switch self {
            case .wifi: "Wi‑Fi 切换成功或失败时通知"
            case .automation: "自动化执行时通知"
            }
        }

        /// 一批里只保留最后一条。
        var latestOnly: Bool { self == .wifi }
    }

    static let quietInterval: TimeInterval = 2
    static let maxWait: TimeInterval = 6

    private struct Item {
        let title: String
        let body: String
        let isError: Bool
    }

    private struct Batch {
        var items: [Item] = []
        var startedAt = Date()
        var timer: Timer?
    }

    private static var batches: [Category: Batch] = [:]

    static func isEnabled(_ category: Category) -> Bool {
        UserDefaults.standard.object(forKey: category.rawValue) as? Bool ?? true
    }

    static func post(_ category: Category, title: String, body: String = "", isError: Bool = false) {
        guard isEnabled(category) else { return }
        var batch = batches[category] ?? Batch()
        batch.items.append(Item(title: title, body: body, isError: isError))
        batch.timer?.invalidate()
        let deadline = batch.startedAt.addingTimeInterval(maxWait).timeIntervalSinceNow
        let delay = max(0, min(quietInterval, deadline))
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in flush(category) }
        }
        // 加到 .common 模式，菜单展开期间也会照常触发。
        RunLoop.main.add(timer, forMode: .common)
        batch.timer = timer
        batches[category] = batch
    }

    private static func flush(_ category: Category) {
        guard let batch = batches.removeValue(forKey: category), let last = batch.items.last else { return }
        let item: Item
        if category.latestOnly || batch.items.count == 1 {
            item = last
        } else {
            let errors = batch.items.filter(\.isError).count
            item = Item(title: errors > 0 ? "\(batch.items.count) 条通知，其中 \(errors) 条失败" : "\(batch.items.count) 条通知",
                        body: batch.items.map(\.title).joined(separator: "\n"),
                        isError: errors > 0)
        }
        deliver(category, item)
    }

    /// 失败的通知在用户关闭了系统通知权限时改用弹窗，保证一定能看到。
    private static func deliver(_ category: Category, _ item: Item) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            let allowed = status == .authorized || status == .provisional
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.threadIdentifier = category.rawValue
                if item.isError { content.sound = .default }
                try? await center.add(UNNotificationRequest(identifier: category.rawValue, content: content, trigger: nil))
            } else if item.isError {
                NSAlert.show(item.title, item.body)
            }
        }
    }
}
