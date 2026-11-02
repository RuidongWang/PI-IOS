import Foundation

/// 审批卡正文里的工具调用预览。
///
/// Host 在审批 payload 的 `input` 字段下发了完整的工具参数（例如 bash 的
/// `command`），但审批卡过去只展示工具名，用户实际上是在看不到命令的情况下
/// 决定是否放行。这里把 `input` 渲染成一段有界、可直接阅读的文本，供 UI 与
/// 离线缓存共用；渲染逻辑保持纯函数以便测试。
public enum ApprovalInputPreview {
    /// 预览上限。命令本身通常很短；通用 JSON 参数可能很大，必须截断，
    /// 避免审批卡被一个超长 input 撑爆。
    public static let defaultLimit = 1_200

    /// 返回可直接展示的预览文本；payload 没有可展示的 `input` 时返回 nil。
    public static func text(from payload: JSONValue, limit: Int = defaultLimit) -> String? {
        guard let input = payload.value(at: ["input"]), input != .null else { return nil }
        if case let .string(command) = input {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return bounded("$ \(trimmed)", limit: limit)
        }
        if case let .object(fields) = input,
           let command = fields["command"]?.stringValue {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return bounded("$ \(trimmed)", limit: limit)
            }
        }
        let rendered = render(input)
        guard rendered != "{}", rendered != "[]", !rendered.isEmpty else { return nil }
        return bounded(rendered, limit: limit)
    }

    /// 紧凑、确定性的 JSON 渲染：对象键排序，保证同一输入在不同设备上一致。
    static func render(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case let .bool(flag):
            return flag ? "true" : "false"
        case let .number(number):
            if number.rounded() == number, number.magnitude < 1e15 {
                return String(Int64(number))
            }
            return String(number)
        case let .string(text):
            return quoted(text)
        case let .array(items):
            return "[" + items.map(render).joined(separator: ", ") + "]"
        case let .object(fields):
            let members = fields.keys.sorted().map { key in
                quoted(key) + ": " + render(fields[key] ?? .null)
            }
            return "{" + members.joined(separator: ", ") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count + 2)
        escaped.append("\"")
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        escaped.append("\"")
        return escaped
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n…（输入已截断）"
    }
}
