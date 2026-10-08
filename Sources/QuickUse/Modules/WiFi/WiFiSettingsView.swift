import SwiftUI

struct WiFiSettingsView: View {
    @ObservedObject var store: WiFiPresetStore
    let connect: (WiFiPreset) -> Void
    @State private var editing: WiFiPreset?
    @State private var isNew = false
    @State private var editorNote: String?

    var body: some View {
        Form {
            if store.presets.isEmpty {
                Section {
                    Text("还没有预设。添加常用网络，按“家”“学校”等分组，之后在菜单里点一下即可切换。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.groups, id: \.self) { group in
                Section(group) {
                    ForEach(store.presets.filter { $0.group == group }) { preset in
                        PresetRow(preset: preset,
                                  needsAuthorization: preset.security == .system && !preset.hasPassword,
                                  onAuthorize: { authorize(preset) },
                                  onEdit: { isNew = false; editorNote = nil; editing = preset },
                                  onConnect: { connect(preset) },
                                  onDelete: { store.delete(preset) },
                                  onMove: { move(preset, by: $0) })
                    }
                }
            }
            Section {
                Button {
                    isNew = true
                    editorNote = nil
                    editing = WiFiPreset(group: store.groups.first ?? "家", name: "", ssid: "", security: .system)
                } label: { Label("添加预设", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset, isNew: isNew, groups: store.groups, initialNote: editorNote) { saved, password in
                if let password { saved.password = password }
                store.upsert(saved)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    /// 为“使用系统已保存的密码”的预设补做授权。
    /// 个人网络：读取系统密码并缓存。企业网络：不读系统密码，打开编辑框请用户填写一次。
    private func authorize(_ preset: WiFiPreset) {
        Task {
            switch await WiFiService.lookupSaved(ssid: preset.ssid) {
            case .personal(let credential):
                preset.password = credential.password
                store.objectWillChange.send()
            case .enterprise(let username):
                var p = preset
                p.security = .enterprise
                p.username = username
                isNew = false
                editorNote = PresetEditor.enterpriseNote(p.ssid)
                editing = p
            case .unavailable:
                break
            }
        }
    }

    /// 在同组内上下移动。
    private func move(_ preset: WiFiPreset, by offset: Int) {
        let sameGroup = store.presets.indices.filter { store.presets[$0].group == preset.group }
        guard let pos = sameGroup.firstIndex(where: { store.presets[$0].id == preset.id }),
              sameGroup.indices.contains(pos + offset) else { return }
        store.presets.swapAt(sameGroup[pos], sameGroup[pos + offset])
    }
}

private struct PresetRow: View {
    let preset: WiFiPreset
    let needsAuthorization: Bool
    let onAuthorize: () -> Void
    let onEdit: () -> Void
    let onConnect: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: preset.security == .enterprise ? "person.badge.key" : preset.hidden ? "eye.slash" : "wifi")
                .frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if needsAuthorization {
                Button("授权…", action: onAuthorize).controlSize(.small)
                    .help("读取系统为这个网络保存的密码并缓存，之后连接不再询问")
            }
            Button("连接", action: onConnect).controlSize(.small)
            Menu {
                Button("编辑…", action: onEdit)
                Button("上移") { onMove(-1) }
                Button("下移") { onMove(1) }
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var subtitle: String {
        var parts = [preset.ssid, preset.security.label]
        if preset.hidden { parts.append("隐藏网络") }
        if preset.security == .enterprise, let u = preset.username, !u.isEmpty { parts.append(u) }
        return parts.joined(separator: " · ")
    }
}

private struct PresetEditor: View {
    enum Source: String { case saved, manual }

    @State var preset: WiFiPreset
    let isNew: Bool
    let groups: [String]
    var initialNote: String?
    let onSave: (WiFiPreset, String?) -> Void
    let onCancel: () -> Void

    @State private var source: Source = .saved
    @State private var savedNetworks: [String] = []
    @State private var loading = true
    @State private var search = ""
    @State private var password = ""
    @State private var username = ""
    @State private var originalSSID = ""
    @State private var authorizing = false
    /// 读取系统密码被拒绝时，暂存待保存的预设，让用户选择“仍然保存”或“重试”。
    @State private var pendingWithoutPassword: WiFiPreset?
    @State private var note: String?

    static func enterpriseNote(_ ssid: String) -> String {
        "「\(ssid)」是企业网络。系统不允许其他 App 读取它的密码，账号已自动填好，请填写一次密码。"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("来源", selection: $source) {
                        Text("从连过的网络选").tag(Source.saved)
                        Text("手动输入").tag(Source.manual)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: source) { _, new in
                        preset.security = new == .saved ? .system : (preset.security == .system ? .personal : preset.security)
                    }
                }

                if source == .saved {
                    Section {
                        TextField("搜索", text: $search, prompt: Text("搜索 \(savedNetworks.count) 个连过的网络"))
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            List(filtered, id: \.self, selection: Binding(
                                get: { preset.ssid.isEmpty ? nil : preset.ssid },
                                set: { pick($0 ?? "") })) { ssid in
                                Text(ssid).tag(ssid)
                            }
                            .frame(height: 150)
                        }
                        if !preset.ssid.isEmpty {
                            Label("已选择 \(preset.ssid)，使用系统已保存的密码，不用再填", systemImage: "checkmark.seal")
                                .foregroundStyle(.green).font(.callout)
                        }
                    }
                } else {
                    Section {
                        if let note {
                            Label(note, systemImage: "info.circle").foregroundStyle(.blue).font(.callout)
                        }
                        TextField("网络名称（SSID）", text: $preset.ssid)
                        Picker("安全性", selection: $preset.security) {
                            ForEach([WiFiPreset.Security.personal, .enterprise, .open], id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        if preset.security == .enterprise {
                            TextField("用户名", text: $username, prompt: Text("例如 s123456@univ.edu"))
                        }
                        if preset.security == .personal || preset.security == .enterprise {
                            SecureField("密码", text: $password, prompt: Text(isNew ? "" : "留空则不修改"))
                        }
                        Toggle("这是隐藏网络（不广播名称）", isOn: $preset.hidden)
                    }
                }

                Section {
                    LabeledContent("分组") {
                        HStack(spacing: 4) {
                            TextField("", text: $preset.group, prompt: Text("家 / 学校")).labelsHidden()
                            if !groups.isEmpty {
                                Menu {
                                    ForEach(groups, id: \.self) { g in Button(g) { preset.group = g } }
                                } label: { Image(systemName: "chevron.down") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                        }
                    }
                    TextField("名称", text: $preset.name, prompt: Text("例如 日常、实验室"))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if authorizing {
                    ProgressView().controlSize(.small)
                    Text("请在系统弹窗中授权读取这个网络的密码…").font(.callout).foregroundStyle(.secondary)
                } else if let pending = pendingWithoutPassword {
                    Text("没有获得授权。仍然保存的话，第一次连接时会再询问。")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("仍然保存") { onSave(pending, nil) }
                }
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(pendingWithoutPassword != nil ? "重试" : isNew ? "添加" : "保存", action: save)
                    .disabled(authorizing)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset.ssid.trimmingCharacters(in: .whitespaces).isEmpty
                              || (source == .manual && preset.security == .enterprise && password.isEmpty && !preset.hasPassword)
                              || preset.group.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
        .task {
            if preset.security != .system { source = .manual }
            originalSSID = preset.ssid
            note = initialNote
            username = preset.username ?? ""
            savedNetworks = await WiFiService.savedNetworks()
            loading = false
        }
    }

    private var filtered: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? savedNetworks : savedNetworks.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private func pick(_ ssid: String) {
        preset.ssid = ssid
        if preset.name.isEmpty { preset.name = ssid }
    }

    private func save() {
        var p = preset
        p.ssid = p.ssid.trimmingCharacters(in: .whitespaces)
        p.group = p.group.trimmingCharacters(in: .whitespaces)
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = p.ssid }
        if p.security == .system {
            // 保存时就向系统要授权、读出密码并缓存，之后连接不再弹窗。
            // 编辑已有预设且网络没变、已经缓存过密码时不再询问。
            if !isNew && p.ssid == originalSSID && p.hasPassword { onSave(p, nil); return }
            authorizing = true
            pendingWithoutPassword = nil
            Task {
                let lookup = await WiFiService.lookupSaved(ssid: p.ssid)
                authorizing = false
                switch lookup {
                case .personal(let credential):
                    onSave(p, credential.password)
                case .enterprise(let account):
                    // 企业网络改为手动填写：账号已知，只差密码。
                    preset.security = .enterprise
                    username = account ?? ""
                    source = .manual
                    note = Self.enterpriseNote(p.ssid)
                case .unavailable:
                    p.password = nil
                    pendingWithoutPassword = p
                }
            }
            return
        }
        p.username = p.security == .enterprise ? username : nil
        let usesPassword = p.security == .personal || p.security == .enterprise
        if !usesPassword { p.password = nil }
        onSave(p, usesPassword && !password.isEmpty ? password : nil)
    }
}
