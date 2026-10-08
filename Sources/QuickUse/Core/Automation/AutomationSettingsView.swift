import AppKit
import SwiftUI

struct AutomationSettingsView: View {
    @ObservedObject var store: AutomationStore
    let runNow: (AutomationRule) -> Void
    @State private var editing: AutomationRule?
    @AppStorage(WiFiModule.settleSecondsKey) private var settleSeconds = WiFiModule.defaultSettleSeconds

    var body: some View {
        Form {
            Section {
                if store.rules.isEmpty {
                    Text("还没有规则。例如：连上 eduroam 时，把菜单栏设为始终隐藏并打开 Zotero。")
                        .foregroundStyle(.secondary)
                }
                ForEach($store.rules) { $rule in
                    RuleRow(rule: $rule,
                            onEdit: { editing = rule },
                            onRun: { runNow(rule) },
                            onDelete: { store.rules.removeAll { $0.id == rule.id } })
                }
                Button {
                    editing = AutomationRule(
                        name: "新规则",
                        trigger: .init(kind: AppServices.shared.triggers.first?.id ?? ""),
                        actions: [])
                } label: { Label("新建规则", systemImage: "plus") }
            } header: {
                Text("规则")
            }

            Section {
                Stepper(value: $settleSeconds, in: 2...60) {
                    LabeledContent("网络稳定多久才算连上", value: "\(settleSeconds) 秒")
                }
                Text("网络在这段时间内断开又连回同一个 Wi‑Fi，不算新的连接，不会触发规则。每条规则另有冷却时间，冷却期内不会重复执行。打开 App 时如果它已在运行，会直接跳过。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("防抖")
            }

            Section {
                if store.log.isEmpty {
                    Text("暂无记录").foregroundStyle(.secondary)
                }
                ForEach(store.log.prefix(30)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.level == .done ? "checkmark.circle.fill"
                              : entry.level == .skipped ? "minus.circle" : "xmark.octagon.fill")
                            .foregroundStyle(entry.level == .done ? .green : entry.level == .skipped ? .secondary : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                            Text("\(entry.rule) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("最近执行记录")
                    Spacer()
                    if !store.log.isEmpty { Button("清空") { store.clearLog() }.buttonStyle(.link) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { saved in
                store.upsert(saved)
                store.resetCooldown(saved.id)
                editing = nil
            } onCancel: { editing = nil }
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: AutomationRule
    let onEdit: () -> Void
    let onRun: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).font(.headline)
                Text(Self.describe(rule)).font(.callout).foregroundStyle(.secondary)
                Text(rule.cooldownMinutes > 0 ? "冷却 \(rule.cooldownMinutes) 分钟" : "每次触发都执行")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button("编辑…", action: onEdit)
                Button("立即执行一次", action: onRun)
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    static func describe(_ rule: AutomationRule) -> String {
        let services = AppServices.shared
        let when = services.trigger(rule.trigger.kind)?.summary(rule.trigger.params) ?? "未知触发条件"
        let what = rule.actions.compactMap { services.action($0.kind)?.summary($0.params) }
        return "\(when) → " + (what.isEmpty ? "（没有动作）" : what.joined(separator: "，"))
    }
}

private struct RuleEditor: View {
    @State var rule: AutomationRule
    let onSave: (AutomationRule) -> Void
    let onCancel: () -> Void

    private var triggers: [TriggerDefinition] { AppServices.shared.triggers }
    private var actions: [ActionDefinition] { AppServices.shared.actions }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $rule.name)
                    Toggle("启用", isOn: $rule.enabled)
                }
                Section("当") {
                    Picker("触发条件", selection: $rule.trigger.kind) {
                        ForEach(triggers, id: \.id) { Label($0.title, systemImage: $0.icon).tag($0.id) }
                    }
                    .onChange(of: rule.trigger.kind) { _, _ in rule.trigger.params = [:] }
                    if let def = triggers.first(where: { $0.id == rule.trigger.kind }) {
                        ForEach(def.params, id: \.key) { spec in
                            ParamEditor(spec: spec, value: binding(for: spec.key, in: $rule.trigger))
                        }
                    }
                }
                Section("就依次执行") {
                    if rule.actions.isEmpty {
                        Text("还没有动作").foregroundStyle(.secondary)
                    }
                    ForEach($rule.actions) { $step in
                        if let def = actions.first(where: { $0.id == step.kind }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(def.title, systemImage: def.icon).font(.headline)
                                    Spacer()
                                    Button(role: .destructive) {
                                        rule.actions.removeAll { $0.id == step.id }
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                                ForEach(def.params, id: \.key) { spec in
                                    ParamEditor(spec: spec, value: binding(for: spec.key, in: $step))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Menu {
                        ForEach(actions, id: \.id) { def in
                            Button { rule.actions.append(.init(kind: def.id)) } label: {
                                Label(def.title, systemImage: def.icon)
                            }
                        }
                    } label: { Label("添加动作", systemImage: "plus") }
                        .fixedSize()
                }
                Section("防抖") {
                    Stepper(value: $rule.cooldownMinutes, in: 0...720, step: 5) {
                        LabeledContent("冷却时间",
                                       value: rule.cooldownMinutes == 0 ? "不冷却" : "\(rule.cooldownMinutes) 分钟")
                    }
                    Text("执行过后在冷却时间内再次触发，不会重复执行。保存规则会重置冷却。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty || rule.trigger.kind.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 580)
    }

    private func binding(for key: String, in step: Binding<AutomationRule.Step>) -> Binding<String> {
        Binding(get: { step.wrappedValue.params[key] ?? "" },
                set: { step.wrappedValue.params[key] = $0 })
    }
}

/// 根据 `ParamSpec.Kind` 生成输入控件。
struct ParamEditor: View {
    let spec: ParamSpec
    @Binding var value: String

    var body: some View {
        switch spec.kind {
        case .choice(let options):
            let opts = options()
            Picker(spec.label, selection: $value) {
                if !opts.contains(where: { $0.value == value }) { Text("请选择").tag(value) }
                ForEach(opts, id: \.self) { Text($0.label).tag($0.value) }
            }
        case .suggestions(let placeholder, let suggestions):
            LabeledContent(spec.label) {
                HStack(spacing: 4) {
                    TextField("", text: $value, prompt: Text(placeholder)).labelsHidden()
                    Menu {
                        Button("任意") { value = "" }
                        Divider()
                        ForEach(suggestions(), id: \.self) { s in Button(s) { value = s } }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        case .application:
            LabeledContent(spec.label) {
                HStack {
                    if !value.isEmpty {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: value)).resizable().frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: value))
                    }
                    Button(value.isEmpty ? "选择 App…" : "更换…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { value = url.path }
                    }
                }
            }
        case .text(let placeholder):
            TextField(spec.label, text: $value, prompt: Text(placeholder))
        }
    }
}
