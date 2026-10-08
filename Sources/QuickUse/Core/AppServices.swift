import AppKit

/// 全局共享的服务：事件总线、模块列表、设置窗口。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let events = EventBus()
    private(set) var modules: [Module] = []
    private lazy var settingsWindow = SettingsWindowController()

    func register(_ modules: [Module]) { self.modules = modules }

    var triggers: [TriggerDefinition] { modules.flatMap { $0.automationTriggers() } }
    var actions: [ActionDefinition] { modules.flatMap { $0.automationActions() } }
    var settingsPanes: [SettingsPane] {
        modules.flatMap { $0.settingsPanes() } + [permissionsPane, GeneralSettings.pane]
    }

    /// 所有模块声明的权限，加上通用的通知和登录项。
    private(set) lazy var permissions = PermissionsModel(
        items: modules.flatMap { $0.permissions() } + [Permissions.notificationsItem, Permissions.loginItem])

    private var permissionsPane: SettingsPane {
        SettingsPane(id: "permissions", title: "权限", subtitle: "QuickUse 需要的系统权限。点按钮会弹出授权框，或直接跳到系统设置对应的位置。",
                     icon: "hand.raised.fill", tint: .orange) { [permissions] in
            PermissionsView(model: permissions)
        }
    }

    func trigger(_ id: String) -> TriggerDefinition? { triggers.first { $0.id == id } }
    func action(_ id: String) -> ActionDefinition? { actions.first { $0.id == id } }

    func openSettings(pane: String? = nil) { settingsWindow.show(pane: pane) }
}

/// 模块之间、模块与自动化之间通信用的事件。
struct AppEvent {
    let kind: String
    let params: [String: String]
}

@MainActor
final class EventBus {
    private var handlers: [(AppEvent) -> Void] = []

    func subscribe(_ handler: @escaping (AppEvent) -> Void) { handlers.append(handler) }

    func post(_ event: AppEvent) {
        NSLog("[QuickUse] event %@ %@", event.kind, event.params.description)
        handlers.forEach { $0(event) }
    }
}
