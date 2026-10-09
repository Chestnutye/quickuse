import AppKit
import Combine
import SwiftUI

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var statuses: [String: PermissionStatus] = [:]
    let items: [PermissionItem]

    init(items: [PermissionItem]) { self.items = items }

    func refresh() async {
        var result: [String: PermissionStatus] = [:]
        for item in items {
            var status = await item.check()
            if status == nil, statuses[item.id] == nil, let prepare = item.prepare {
                await prepare()
                status = await item.check()
            }
            result[item.id] = status ?? statuses[item.id] ?? .notDetermined
        }
        if result != statuses { statuses = result }
    }

    var missingRequired: [PermissionItem] {
        items.filter { $0.required && statuses[$0.id] != .granted }
    }

    /// 还没询问过的弹系统授权框，已拒绝的跳到系统设置对应页面。
    func fix(_ item: PermissionItem) async {
        if statuses[item.id] == .notDetermined {
            await item.request()
            await refresh()
            if statuses[item.id] != .granted { item.openSettings() }
        } else {
            item.openSettings()
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(model.items) { item in
                    PermissionRow(item: item, status: model.statuses[item.id]) {
                        Task { await model.fix(item) }
                    }
                }
            } footer: {
                summary
            }
            Section {
                Text("连接“使用系统已保存的密码”的 Wi‑Fi 时，第一次会弹窗询问是否允许 QuickUse 读取这个网络的密码。授权只针对这一条，读到后存进 QuickUse 自己的钥匙串条目，之后不再询问。建议点“允许”而不是“始终允许”。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        // 从系统设置切回来、或页面打开期间，定时刷新状态。
        .onReceive(tick) { _ in Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    @ViewBuilder private var summary: some View {
        let missing = model.missingRequired.count
        if model.statuses.isEmpty {
            EmptyView()
        } else if missing == 0 {
            Label("所有必需权限都已开启", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else {
            Label("还有 \(missing) 项必需权限未开启，相关功能暂时无法使用", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct PermissionRow: View {
    let item: PermissionItem
    let status: PermissionStatus?
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: item.icon, tint: item.tint, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                    if !item.required { Text("可选").font(.caption).foregroundStyle(.secondary) }
                }
                Text(item.reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let status {
                if status == .granted {
                    Label(status.label, systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon).foregroundStyle(.green).font(.callout)
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(status.label).font(.caption).foregroundStyle(status.color)
                        Button(status == .notDetermined ? "允许…" : "打开系统设置", action: fix)
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
