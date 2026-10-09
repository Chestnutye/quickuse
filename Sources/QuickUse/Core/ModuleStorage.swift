import Foundation

/// 每个模块独立的 JSON 存储，位于 ~/Library/Application Support/QuickUse/<模块id>/。
/// 密码等敏感信息不要放这里，用 `Keychain`。
struct ModuleStorage {
    let directory: URL

    init(moduleID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("QuickUse/\(moduleID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 文件不存在时返回 nil。文件存在但解析失败（例如数据结构改了）时，先把它改名备份再返回 nil，
    /// 否则调用方按空数据继续运行，下一次保存就会把原文件覆盖掉。
    /// 给已有的数据结构加字段时，用可选类型或手写解码提供默认值，避免旧文件解析失败。
    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let backup = directory.appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("[QuickUse] 无法解析 %@，已备份为 %@：%@", url.path, backup.lastPathComponent, "\(error)")
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        let url = directory.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
