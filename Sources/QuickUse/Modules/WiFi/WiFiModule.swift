import AppKit
import Network

/// Wi‑Fi 预设切换。
///
/// 发出的自动化事件（只在网络稳定 `settleSeconds` 秒后才发，且回到同一网络不算新连接）：
/// - `wifi.connected`    params: ssid
/// - `wifi.disconnected` params: ssid
@MainActor
final class WiFiModule: Module {
    let id = "wifi"
    static let settleSecondsKey = "wifi.settleSeconds"
    static let defaultSettleSeconds = 8

    private var context: ModuleContext!
    private(set) var store: WiFiPresetStore!
    private let location = LocationPermission()
    private let monitor = WiFiEventMonitor()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var settleTimer: Timer?

    /// 系统当前报告的 SSID（可能在抖动）。
    private var currentSSID: String?
    /// 最近一次“稳定”的 SSID，用来判断是否真的换了网络。
    private var stableSSID: String?
    private var hasSettledOnce = false
    private var connectingID: UUID?

    private var settleSeconds: TimeInterval {
        let v = UserDefaults.standard.integer(forKey: Self.settleSecondsKey)
        return TimeInterval(v > 0 ? v : Self.defaultSettleSeconds)
    }

    func start(context: ModuleContext) {
        self.context = context
        store = WiFiPresetStore(storage: context.storage)
        location.onChange = { [weak self] in self?.check(force: true) }
        monitor.onChange = { [weak self] in self?.check() }
        monitor.start()
        // 不做定时轮询：读取 Wi‑Fi 名称在系统看来就是“使用定位”。
        // 只在网络确实变化（Wi‑Fi 事件或网络路径变化，后者不需要定位）以及打开菜单时读取。
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.check() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        check(force: true)
    }

    func menuWillOpen() { check() }

    // MARK: - 状态与防抖

    private func check(force: Bool = false) {
        let ssid = WiFiService.currentSSID()
        guard force || ssid != currentSSID else { return }
        currentSSID = ssid
        context.refreshMenu()
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
    }

    private func settle() {
        let ssid = WiFiService.currentSSID()
        currentSSID = ssid
        guard !hasSettledOnce || ssid != stableSSID else { return }
        let previous = stableSSID
        stableSSID = ssid
        hasSettledOnce = true
        if let previous { context.events.post(AppEvent(kind: "wifi.disconnected", params: ["ssid": previous])) }
        if let ssid { context.events.post(AppEvent(kind: "wifi.connected", params: ["ssid": ssid])) }
    }

    // MARK: - 连接

    func connect(_ preset: WiFiPreset) {
        guard connectingID == nil else { return }
        if preset.ssid == currentSSID {
            Notifier.post(.wifi, title: "已经连接在 \(preset.displayName)", body: preset.ssid)
            return
        }
        connectingID = preset.id
        context.refreshMenu()

        // “使用系统已保存的密码”的预设也可能已缓存了从系统钥匙串读到的凭据。
        let password: String? = preset.security == .open ? nil : preset.password
        let username = preset.security == .enterprise || preset.security == .system ? preset.username : nil
        Task { @MainActor in
            do {
                if let learned = try await WiFiService.connect(ssid: preset.ssid, security: preset.security,
                                                               username: username, password: password) {
                    preset.password = learned.password
                    if let u = learned.username, var p = store.presets.first(where: { $0.id == preset.id }) {
                        p.username = u
                        store.upsert(p)
                    }
                }
                Notifier.post(.wifi, title: "已连接到 \(preset.displayName)", body: preset.ssid)
            } catch let error as WiFiService.ConnectError {
                Notifier.post(.wifi, title: error.title, body: error.detail, isError: true)
            } catch {
                Notifier.post(.wifi, title: "连接「\(preset.ssid)」失败", body: error.localizedDescription, isError: true)
            }
            connectingID = nil
            check(force: true)
        }
    }

    // MARK: - 菜单

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [statusItem()]

        for group in store.groups {
            items.append(.header(group))
            for preset in store.presets where preset.group == group {
                items.append(presetItem(preset))
            }
        }
        if store.presets.isEmpty {
            items.append(.note("还没有 Wi‑Fi 预设"))
        }
        items.append(ActionMenuItem(store.presets.isEmpty ? "添加 Wi‑Fi 预设…" : "管理 Wi‑Fi 预设…") { [weak self] in
            self?.context.openSettings(pane: "wifi")
        })
        return items
    }

    private func statusItem() -> NSMenuItem {
        if !location.isAuthorized {
            let item = ActionMenuItem("允许定位权限以读取 Wi‑Fi 名称…", image: "location.slash") { [weak self] in
                guard let self else { return }
                location.isUndetermined ? location.request() : location.openSystemSettings()
            }
            return item
        }
        let title: String
        if let id = connectingID, let p = store.presets.first(where: { $0.id == id }) {
            title = "正在连接 \(p.displayName)…"
        } else if let ssid = currentSSID {
            title = store.preset(forSSID: ssid).map { "\($0.displayName)（\(ssid)）" } ?? ssid
        } else if !WiFiService.isPoweredOn {
            title = "Wi‑Fi 已关闭"
        } else {
            title = "未连接 Wi‑Fi"
        }
        let item = NSMenuItem.note(title)
        item.image = NSImage(systemSymbolName: currentSSID == nil ? "wifi.slash" : "wifi",
                             accessibilityDescription: nil)
        return item
    }

    private func presetItem(_ preset: WiFiPreset) -> NSMenuItem {
        let item = ActionMenuItem(preset.name) { [weak self] in self?.connect(preset) }
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: preset.name, attributes: [.font: font])
        title.append(NSAttributedString(string: "  \(preset.ssid)", attributes: [
            .font: NSFont.menuFont(ofSize: font.pointSize - 2),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title
        item.state = preset.ssid == currentSSID ? .on : .off
        item.isEnabled = connectingID == nil
        if connectingID == preset.id {
            item.badge = NSMenuItemBadge(string: "连接中…")
        } else if preset.security == .enterprise {
            item.badge = NSMenuItemBadge(string: "企业")
        } else if preset.hidden {
            item.badge = NSMenuItemBadge(string: "隐藏")
        }
        return item
    }

    // MARK: - 设置与自动化

    func permissions() -> [PermissionItem] { [Permissions.locationItem] }

    func settingsPanes() -> [SettingsPane] {
        [SettingsPane(id: "wifi", title: "Wi‑Fi 预设", subtitle: "按分组管理常用网络，在菜单里点一下即可切换。", icon: "wifi", tint: .blue) { [store, weak self] in
            WiFiSettingsView(store: store!) { self?.connect($0) }
        }]
    }

    private var ssidSuggestions: () -> [String] {
        { [weak self] in
            guard let self else { return [] }
            var seen = Set<String>()
            return (store.presets.map(\.ssid) + [currentSSID].compactMap { $0 }).filter { seen.insert($0).inserted }
        }
    }

    func automationTriggers() -> [TriggerDefinition] {
        let ssid = ParamSpec(key: "ssid", label: "Wi‑Fi 名称", kind: .suggestions(placeholder: "留空表示任意网络", ssidSuggestions))
        return [
            TriggerDefinition(id: "wifi.connected", title: "连上 Wi‑Fi", icon: "wifi", params: [ssid]) {
                let s = $0["ssid"] ?? ""
                return s.isEmpty ? "连上任意 Wi‑Fi 时" : "连上 \(s) 时"
            },
            TriggerDefinition(id: "wifi.disconnected", title: "断开 Wi‑Fi", icon: "wifi.slash", params: [ssid]) {
                let s = $0["ssid"] ?? ""
                return s.isEmpty ? "断开任意 Wi‑Fi 时" : "离开 \(s) 时"
            },
        ]
    }

    func automationActions() -> [ActionDefinition] {
        let presets: () -> [ParamOption] = { [weak self] in
            self?.store.presets.map { ParamOption(value: $0.id.uuidString, label: "\($0.displayName)（\($0.ssid)）") } ?? []
        }
        return [
            ActionDefinition(
                id: "wifi.connect", title: "切换到 Wi‑Fi 预设", icon: "wifi",
                params: [ParamSpec(key: "preset", label: "预设", kind: .choice(presets))],
                summary: { [weak self] params in
                    let p = self?.store.presets.first { $0.id.uuidString == params["preset"] }
                    return "切换到 \(p?.displayName ?? "（未选择）")"
                },
                run: { [weak self] params in
                    guard let self, let p = store.presets.first(where: { $0.id.uuidString == params["preset"] }) else {
                        return .failed("预设不存在")
                    }
                    if p.ssid == currentSSID { return .skipped("已经连接在 \(p.displayName)") }
                    connect(p)
                    return .done("开始切换到 \(p.displayName)")
                }),
        ]
    }
}
