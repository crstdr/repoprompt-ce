import Foundation

/// Value snapshot shared by parsing and labels during one picker sort.
struct CodexModelDiscovery {
    let records: [CodexDynamicModelRecord]
    private let advertisedIDs: Set<String>
    private let effortsByID: [String: Set<CodexReasoningEffort>]

    init(records: [CodexDynamicModelRecord]) {
        self.records = records
        var ids = Set<String>()
        var efforts: [String: Set<CodexReasoningEffort>] = [:]
        for record in records {
            let key = CodexModelIdentity.key(record.id)
            // The legacy parser uses the first matching capability record.
            guard ids.insert(key).inserted else { continue }
            let raw = record.supportedReasoningEfforts.map(\.reasoningEffort)
                + [record.defaultReasoningEffort].compactMap(\.self)
            efforts[key] = Set(raw.compactMap(CodexReasoningEffort.parse))
        }
        advertisedIDs = ids
        effortsByID = efforts
    }

    func contains(normalizedID: String) -> Bool {
        advertisedIDs.contains(normalizedID)
    }

    func supports(_ normalizedBase: String, _ effort: CodexReasoningEffort) -> Bool {
        effortsByID[normalizedBase]?.contains(effort) == true
    }
}
