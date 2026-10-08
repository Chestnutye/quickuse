import AppKit
import ServiceManagement
import SwiftUI

enum GeneralSettings {
    static let pane = SettingsPane(id: "general", title: "通用", subtitle: "启动、通知和数据位置。", icon: "gearshape.fill", tint: .gray) { GeneralSettingsView() }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("登录时自动启动 QuickUse", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            Section("通知") {
                ForEach(Notifier.Category.allCases, id: \.self) { category in
                    NotifyToggle(category: category)
                }
                Button("打开系统通知设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Section("数据") {
                LabeledContent("预设和规则保存在") {
                    Button("在访达中显示") {
                        let url = ModuleStorage(moduleID: "").directory
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Text("密码保存在“钥匙串访问”中，名称以 QuickUse 开头。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotifyToggle: View {
    let category: Notifier.Category
    @AppStorage private var on: Bool

    init(category: Notifier.Category) {
        self.category = category
        _on = AppStorage(wrappedValue: true, category.rawValue)
    }

    var body: some View { Toggle(category.title, isOn: $on) }
}
