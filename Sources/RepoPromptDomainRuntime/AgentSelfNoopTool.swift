import MCP

/// Fork-only feasibility trial: a stateless response, not a host-side turn seal.
package enum AgentSelfNoopTool {
    package static let definition = MCPDomainToolDefinition(
        name: MCPWindowToolName.selfNoop,
        description: "Quietly close a routine wake that needs nothing.",
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([:])
        ])
    )

    package static func execute() -> Value {
        .object(["result": .string("done")])
    }

    package static let binding = MCPDomainToolBinding(definition: definition) { _ in execute() }
}
