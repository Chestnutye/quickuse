/// 所有启用的模块，按菜单中从上到下的顺序排列。新增模块加在这里。
@MainActor
enum ModuleRegistry {
    static func makeAll() -> [Module] {
        [
            WiFiModule(),
            MenuBarAutoHideModule(),
            StudyTasksModule(),
            AppLauncherModule(),
            AutomationModule(),
        ]
    }
}
