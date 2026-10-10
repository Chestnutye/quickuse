import AppKit
@preconcurrency import EventKit
import SwiftUI

/// 学业待办：把 Obsidian 笔记里的待办（Tasks 插件格式）和“提醒事项”里的一个列表双向同步。
///
/// - 笔记里新加的未完成待办：自动加上 `🆔`，并在提醒事项里创建；标题、优先级、截止日期跟随笔记更新。
/// - 任意一边打勾，同步后另一边跟着打勾。规则见 `StudySyncEngine`。
/// - 只手动同步：菜单或设置里的“立即同步”、自动化动作。不在后台定时运行。
///
/// 发出的自动化事件：
/// - `study.synced`：同步后有变化时发出，无参数。
@MainActor
final class StudyTasksModule: Module {
    let id = "study"
    private var context: ModuleContext!
    private var model: StudyTasksModel!

    func start(context: ModuleContext) {
        self.context = context
        model = StudyTasksModel(storage: context.storage, events: context.events)
        model.onChange = { [weak context] in context?.refreshMenu() }
        model.start()
    }

    func menuWillOpen() { model.menuWillOpen() }

    // MARK: - 菜单

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [.header("学业待办")]
        guard model.authorization == .granted else {
            items.append(ActionMenuItem("允许访问“提醒事项”以同步待办…", image: "checklist") { [model] in
                Task { await model?.requestAccess() }
            })
            return items
        }
        if let error = model.lastError {
            let item = ActionMenuItem(error, image: "exclamationmark.triangle") { [context] in
                context?.openSettings(pane: "study")
            }
            items.append(item)
        }

        // 只显示剩余数量，具体内容在提醒事项或笔记里看。
        let open = model.tasks.filter { !$0.isDone }
        let urgent = open.filter { $0.priority.isHigh }.count
        if open.isEmpty {
            items.append(.note("待办全部完成"))
        } else {
            items.append(.note(urgent > 0 ? "剩余 \(open.count) 项待办，其中高优先级 \(urgent) 项" : "剩余 \(open.count) 项待办"))
        }

        let sync = ActionMenuItem(model.isSyncing ? "正在同步…" : "立即同步", image: "arrow.triangle.2.circlepath") { [model] in
            Task { await model?.syncNow(manual: true) }
        }
        sync.isEnabled = !model.isSyncing
        items.append(sync)
        if let last = model.lastSync {
            items.append(.note("上次同步 \(last.formatted(date: .omitted, time: .shortened))"))
        }
        items.append(ActionMenuItem("打开课程主页", image: "house") { [model] in model?.openHome() })
        return items
    }

    // MARK: - 设置、权限与自动化

    func settingsPanes() -> [SettingsPane] {
        [SettingsPane(id: "study", title: "学业待办", subtitle: "Obsidian 笔记里的待办和“提醒事项”双向同步。",
                      icon: "checklist", tint: .orange) { [model] in
            StudyTasksSettingsView(model: model!)
        }]
    }

    func permissions() -> [PermissionItem] {
        [PermissionItem(
            id: "reminders", title: "提醒事项",
            reason: "把 Obsidian 笔记里的待办同步到“提醒事项”，并把手机上打的勾同步回笔记。",
            icon: "checklist", tint: .orange, required: false,
            check: { StudySyncEngine.authorization },
            request: { [model] in await model?.requestAccess() },
            openSettings: { SystemSettings.open(SystemSettings.reminders) })]
    }

    func automationTriggers() -> [TriggerDefinition] {
        [TriggerDefinition(id: "study.synced", title: "学业待办有更新", icon: "checklist", params: []) { _ in
            "学业待办同步出现变化时"
        }]
    }

    func automationActions() -> [ActionDefinition] {
        [ActionDefinition(
            id: "study.sync", title: "同步学业待办", icon: "arrow.triangle.2.circlepath", params: [],
            summary: { _ in "同步学业待办" },
            run: { [weak self] _ in
                guard let model = self?.model else { return .failed("模块未启动") }
                return await model.syncForAutomation()
            })]
    }
}

extension SystemSettings {
    static let reminders = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
}

/// 学业待办的状态：设置、上次同步结果。只在手动（菜单、设置页）或自动化动作触发时同步，不在后台定时运行。
@MainActor
final class StudyTasksModel: ObservableObject {
    @Published var settings: StudyTasksSettings {
        didSet {
            guard settings != oldValue else { return }
            storage.save(settings, to: "config")
            reloadFromDisk()
        }
    }
    @Published private(set) var authorization: PermissionStatus = .notDetermined
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var tasks: [StudyTask] = []
    @Published private(set) var isSyncing = false

    var onChange: (() -> Void)?

    private let engine: StudySyncEngine
    private let storage: ModuleStorage
    private let events: EventBus
    private var isReloading = false

    init(storage: ModuleStorage, events: EventBus) {
        self.storage = storage
        self.events = events
        settings = storage.load(StudyTasksSettings.self, from: "config") ?? StudyTasksSettings()
        engine = StudySyncEngine(storage: storage)
    }

    func start() {
        refreshAuthorization()
        reloadFromDisk()
    }

    func menuWillOpen() {
        refreshAuthorization()
        reloadFromDisk()
    }

    // MARK: - 权限

    func refreshAuthorization() {
        let status = StudySyncEngine.authorization
        if status != authorization {
            authorization = status
            onChange?()
        }
    }

    func requestAccess() async {
        if StudySyncEngine.authorization == .notDetermined {
            await engine.requestAccess()
        } else if StudySyncEngine.authorization != .granted {
            SystemSettings.open(SystemSettings.reminders)
        }
        refreshAuthorization()
    }

    struct ListOption: Identifiable, Hashable {
        let id: String
        let title: String
    }

    func listOptions() -> [ListOption] {
        engine.reminderLists().map { ListOption(id: $0.calendarIdentifier, title: $0.title) }
    }

    // MARK: - 同步

    /// 同步一次。`manual` 为 true 时（菜单、设置里点的）即使没有变化也给出反馈。正在同步时返回 nil。
    @discardableResult
    func syncNow(manual: Bool = false) async -> StudySyncEngine.Report? {
        refreshAuthorization()
        guard authorization == .granted else {
            setError("没有访问“提醒事项”的权限")
            return nil
        }
        guard !isSyncing else { return nil }
        isSyncing = true
        onChange?()
        var result: StudySyncEngine.Report?
        do {
            let (report, tasks) = try await engine.sync(settings)
            self.tasks = tasks
            lastSync = Date()
            lastError = nil
            if report.hasChanges {
                appendLog(report.summary)
                Notifier.post(.study, title: "学业待办已同步", body: report.summary)
                events.post(AppEvent(kind: "study.synced", params: [:]))
            } else if manual {
                appendLog("已是最新")
            }
            report.warnings.forEach(appendLog)
            result = report
        } catch {
            setError(error.localizedDescription)
            if manual { Notifier.post(.study, title: "学业待办同步失败", body: error.localizedDescription, isError: true) }
        }
        isSyncing = false
        onChange?()
        return result
    }

    func syncForAutomation() async -> ActionOutcome {
        guard let report = await syncNow() else {
            return .failed(lastError ?? "正在同步，稍后会再同步一次")
        }
        return report.hasChanges ? .done("学业待办：\(report.summary)") : .skipped("学业待办没有变化")
    }

    /// 只读笔记、不碰提醒事项，用于打开菜单时刷新数量。在后台扫描，菜单先用上次的结果立即显示，
    /// 扫描完有变化再刷新。
    private func reloadFromDisk() {
        guard !isReloading else { return }
        isReloading = true
        let settings = settings
        Task {
            defer { isReloading = false }
            guard let files = try? await StudySyncEngine.scanInBackground(settings) else { return }
            let fresh = files.flatMap(\.tasks)
            guard fresh != tasks else { return }
            tasks = fresh
            onChange?()
        }
    }

    private func setError(_ message: String) {
        // 定时同步反复失败时只记一次。
        if lastError != message { appendLog("失败：\(message)") }
        lastError = message
        onChange?()
    }

    private func appendLog(_ line: String) {
        let time = Date().formatted(date: .abbreviated, time: .shortened)
        log.insert("\(time)  \(line)", at: 0)
        if log.count > 30 { log.removeLast(log.count - 30) }
    }

    // MARK: - 打开笔记

    func openHome() {
        let home = settings.vaultURL.appendingPathComponent("课程主页.md")
        if FileManager.default.fileExists(atPath: home.path) {
            Self.openInObsidian(home)
        } else {
            NSWorkspace.shared.open(settings.vaultURL)
        }
    }

    /// 用 Obsidian 打开笔记；没装 Obsidian 时用默认程序打开。
    static func openInObsidian(_ file: URL) {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: file.path)]
        if let url = c.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}
