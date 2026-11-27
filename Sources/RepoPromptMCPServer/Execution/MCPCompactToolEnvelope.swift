/// Wire syntax only. Admission remains owned by the app connection and target dispatcher.
package enum MCPCompactToolEnvelope {
    package static let describe = "describe_tool"
    package static let call = "call_tool"

    package static func isWrapper(_ name: String) -> Bool {
        name == describe || name == call
    }

    package static func forwardedTarget<T>(
        _ fields: [String: T], string: (T) -> String?, object: (T) -> [String: T]?
    ) -> (name: String, arguments: [String: T])? {
        guard fields.keys.allSatisfy({ $0 == "name" || $0 == "arguments" }),
              let name = fields["name"].flatMap(string), !name.isEmpty,
              let arguments = fields["arguments"].flatMap(object)
        else { return nil }
        return (name, arguments)
    }
}
