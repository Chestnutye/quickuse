import AppKit
import SwiftUI

struct StudyTasksSettingsView: View {
    @ObservedObject var model: StudyTasksModel
    @State private var lists: [StudyTasksModel.ListOption] = []

    var body: some View {
        Form {
            Section("Obsidian 笔记") {
                LabeledContent("文件夹") {
                    HStack {
                        Text(model.settings.vaultPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…", action: chooseFolder)
                    }
                }
                TextField("只扫描文件名包含", text: $model.settings.fileFilter, prompt: Text("留空表示所有 .md 文件"))
                Toggle("只同步带优先级标记（⏫ 🔼 等）的待办", isOn: $model.settings.onlyPrioritized)
            }

            Section("提醒事项") {
                if model.authorization != .granted {
                    HStack {
                        Text("还没有访问“提醒事项”的权限").foregroundStyle(.secondary)
                        Spacer()
                        Button("允许访问…") {
                            Task {
                                await model.requestAccess()
                                lists = model.listOptions()
                            }
                        }
                    }
                } else {
                    Picker("同步到列表", selection: listSelection) {
                        if listSelection.wrappedValue == nil { Text("请选择").tag(String?.none) }
                        ForEach(lists) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
                Toggle("有截止日期的待办，前一天 20:00 提醒", isOn: $model.settings.alarmDayBefore)
            }

            Section("同步") {
                LabeledContent("上次同步") {
                    Text(model.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "还没有")
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Button(model.isSyncing ? "正在同步…" : "立即同步") {
                    Task { await model.syncNow(manual: true) }
                }
                .disabled(model.isSyncing || model.authorization != .granted)
            }

            if !model.log.isEmpty {
                Section("最近记录") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).textSelection(.enabled)
                    }
                }
            }

            Section {
                Text("""
                笔记里的待办用 Obsidian Tasks 插件的格式（例如 `- [ ] 打印 PV 表 ⏫ 📅 2026-10-16`）。\
                只在点“立即同步”时同步：新的未完成待办会加上 🆔 编号并出现在提醒事项里；任意一边打的勾会同步到另一边。\
                在提醒事项里删掉的条目不会再出现；标题、优先级、日期以笔记为准。
                """)
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { lists = model.listOptions() }
    }

    /// 选中的列表：优先按 ID，找不到时按名字匹配（例如换了设备，ID 变了）。
    private var listSelection: Binding<String?> {
        Binding(
            get: {
                if let id = model.settings.listID, lists.contains(where: { $0.id == id }) { return id }
                return lists.first { $0.title == model.settings.listTitle }?.id
            },
            set: { id in
                guard let id, let option = lists.first(where: { $0.id == id }) else { return }
                var s = model.settings
                s.listID = option.id
                s.listTitle = option.title
                model.settings = s
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择存放课程笔记的文件夹（Obsidian 仓库）"
        panel.directoryURL = model.settings.vaultURL
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.vaultPath = (url.path as NSString).abbreviatingWithTildeInPath
    }
}
