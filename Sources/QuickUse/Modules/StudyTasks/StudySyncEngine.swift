@preconcurrency import EventKit
import Foundation

/// 学业待办的设置，保存在模块存储的 config.json。
struct StudyTasksSettings: Codable, Equatable {
    /// Obsidian 仓库（或其中任意文件夹）的路径，可以用 `~`。
    var vaultPath = "~/Documents/Obsidian"
    /// 同步到的“提醒事项”列表。`listID` 找不到时按 `listTitle` 找。
    var listID: String?
    var listTitle = "课程待办"
    /// 只扫描文件名包含这段文字的 .md 文件；留空表示所有 .md 文件。
    var fileFilter = "笔记_中文"
    /// 只同步带优先级标记（⏫ 🔼 等）的待办。
    var onlyPrioritized = false
    /// 有截止日期的待办，在前一天 20:00 提醒。
    var alarmDayBefore = true

    var vaultURL: URL { URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath) }

    init() {}

    /// 逐个字段解码，缺字段时用默认值，以后加字段不会让旧配置文件解析失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudyTasksSettings()
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? d.vaultPath
        listID = try c.decodeIfPresent(String.self, forKey: .listID)
        listTitle = try c.decodeIfPresent(String.self, forKey: .listTitle) ?? d.listTitle
        fileFilter = try c.decodeIfPresent(String.self, forKey: .fileFilter) ?? d.fileFilter
        onlyPrioritized = try c.decodeIfPresent(Bool.self, forKey: .onlyPrioritized) ?? d.onlyPrioritized
        alarmDayBefore = try c.decodeIfPresent(Bool.self, forKey: .alarmDayBefore) ?? d.alarmDayBefore
    }
}

/// 一个笔记文件和其中的待办。`lines` 在同步过程中被改写，`original` 用来判断写回前文件是否被别人改过。
struct StudyFile {
    let url: URL
    let original: String
    var lines: [String]
    let tasks: [StudyTask]
}

/// 笔记与“提醒事项”之间的双向同步。
///
/// 每条待办用 `🆔` 字段和提醒备注里的 `ID:` 对应。上次同步后双方的勾选状态记在 state.json 里，
/// 用来判断这次是哪一边改了：
/// - 只有一边变了：以变的一边为准。
/// - 两边都变了且不一致：以“完成”为准。
/// - 第一次配对、双方不一致：以“完成”为准。
/// - 笔记里改了标题、优先级或日期：更新提醒。提醒里改了这些不会写回笔记。
/// - 在提醒事项里删掉的提醒不会重建；笔记里删掉的待办，对应提醒保持原样。
@MainActor
final class StudySyncEngine {
    struct ItemState: Codable, Equatable {
        var noteDone: Bool
        var reminderDone: Bool
        var reminderID: String?
        var meta: String
    }

    struct State: Codable, Equatable {
        var items: [String: ItemState] = [:]
    }

    struct Report {
        var created = 0
        /// 笔记 → 提醒事项 的勾选变化，分“完成”和“取消完成”。
        var pushedDone = 0
        var pushedUndone = 0
        /// 提醒事项 → 笔记 的勾选变化，分“完成”和“取消完成”。
        var pulledDone = 0
        var pulledUndone = 0
        var updated = 0
        var assignedIDs = 0
        var warnings: [String] = []

        var hasChanges: Bool { created + pushedDone + pushedUndone + pulledDone + pulledUndone + updated > 0 }

        var summary: String {
            var parts: [String] = []
            if pulledDone > 0 { parts.append("提醒事项里完成 \(pulledDone) 条，已在笔记打勾") }
            if pulledUndone > 0 { parts.append("提醒事项里取消完成 \(pulledUndone) 条，已在笔记取消勾选") }
            if pushedDone > 0 { parts.append("笔记里完成 \(pushedDone) 条，已在提醒事项打勾") }
            if pushedUndone > 0 { parts.append("笔记里取消完成 \(pushedUndone) 条，已在提醒事项取消勾选") }
            if created > 0 { parts.append("笔记里新增待办 \(created) 条，已加到提醒事项") }
            if updated > 0 { parts.append("笔记里修改了 \(updated) 条，已更新提醒") }
            return parts.isEmpty ? "没有变化" : parts.joined(separator: "；")
        }
    }

    enum SyncError: LocalizedError {
        case notAuthorized
        case vaultMissing(String)
        case listMissing(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "没有访问“提醒事项”的权限"
            case .vaultMissing(let path): "找不到笔记文件夹：\(path)"
            case .listMissing(let title): "找不到提醒事项列表“\(title)”，请在设置里重新选择"
            }
        }
    }

    let eventStore = EKEventStore()
    private let storage: ModuleStorage
    private var state: State

    init(storage: ModuleStorage) {
        self.storage = storage
        state = storage.load(State.self, from: "state") ?? State()
    }

    // MARK: - 权限与列表

    static var authorization: PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied   // 拒绝、受限、只写
        }
    }

    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToReminders()
        // 授权后要重置一次，否则这个实例看不到列表。
        eventStore.reset()
    }

    func reminderLists() -> [EKCalendar] {
        eventStore.calendars(for: .reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func calendar(for settings: StudyTasksSettings) -> EKCalendar? {
        if let id = settings.listID, let c = eventStore.calendar(withIdentifier: id) { return c }
        return eventStore.calendars(for: .reminder).first { $0.title == settings.listTitle }
    }

    // MARK: - 扫描笔记

    /// 读出文件夹里所有符合条件的笔记和其中的待办，不访问“提醒事项”。
    /// 不依赖主线程，调用方用 `scanInBackground` 放到后台做，避免卡住菜单和界面。
    nonisolated static func scan(_ settings: StudyTasksSettings) throws -> [StudyFile] {
        let root = settings.vaultURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.vaultMissing(root.path)
        }
        let filter = settings.fileFilter.trimmingCharacters(in: .whitespaces)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [StudyFile] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            guard url.pathExtension.lowercased() == "md", filter.isEmpty || name.contains(filter),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            files.append(StudyFile(url: url, original: text, lines: lines,
                                   tasks: StudyTaskParser.parse(lines: lines, file: url)))
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// 在后台线程扫描。学期末笔记多时一次扫描约 40 ms，放在主线程会让菜单打开变慢。
    nonisolated static func scanInBackground(_ settings: StudyTasksSettings) async throws -> [StudyFile] {
        try await Task.detached(priority: .utility) { try scan(settings) }.value
    }

    // MARK: - 同步

    /// 同步一次，返回结果和同步后的全部待办。
    func sync(_ settings: StudyTasksSettings) async throws -> (Report, [StudyTask]) {
        guard Self.authorization == .granted else { throw SyncError.notAuthorized }
        guard let calendar = calendar(for: settings) else { throw SyncError.listMissing(settings.listTitle) }
        var report = Report()

        // 第一步：给新待办分配 ID 并先写回文件。
        // 先落盘再建提醒：如果写文件失败，下次不会又分配一个新 ID、重复建提醒。
        var files = try await Self.scanInBackground(settings)
        var wroteIDs = false
        for f in files.indices {
            var count = 0
            for task in files[f].tasks where task.id == nil && !task.isDone {
                if settings.onlyPrioritized && task.priority == .none { continue }
                let id = StudyTaskParser.newID(course: task.course, week: task.week)
                files[f].lines[task.line] = StudyTaskParser.addID(files[f].lines[task.line], id)
                count += 1
            }
            if count > 0, write(files[f], report: &report) {
                wroteIDs = true
                report.assignedIDs += count
            }
        }
        if wroteIDs { files = try await Self.scanInBackground(settings) }

        // 第二步：和提醒事项逐条对账。
        let reminders = await fetchReminders(in: calendar)
        var byID: [String: EKReminder] = [:]
        var byItemID: [String: EKReminder] = [:]
        for reminder in reminders {
            byItemID[reminder.calendarItemIdentifier] = reminder
            if let id = StudyTaskParser.id(inNotes: reminder.notes), byID[id] == nil { byID[id] = reminder }
        }

        var seen = Set<String>()
        var needsCommit = false
        /// 只有对应文件成功写回（或不需要写）后才更新这些状态，否则下次重新对账。
        var newStates: [URL: [String: ItemState]] = [:]

        for f in files.indices {
            let url = files[f].url
            for task in files[f].tasks {
                guard let id = task.id else { continue }
                guard seen.insert(id).inserted else {
                    report.warnings.append("ID \(id) 出现了不止一次，只同步第一处")
                    continue
                }
                let previous = state.items[id]
                var noteDone = task.isDone
                let meta = task.metaSignature

                if let reminder = byID[id] ?? previous?.reminderID.flatMap({ byItemID[$0] }) {
                    var target: Bool?
                    if noteDone != reminder.isCompleted {
                        if let previous {
                            let noteChanged = noteDone != previous.noteDone
                            let reminderChanged = reminder.isCompleted != previous.reminderDone
                            if noteChanged && !reminderChanged {
                                target = noteDone
                            } else if reminderChanged && !noteChanged {
                                target = reminder.isCompleted
                            } else {
                                target = true
                            }
                        } else {
                            target = true
                        }
                    }
                    var changed = false
                    if let target {
                        if reminder.isCompleted != target {
                            reminder.isCompleted = target
                            changed = true
                            if target { report.pushedDone += 1 } else { report.pushedUndone += 1 }
                        }
                        if noteDone != target {
                            files[f].lines[task.line] = StudyTaskParser.setDone(files[f].lines[task.line], target)
                            noteDone = target
                            if target { report.pulledDone += 1 } else { report.pulledUndone += 1 }
                        }
                    }
                    if let previous, previous.meta != meta {
                        apply(task, id: id, to: reminder, settings: settings)
                        changed = true
                        report.updated += 1
                    }
                    if changed {
                        do {
                            try eventStore.save(reminder, commit: false)
                            needsCommit = true
                        } catch {
                            // 保存失败时撤销内存里的修改，并保留上次的状态：否则下次会把这次没存上的值
                            // 当成“提醒事项里改过”，反过来覆盖笔记。
                            reminder.rollback()
                            report.warnings.append("更新提醒“\(task.title)”失败：\(error.localizedDescription)")
                            if let previous { newStates[url, default: [:]][id] = previous }
                            continue
                        }
                    }
                    newStates[url, default: [:]][id] = ItemState(
                        noteDone: noteDone, reminderDone: reminder.isCompleted,
                        reminderID: reminder.calendarItemIdentifier, meta: meta)
                } else if var deleted = previous, deleted.reminderID != nil {
                    // 用户在提醒事项里删掉了这条：尊重删除，不重建。
                    deleted.noteDone = noteDone
                    deleted.meta = meta
                    newStates[url, default: [:]][id] = deleted
                } else if !noteDone {
                    if settings.onlyPrioritized && task.priority == .none { continue }
                    let reminder = EKReminder(eventStore: eventStore)
                    reminder.calendar = calendar
                    apply(task, id: id, to: reminder, settings: settings)
                    do {
                        try eventStore.save(reminder, commit: false)
                        needsCommit = true
                        report.created += 1
                        newStates[url, default: [:]][id] = ItemState(
                            noteDone: false, reminderDone: false,
                            reminderID: reminder.calendarItemIdentifier, meta: meta)
                    } catch {
                        report.warnings.append("新建提醒“\(task.title)”失败：\(error.localizedDescription)")
                    }
                }
            }
        }
        if needsCommit {
            do {
                try eventStore.commit()
            } catch {
                // 丢掉没提交的修改，文件和状态都不动，下次从头对账。
                eventStore.reset()
                throw error
            }
        }

        let oldState = state
        var finalTasks: [StudyTask] = []
        for file in files {
            if write(file, report: &report) {
                for (id, s) in newStates[file.url] ?? [:] { state.items[id] = s }
            }
            finalTasks += StudyTaskParser.parse(lines: file.lines, file: file.url)
        }
        // 没变化时不写。
        if state != oldState { storage.save(state, to: "state") }
        return (report, finalTasks)
    }

    // MARK: - 工具

    /// 把笔记里的标题、说明、优先级、截止日期写进提醒。备注最后一行固定是 `ID: …`，用来对应。
    private func apply(_ task: StudyTask, id: String, to reminder: EKReminder, settings: StudyTasksSettings) {
        reminder.title = task.reminderTitle
        let source = task.file.deletingPathExtension().lastPathComponent
        reminder.notes = (task.detail.isEmpty ? "" : task.detail + "\n") + "ID: \(id) · \(source)"
        reminder.priority = task.priority.reminderValue
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if var due = task.due {
            due.calendar = Calendar.current
            reminder.dueDateComponents = due
            if settings.alarmDayBefore,
               let day = Calendar.current.date(from: due),
               let alarm = Calendar.current.date(byAdding: DateComponents(day: -1, hour: 20), to: day) {
                reminder.addAlarm(EKAlarm(absoluteDate: alarm))
            }
        } else {
            reminder.dueDateComponents = nil
        }
    }

    /// 写回文件。写之前确认文件在同步期间没被改过（例如正在 Obsidian 里编辑），改过就跳过，下次再处理。
    private func write(_ file: StudyFile, report: inout Report) -> Bool {
        let text = file.lines.joined(separator: "\n")
        guard text != file.original else { return true }
        guard let current = try? String(contentsOf: file.url, encoding: .utf8), current == file.original else {
            report.warnings.append("「\(file.url.lastPathComponent)」在同步时被修改，已跳过，稍后自动重试")
            return false
        }
        do {
            try text.write(to: file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            report.warnings.append("写入「\(file.url.lastPathComponent)」失败：\(error.localizedDescription)")
            return false
        }
    }

    private func fetchReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }
}
