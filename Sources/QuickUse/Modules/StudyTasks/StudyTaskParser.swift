import Foundation

/// Obsidian 笔记里的一条待办（Tasks 插件格式）。
///
/// 支持的行格式，字段都在行尾、顺序不限：
///
///     - [ ] **标题**：说明 ⏫ 📅 2026-10-16 🆔 FoF-W1-24
///     - [x] **标题** 🆔 FoF-W1-24 ✅ 2026-10-12
struct StudyTask: Equatable {
    enum Priority: String, Codable {
        case highest, high, medium, none, low, lowest

        /// “提醒事项”的优先级：1 高、5 中、9 低、0 无。
        var reminderValue: Int {
            switch self {
            case .highest, .high: 1
            case .medium: 5
            case .low, .lowest: 9
            case .none: 0
            }
        }

        var isHigh: Bool { self == .highest || self == .high }
    }

    let file: URL
    /// 在文件中的行号，从 0 开始。
    let line: Int
    let isDone: Bool
    let id: String?
    /// 课程简称，取自文件名开头，例如 `FoF-Week1-笔记_中文.md` → FoF。
    let course: String?
    let week: Int?
    let title: String
    let detail: String
    let priority: Priority
    /// 截止日期，只有年月日。
    let due: DateComponents?

    /// 在“提醒事项”里显示的标题。
    var reminderTitle: String { course.map { "[\($0)] \(title)" } ?? title }

    /// 标题、说明、优先级、日期合成的签名，用来判断笔记里的内容是否改过。
    var metaSignature: String {
        let d = due.map { String(format: "%04d-%02d-%02d", $0.year ?? 0, $0.month ?? 0, $0.day ?? 0) } ?? ""
        return [title, detail, priority.rawValue, d].joined(separator: "\u{1F}")
    }
}

/// 纯文本的解析与改写，不碰文件和“提醒事项”，便于测试。
enum StudyTaskParser {
    // MARK: - 解析

    /// 解析一个文件的全部待办。代码块里的内容会被忽略。
    static func parse(lines: [String], file: URL) -> [StudyTask] {
        let name = match(fileName, in: file.lastPathComponent)
        let course = name?[1]
        let week = name.flatMap { Int($0[2]) }
        var tasks: [StudyTask] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence, let m = match(taskLine, in: line) else { continue }
            let body = m[3].replacingOccurrences(of: "\u{FE0F}", with: "")
            let description = replacing(anyField, in: body, with: "")
            let (title, detail) = split(description)
            guard !title.isEmpty else { continue }
            tasks.append(StudyTask(
                file: file, line: index, isDone: m[2] != " ",
                id: match(idField, in: body)?[1],
                course: course, week: week, title: title, detail: detail,
                priority: priority(in: body),
                due: match(dueField, in: body).map { DateComponents(year: Int($0[1]), month: Int($0[2]), day: Int($0[3])) }))
        }
        return tasks
    }

    static func priority(in body: String) -> StudyTask.Priority {
        if body.contains("🔺") { return .highest }
        if body.contains("⏫") { return .high }
        if body.contains("🔼") { return .medium }
        if body.contains("🔽") { return .low }
        if body.contains("⏬") { return .lowest }
        return .none
    }

    /// 拆出标题和说明。以 `**加粗**` 开头时，加粗部分是标题、其余是说明；否则整句是标题，过长时截断。
    static func split(_ description: String) -> (title: String, detail: String) {
        let text = description.trimmingCharacters(in: .whitespaces)
        var title = text
        var detail = ""
        if text.hasPrefix("**"),
           let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            title = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
            detail = String(text[close.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,；; ").union(.whitespaces))
        }
        title = clean(title)
        detail = clean(detail)
        if title.count > 40 {
            detail = detail.isEmpty ? title : "\(title)\n\(detail)"
            title = String(title.prefix(40)) + "…"
        }
        return (title, detail)
    }

    /// 去掉 Markdown 标记，只留文字。
    static func clean(_ s: String) -> String {
        var t = replacing(wikiLinkAlias, in: s, with: "$2")
        t = replacing(wikiLink, in: t, with: "$1")
        t = replacing(markdownLink, in: t, with: "$1")
        // 不去掉单个下划线：文件名、术语里常有（例如 笔记_中文）。
        for token in ["**", "__", "*", "`"] { t = t.replacingOccurrences(of: token, with: "") }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 从“提醒事项”的备注里读出 ID（`ID: FoF-W1-24`）。
    static func id(inNotes notes: String?) -> String? {
        notes.flatMap { match(noteID, in: $0)?[1] }
    }

    // MARK: - 改写

    /// 改勾选状态。完成时补上 `✅ 日期`（和 Tasks 插件一致），取消完成时去掉。
    static func setDone(_ line: String, _ done: Bool, on date: Date = Date()) -> String {
        guard let m = match(taskLine, in: line) else { return line }
        var body = replacing(doneField, in: m[3], with: "").trimmingTrailingWhitespace()
        if done { body += " ✅ " + dayFormatter.string(from: date) }
        return m[1] + (done ? "[x] " : "[ ] ") + body
    }

    /// 在行尾加上 `🆔 id`。
    static func addID(_ line: String, _ id: String) -> String {
        line.trimmingTrailingWhitespace() + " 🆔 " + id
    }

    /// 生成新的 ID，例如 `FoF-W2-k7m3p`。只用 Tasks 插件允许的字符。
    static func newID(course: String?, week: Int?) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let suffix = String((0..<5).map { _ in chars.randomElement()! })
        return "\(course ?? "T")-W\(week ?? 0)-\(suffix)"
    }

    // MARK: - 正则

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// 1 缩进和列表符号，2 勾选状态，3 正文。
    private static let taskLine = regex(#"^(\s*[-*+]\s+)\[([ xX])\]\s+(.*)$"#)
    private static let idField = regex(#"🆔\s*([A-Za-z0-9_\-]+)"#)
    private static let dueField = regex(#"📅\s*(\d{4})-(\d{2})-(\d{2})"#)
    private static let doneField = regex(#"\s*✅\s*\d{4}-\d{2}-\d{2}"#)
    /// 所有 Tasks 字段，从正文里去掉后得到纯描述。
    private static let anyField = regex(
        #"\s*(?:🆔\s*[A-Za-z0-9_\-]+|(?:📅|⏳|🛫|✅|➕|❌)\s*\d{4}-\d{2}-\d{2}|⛔\s*[A-Za-z0-9_,\-]+|⏫|🔼|🔽|⏬|🔺)"#)
    private static let fileName = regex(#"^([A-Za-z]+)-Week(\d+)-"#)
    private static let wikiLinkAlias = regex(#"\[\[([^\]|]+)\|([^\]]+)\]\]"#)
    private static let wikiLink = regex(#"\[\[([^\]]+)\]\]"#)
    private static let markdownLink = regex(#"\[([^\]]+)\]\([^)]*\)"#)
    private static let noteID = regex(#"ID:\s*([A-Za-z0-9_\-]+)"#)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 第一个匹配的各个分组（0 是整体）；没有匹配返回 nil，未参与匹配的分组是空字符串。
    private static func match(_ re: NSRegularExpression, in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private static func replacing(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: template)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
