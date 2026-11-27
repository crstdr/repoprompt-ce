import MCP
import RepoPromptMCPServer

/// Temporary projection for Antigravity's eager-only ACP catalog. Not a tool registry.
enum MCPCompactToolCatalog {
    static let nativeNames: Set<String> = ["self_compact", "self_noop", "set_status"]
    static let guidance = "Antigravity can time out tool calls after 3 minutes. Keep observation waits at 120 seconds or less; detach starts when supported."
    static let unavailable = "Compact tool dispatch is not available for this connection."
    static let malformedDescribe = "describe_tool accepts only an optional non-empty name."
    static let malformedCall = "call_tool requires a non-empty name and an arguments object; no other public arguments are accepted."
    static let recursiveCall = "call_tool cannot target describe_tool or call_tool."

    static func unavailableTarget(_ name: String) -> String {
        "Tool '\(name)' is not available for this session."
    }

    static var wrappers: [MCP.Tool] {
        let string: Value = .object(["type": .string("string")])
        return [
            .init(
                name: MCPCompactToolEnvelope.describe,
                description: "List available tools and what they do. Pass a name to get its full description and input schema.",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object(["name": string]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            .init(
                name: MCPCompactToolEnvelope.call,
                description: "Run a tool with arguments from its input schema. Use describe_tool to find the schema.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": string,
                        "arguments": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(true)])
                    ]),
                    "required": .array([.string("name"), .string("arguments")]),
                    "additionalProperties": .bool(false)
                ])
            )
        ]
    }

    static func project(_ tools: [MCP.Tool], compact: Bool, enabled: Bool) -> [MCP.Tool] {
        guard compact else { return tools }
        guard enabled else { return [] }
        return wrappers + tools.filter { nativeNames.contains($0.name) }
    }

    static func hasExactWrapperPair(_ tools: [MCP.Tool]) -> Bool {
        wrappers.allSatisfy { wrapper in tools.filter { $0.name == wrapper.name } == [wrapper] }
    }

    static func directory(_ tools: [MCP.Tool]) -> String {
        ([guidance] + tools.filter { !MCPCompactToolEnvelope.isWrapper($0.name) }.map { tool in
            let summary: String = switch tool.name {
            case "ask_oracle": "Ask the configured Oracle roster or continue an eligible Oracle conversation."
            case "oracle_chat_log": "Read recent Oracle conversation messages."
            default: firstSentence(tool.description ?? "")
            }
            let marker = nativeNames.contains(tool.name) ? " [native]" : ""
            return "\(tool.name)\(marker): \(summary)"
        }).joined(separator: "\n")
    }

    private static func firstSentence(_ description: String) -> String {
        let line = String(description.split(whereSeparator: \.isNewline).first ?? "")
        var inCode = false
        for index in line.indices {
            let character = line[index]
            if character == "`" { inCode.toggle() }
            guard character == ".", !inCode else { continue }
            let next = line.index(after: index)
            if next == line.endIndex || line[next].isWhitespace { return String(line[...index]) }
        }
        return line
    }
}
