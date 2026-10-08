import AppKit

struct AutomationRule: Codable, Identifiable, Hashable {
    struct Step: Codable, Identifiable, Hashable {
        var id = UUID()
        var kind: String
        var params: [String: String] = [:]
    }

    var id = UUID()
    var name: String
    var enabled = true
    var trigger: Step
    var actions: [Step]
    /// 执行过后多少分钟内不再重复执行。0 表示每次触发都执行。
    var cooldownMinutes = 30
}

struct AutomationLogEntry: Codable, Identifiable, Hashable {
    enum Level: String, Codable { case done, skipped, failed }
    var id = UUID()
    var date: Date
    var rule: String
    var message: String
    var level: Level
}

@MainActor
final class AutomationStore: ObservableObject {
    @Published var rules: [AutomationRule] { didSet { save() } }
    @Published private(set) var log: [AutomationLogEntry]
    private(set) var lastRun: [UUID: Date]
    private let storage: ModuleStorage

    init(storage: ModuleStorage) {
        self.storage = storage
        rules = storage.load([AutomationRule].self, from: "rules") ?? []
        log = storage.load([AutomationLogEntry].self, from: "log") ?? []
        lastRun = storage.load([UUID: Date].self, from: "last-run") ?? [:]
    }

    func upsert(_ rule: AutomationRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
    }

    func markRun(_ id: UUID) {
        lastRun[id] = Date()
        storage.save(lastRun, to: "last-run")
    }

    func resetCooldown(_ id: UUID) {
        lastRun[id] = nil
        storage.save(lastRun, to: "last-run")
    }

    func record(_ rule: String, _ message: String, _ level: AutomationLogEntry.Level) {
        NSLog("[QuickUse] automation %@: %@", rule, message)
        log.insert(AutomationLogEntry(date: Date(), rule: rule, message: message, level: level), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        storage.save(log, to: "log")
    }

    func clearLog() {
        log = []
        storage.save(log, to: "log")
    }

    private func save() { storage.save(rules, to: "rules") }
}

/// 自动化引擎：监听事件总线，命中规则后按顺序执行动作。
///
/// 防抖分两层：
/// 1. 事件来源负责“状态稳定后才发事件”（例如 Wi‑Fi 模块要求网络稳定若干秒，且回到同一网络不算新连接）。
/// 2. 这里按规则做冷却：冷却时间内再次命中只记录、不执行；同一条规则执行中再次命中也会被忽略。
///    动作本身也是幂等的（App 已在运行就不再打开，菜单栏已是目标状态就不再修改）。
@MainActor
final class AutomationModule: Module {
    let id = "automation"
    private var store: AutomationStore!
    private var context: ModuleContext!
    private var running: Set<UUID> = []

    func start(context: ModuleContext) {
        self.context = context
        store = AutomationStore(storage: context.storage)
        context.events.subscribe { [weak self] in self?.handle($0) }
    }

    private func handle(_ event: AppEvent) {
        for rule in store.rules where rule.enabled && rule.trigger.kind == event.kind {
            let matches = rule.trigger.params.allSatisfy { key, value in
                value.isEmpty || event.params[key] == value
            }
            guard matches else { continue }
            guard !running.contains(rule.id) else { continue }
            if rule.cooldownMinutes > 0, let last = store.lastRun[rule.id] {
                let remaining = Double(rule.cooldownMinutes * 60) - Date().timeIntervalSince(last)
                if remaining > 0 {
                    store.record(rule.name, "已触发，但在冷却中（还剩 \(Int(remaining / 60) + 1) 分钟），本次不执行", .skipped)
                    continue
                }
            }
            run(rule)
        }
    }

    func run(_ rule: AutomationRule) {
        running.insert(rule.id)
        store.markRun(rule.id)
        Task { @MainActor in
            defer { running.remove(rule.id) }
            var done: [String] = [], failed: [String] = []
            var lastDone: [String: ContinuousClock.Instant] = [:]
            for step in rule.actions {
                guard let def = AppServices.shared.action(step.kind) else {
                    store.record(rule.name, "未知动作 \(step.kind)", .failed)
                    failed.append("未知动作 \(step.kind)")
                    continue
                }
                if def.spacing > .zero, let last = lastDone[def.id] {
                    let wait = def.spacing - last.duration(to: .now)
                    if wait > .zero { try? await Task.sleep(for: wait) }
                }
                switch await def.run(step.params) {
                case .done(let m):
                    store.record(rule.name, m, .done); done.append(m)
                    lastDone[def.id] = .now
                case .skipped(let m): store.record(rule.name, m, .skipped)
                case .failed(let m): store.record(rule.name, m, .failed); failed.append(m)
                }
            }
            // 全部动作都被跳过（状态本来就满足）时不打扰。
            if !failed.isEmpty {
                Notifier.post(.automation, title: "自动化「\(rule.name)」部分失败",
                              body: (failed + done).joined(separator: "\n"), isError: true)
            } else if !done.isEmpty {
                Notifier.post(.automation, title: "自动化「\(rule.name)」已执行", body: done.joined(separator: "\n"))
            }
        }
    }

    func menuItems() -> [NSMenuItem] {
        guard !store.rules.isEmpty else { return [] }
        let parent = NSMenuItem(title: "自动化", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(.header("点击启用或停用"))
        for rule in store.rules {
            let item = ActionMenuItem(rule.name) { [weak self] in
                guard let self, let i = store.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                store.rules[i].enabled.toggle()
            }
            item.state = rule.enabled ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addItem(ActionMenuItem("管理自动化…") { [weak self] in self?.context.openSettings(pane: "automation") })
        parent.submenu = sub
        let enabled = store.rules.filter(\.enabled).count
        parent.badge = NSMenuItemBadge(string: "\(enabled)/\(store.rules.count)")
        return [parent]
    }

    func settingsPanes() -> [SettingsPane] {
        [SettingsPane(id: "automation", title: "自动化", subtitle: "满足条件时自动执行一组动作，例如连上 eduroam 后打开常用 App。", icon: "bolt.fill", tint: .purple) { [store, weak self] in
            AutomationSettingsView(store: store!) { self?.run($0) }
        }]
    }
}
