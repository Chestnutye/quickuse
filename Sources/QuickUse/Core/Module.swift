import AppKit

/// 一个功能模块。新增功能时实现这个协议，然后在 `ModuleRegistry.makeAll()` 里注册即可。
///
/// 模块可以提供四类东西，都是可选的：
/// - 菜单项：每次打开菜单时调用 `menuItems()` 重新生成，模块之间自动插入分隔线。
/// - 设置页：`settingsPanes()` 返回的页面会出现在设置窗口左侧。
/// - 自动化触发条件：`automationTriggers()`，模块通过 `context.events.post` 发出对应事件。
/// - 自动化动作：`automationActions()`，会出现在规则编辑器的动作列表里。
@MainActor
protocol Module: AnyObject {
    /// 唯一标识，用作数据存储目录名，发布后不要改。
    var id: String { get }

    /// App 启动时调用一次。
    func start(context: ModuleContext)

    /// 菜单即将打开时调用（可在这里做轻量的状态刷新）。
    func menuWillOpen()

    func menuItems() -> [NSMenuItem]
    func settingsPanes() -> [SettingsPane]
    func automationTriggers() -> [TriggerDefinition]
    func automationActions() -> [ActionDefinition]
    /// 本模块需要的系统权限，会出现在设置 → 权限 页。
    func permissions() -> [PermissionItem]
}

extension Module {
    func start(context: ModuleContext) {}
    func menuWillOpen() {}
    func menuItems() -> [NSMenuItem] { [] }
    func settingsPanes() -> [SettingsPane] { [] }
    func automationTriggers() -> [TriggerDefinition] { [] }
    func automationActions() -> [ActionDefinition] { [] }
    func permissions() -> [PermissionItem] { [] }
}

/// 主程序提供给模块的能力。
@MainActor
final class ModuleContext {
    let storage: ModuleStorage
    let events: EventBus
    private let refresh: () -> Void

    init(moduleID: String, events: EventBus, refresh: @escaping () -> Void) {
        self.storage = ModuleStorage(moduleID: moduleID)
        self.events = events
        self.refresh = refresh
    }

    /// 状态变化后调用，让已打开的菜单立即重绘。
    func refreshMenu() { refresh() }

    /// 打开设置窗口，可指定页面 id。
    func openSettings(pane: String? = nil) { AppServices.shared.openSettings(pane: pane) }

    /// 弹出一个提示框。
    func alert(_ title: String, _ message: String = "") { NSAlert.show(title, message) }
}

extension NSAlert {
    /// 把 App 切到前台并弹出一个只有“好”按钮的提示框。
    @MainActor
    static func show(_ title: String, _ message: String = "") {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
