import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var modules: [Module] = []
    /// 所有模块 start 完成前忽略刷新请求，避免访问尚未初始化的模块。
    private var ready = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.toolTip = "QuickUse"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        let services = AppServices.shared
        modules = ModuleRegistry.makeAll()
        services.register(modules)
        for module in modules {
            module.start(context: ModuleContext(moduleID: module.id, events: services.events) { [weak self] in
                self?.rebuild()
            })
        }
        ready = true
        rebuild()
        // 有必需权限没开时，启动后自动打开权限页。
        Task {
            await services.permissions.refresh()
            rebuild()
            if !services.permissions.missingRequired.isEmpty { services.openSettings(pane: "permissions") }
        }
        // 开发用：open QuickUse.app --args --settings 启动后直接打开设置窗口。
        if CommandLine.arguments.contains("--settings") { services.openSettings() }
        // 安装脚本用：open QuickUse.app --args --enable-login-item 注册为登录时启动。
        if CommandLine.arguments.contains("--enable-login-item") {
            do { try SMAppService.mainApp.register() } catch { NSLog("[QuickUse] 注册登录项失败：%@", "\(error)") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        modules.forEach { $0.menuWillOpen() }
        rebuild()
        Task { await AppServices.shared.permissions.refresh(); rebuild() }
    }

    private func rebuild() {
        guard ready else { return }
        menu.removeAllItems()
        let missing = AppServices.shared.permissions.missingRequired.count
        if missing > 0 {
            menu.addItem(ActionMenuItem("有 \(missing) 项权限未开启…", image: "exclamationmark.triangle.fill") {
                AppServices.shared.openSettings(pane: "permissions")
            })
            menu.addItem(.separator())
        }
        for module in modules {
            let items = module.menuItems()
            guard !items.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("设置…", key: ",") { AppServices.shared.openSettings() })
        menu.addItem(ActionMenuItem("退出 QuickUse", key: "q") { NSApp.terminate(nil) })
    }
}
