import AppKit
import CoreLocation
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

enum PermissionStatus {
    case granted, denied, notDetermined

    var label: String {
        switch self {
        case .granted: "已允许"
        case .denied: "未允许"
        case .notDetermined: "还没询问"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        }
    }
}

/// 一项系统权限。模块通过 `Module.permissions()` 声明自己需要的权限。
struct PermissionItem: Identifiable {
    let id: String
    let title: String
    let reason: String
    let icon: String
    let tint: Color
    /// 必需权限缺失时，启动后会自动打开权限页。
    var required = true
    let check: @MainActor () async -> PermissionStatus
    /// 弹出系统授权框。只在 `.notDetermined` 时调用。
    let request: @MainActor () async -> Void
    let openSettings: @MainActor () -> Void
}

enum SystemSettings {
    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    static let locationServices = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    static let automation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    static var notifications: String {
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
    }
}

/// 常用权限的检查与请求。
@MainActor
enum Permissions {
    // MARK: 定位

    private final class LocationRequester: NSObject, CLLocationManagerDelegate {
        let manager = CLLocationManager()
        var continuation: CheckedContinuation<Void, Never>?

        override init() {
            super.init()
            manager.delegate = self
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard manager.authorizationStatus != .notDetermined else { return }
            continuation?.resume()
            continuation = nil
        }
    }

    private static let location = LocationRequester()

    static let locationItem = PermissionItem(
        id: "location", title: "定位服务",
        reason: "macOS 只允许有定位权限的 App 读取 Wi‑Fi 名称。用于显示当前网络和触发自动化，不会获取你的位置。",
        icon: "location.fill", tint: .blue,
        check: {
            switch location.manager.authorizationStatus {
            case .authorizedAlways: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        },
        request: {
            await withCheckedContinuation { c in
                location.continuation = c
                location.manager.requestWhenInUseAuthorization()
            }
        },
        openSettings: { SystemSettings.open(SystemSettings.locationServices) })

    // MARK: 通知

    static let notificationsItem = PermissionItem(
        id: "notifications", title: "通知",
        reason: "显示 Wi‑Fi 切换和自动化的执行结果。",
        icon: "bell.badge.fill", tint: .red,
        check: {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        },
        request: { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
        openSettings: { SystemSettings.open(SystemSettings.notifications) })

    // MARK: 自动化（Apple 事件）

    /// 检查能否向某个 App 发送 Apple 事件。`ask` 为 true 时会弹出系统授权框（阻塞，需在后台调用）。
    nonisolated static func automationStatus(bundleID: String, ask: Bool) -> PermissionStatus {
        var target = AEAddressDesc()
        let created = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notDetermined   // 包括需要询问、目标未运行
        }
    }

    static func automationItem(appName: String, bundleID: String, appPath: String, reason: String) -> PermissionItem {
        func launchTarget() async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config)
        }
        return PermissionItem(
            id: "automation.\(bundleID)", title: "控制“\(appName)”",
            reason: reason, icon: "gearshape.2.fill", tint: .purple,
            check: {
                // 目标 App 未运行时系统无法判断，先在后台启动它。
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { await launchTarget() }
                return await Task.detached { automationStatus(bundleID: bundleID, ask: false) }.value
            },
            request: {
                await launchTarget()
                _ = await Task.detached { automationStatus(bundleID: bundleID, ask: true) }.value
            },
            openSettings: { SystemSettings.open(SystemSettings.automation) })
    }

    // MARK: 登录时启动

    static let loginItem = PermissionItem(
        id: "login", title: "登录时启动",
        reason: "开机后自动运行 QuickUse，自动化才能在你登录后立即生效。",
        icon: "power", tint: .gray, required: false,
        check: {
            switch SMAppService.mainApp.status {
            case .enabled: .granted
            case .notRegistered, .notFound: .notDetermined
            default: .denied   // .requiresApproval：在系统设置里被关掉了
            }
        },
        request: { try? SMAppService.mainApp.register() },
        openSettings: { SMAppService.openSystemSettingsLoginItems() })
}
