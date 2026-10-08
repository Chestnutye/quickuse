import AppKit

/// 提供“打开 App”“退出 App”两个自动化动作。目前没有菜单项。
@MainActor
final class AppLauncherModule: Module {
    let id = "apps"
    /// 连续打开多个 App 时的间隔，避免同时启动抢占资源。
    static let launchSpacing: Duration = .milliseconds(2000)

    func automationActions() -> [ActionDefinition] {
        [
            ActionDefinition(
                id: "app.open", title: "打开 App", icon: "app.badge",
                params: [ParamSpec(key: "path", label: "App", kind: .application)],
                summary: { "打开 \(Self.name($0["path"]))" },
                spacing: Self.launchSpacing,
                run: { params in
                    guard let path = params["path"], !path.isEmpty else { return .failed("没有选择要打开的 App") }
                    let name = Self.name(path)
                    if Self.running(path) != nil { return .skipped("\(name) 已在运行，跳过") }
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    do {
                        try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
                        return .done("已打开 \(name)")
                    } catch {
                        return .failed("打开 \(name) 失败：\(error.localizedDescription)")
                    }
                }),
            ActionDefinition(
                id: "app.quit", title: "退出 App", icon: "xmark.app",
                params: [ParamSpec(key: "path", label: "App", kind: .application)],
                summary: { "退出 \(Self.name($0["path"]))" },
                run: { params in
                    guard let path = params["path"], !path.isEmpty else { return .failed("没有选择要退出的 App") }
                    let name = Self.name(path)
                    guard let app = Self.running(path) else { return .skipped("\(name) 没在运行，跳过") }
                    return app.terminate() ? .done("已退出 \(name)") : .failed("\(name) 拒绝退出")
                }),
        ]
    }

    private static func name(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "（未选择 App）" }
        return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    private static func running(_ path: String) -> NSRunningApplication? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let bundleID = Bundle(url: url)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url || (bundleID != nil && $0.bundleIdentifier == bundleID)
        }
    }
}
