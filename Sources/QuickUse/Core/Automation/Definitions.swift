import Foundation

/// 触发条件或动作的一个参数。规则编辑器根据 `kind` 自动生成输入控件。
struct ParamSpec {
    enum Kind {
        /// 下拉选择。
        case choice(() -> [ParamOption])
        /// 可自由输入，旁边带建议列表。空值表示“任意”。
        case suggestions(placeholder: String, () -> [String])
        /// 选择一个 .app，值为路径。
        case application
        /// 普通文本。
        case text(placeholder: String)
    }

    let key: String
    let label: String
    let kind: Kind
}

struct ParamOption: Hashable {
    let value: String
    let label: String
}

/// 模块提供的一种自动化触发条件。模块发出 `AppEvent(kind: id, params:)` 时，
/// 规则里填写的每个非空参数都要和事件参数相等才算命中。
struct TriggerDefinition {
    let id: String
    let title: String
    let icon: String
    let params: [ParamSpec]
    /// 生成一句话描述，例如“连上 eduroam 时”。
    let summary: ([String: String]) -> String
}

enum ActionOutcome {
    case done(String)
    case skipped(String)
    case failed(String)
}

/// 模块提供的一种自动化动作。`run` 应当是幂等的：目标状态已满足时返回 `.skipped`。
struct ActionDefinition {
    let id: String
    let title: String
    let icon: String
    let params: [ParamSpec]
    let summary: ([String: String]) -> String
    /// 同一条规则里，与上一个“实际执行了”（`.done`）的同类动作之间至少间隔多久。被跳过的不算。
    var spacing: Duration = .zero
    let run: @MainActor ([String: String]) async -> ActionOutcome
}
