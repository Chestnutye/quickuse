import AppKit

/// 对应 系统设置 → 控制中心 → “自动隐藏和显示菜单栏”。
///
/// 系统里由两个全局偏好共同决定：
///   始终       _HIHideMenuBar = 1, AppleMenuBarVisibleInFullscreen = 0
///   永不       _HIHideMenuBar = 0, AppleMenuBarVisibleInFullscreen = 1
///   仅在全屏幕 _HIHideMenuBar = 0, AppleMenuBarVisibleInFullscreen = 0
/// System Events 的 `autohide menu bar` 只改第一个值并让系统立即生效，第二个值需要另外写入。
enum MenuBarAutoHide {
    enum Mode: String, CaseIterable {
        case always, never, fullScreenOnly, desktopOnly

        var label: String {
            switch self {
            case .always: "始终"
            case .never: "永不"
            case .fullScreenOnly: "仅在全屏幕时"
            case .desktopOnly: "仅在桌面上"
            }
        }
    }

    private static let hideKey = "_HIHideMenuBar" as CFString
    private static let fullscreenKey = "AppleMenuBarVisibleInFullscreen" as CFString

    static func current() -> Mode {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let hide = bool(hideKey) ?? false
        let visibleInFullscreen = bool(fullscreenKey) ?? false
        switch (hide, visibleInFullscreen) {
        case (true, false): return .always
        case (false, true): return .never
        case (false, false): return .fullScreenOnly
        case (true, true): return .desktopOnly
        }
    }

    static func set(_ mode: Mode) throws {
        let hide = mode == .always || mode == .desktopOnly
        let visibleInFullscreen = mode == .never || mode == .desktopOnly
        CFPreferencesSetAppValue(fullscreenKey, visibleInFullscreen as CFBoolean, kCFPreferencesAnyApplication)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        _ = try Shell.appleScript(
            "tell application \"System Events\" to tell dock preferences to set autohide menu bar to \(hide)")
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"),
            object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func bool(_ key: CFString) -> Bool? {
        let value = CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication)
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}

@MainActor
final class MenuBarAutoHideModule: Module {
    let id = "menubar"
    private var context: ModuleContext!

    func start(context: ModuleContext) { self.context = context }

    func menuItems() -> [NSMenuItem] {
        let current = MenuBarAutoHide.current()
        var items: [NSMenuItem] = [.header("自动隐藏菜单栏")]
        for mode in [MenuBarAutoHide.Mode.always, .never] {
            let item = ActionMenuItem(mode.label) { [weak self] in self?.apply(mode) }
            item.state = current == mode ? .on : .off
            items.append(item)
        }
        if current != .always && current != .never {
            items.append(.note("当前：\(current.label)"))
        }
        return items
    }

    private func apply(_ mode: MenuBarAutoHide.Mode) {
        do {
            try MenuBarAutoHide.set(mode)
        } catch {
            context.alert("无法修改菜单栏设置",
                          "请在 系统设置 → 隐私与安全性 → 自动化 中允许 QuickUse 控制“System Events”。\n\n\(error.localizedDescription)")
        }
    }

    func automationActions() -> [ActionDefinition] {
        let options = [MenuBarAutoHide.Mode.always, .never].map { ParamOption(value: $0.rawValue, label: $0.label) }
        return [
            ActionDefinition(
                id: "menubar.autohide", title: "设置菜单栏自动隐藏", icon: "menubar.rectangle",
                params: [ParamSpec(key: "mode", label: "自动隐藏", kind: .choice { options })],
                summary: { "菜单栏自动隐藏设为\(MenuBarAutoHide.Mode(rawValue: $0["mode"] ?? "")?.label ?? "（未选择）")" },
                run: { params in
                    guard let mode = MenuBarAutoHide.Mode(rawValue: params["mode"] ?? "") else {
                        return .failed("没有选择菜单栏模式")
                    }
                    if MenuBarAutoHide.current() == mode { return .skipped("菜单栏已是“\(mode.label)”，跳过") }
                    do {
                        try MenuBarAutoHide.set(mode)
                        return .done("菜单栏自动隐藏已设为“\(mode.label)”")
                    } catch {
                        return .failed("修改菜单栏失败：\(error.localizedDescription)")
                    }
                }),
        ]
    }
}
