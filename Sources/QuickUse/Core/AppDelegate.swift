import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var modules: [Module] = []
    /// 所有模块 start 完成前忽略刷新请求，避免访问尚未初始化的模块。
    private var ready = false
    /// `menuWillOpen` 期间模块请求的刷新先忽略，结束后统一重建一次。
    private var updatingMenu = false

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
        // 开发用：open QuickUse.app --args --settings [页面id] 启动后直接打开设置窗口（例如截图）。
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--settings") {
            let pane = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
            services.openSettings(pane: pane)
        }
        // 安装脚本用：open QuickUse.app --args --enable-login-item 注册为登录时启动。
        if CommandLine.arguments.contains("--enable-login-item") {
            do { try SMAppService.mainApp.register() } catch { NSLog("[QuickUse] 注册登录项失败：%@", "\(error)") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updatingMenu = true
        modules.forEach { $0.menuWillOpen() }
        updatingMenu = false
        rebuild()
        Task {
            let permissions = AppServices.shared.permissions
            let missing = permissions.missingRequired.count
            await permissions.refresh()
            if permissions.missingRequired.count != missing { rebuild() }
        }
    }

    private func rebuild() {
        guard ready, !updatingMenu else { return }
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
