import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    /// 同步执行命令行程序（不经过 shell，参数不需要转义）。
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(data: data, encoding: .utf8) ?? "")
    }

    /// 执行 AppleScript，返回结果字符串；出错时抛出系统给出的错误信息。
    static func appleScript(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "" }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            throw NSError(domain: "AppleScript", code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return result.stringValue ?? ""
    }
}
