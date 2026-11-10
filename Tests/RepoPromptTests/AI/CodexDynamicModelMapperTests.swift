import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexDynamicModelMapperTests: XCTestCase {
    func testOptionComparatorObeysStrictWeakOrdering() {
        var options: [CodexDynamicModelOption] = []
        let efforts: [CodexReasoningEffort?] = [nil, .low, .high]
        for base in ["gpt-5.2", "gpt-5.4", "future-model"] {
            for effort in efforts {
                options.append(option(
                    id: "\(base)-\(effort?.rawValue ?? "base")",
                    base: base,
                    name: "\(base) \(effort?.rawValue ?? "Base")",
                    effort: effort,
                    isDefault: base == "gpt-5.2" && effort == .high
                ))
            }
        }
        options.append(option(id: "gpt-5.4-default", base: "gpt-5.4", name: "GPT-5.4", effort: .high, isDefault: true))
        options.append(option(id: "future-model-alpha", base: "future-model", name: "Shared", effort: .high))
        options.append(option(id: "future-model-beta", base: "future-model", name: "shared", effort: .high))
        options.append(option(id: "FUTURE-MODEL-ALPHA", base: "FUTURE-MODEL", name: "SHARED", effort: .high))
        let precedes = CodexDynamicModelMapper.optionPrecedes
        let equivalent = { (lhs: CodexDynamicModelOption, rhs: CodexDynamicModelOption) in
            !precedes(lhs, rhs) && !precedes(rhs, lhs)
        }

        for lhs in options {
            XCTAssertFalse(precedes(lhs, lhs), "Irreflexivity: \(lhs.id)")
            for middle in options {
                if precedes(lhs, middle) {
                    XCTAssertFalse(precedes(middle, lhs), "Asymmetry: \(lhs.id), \(middle.id)")
                }
                for rhs in options {
                    if precedes(lhs, middle), precedes(middle, rhs) {
                        XCTAssertTrue(precedes(lhs, rhs), "Transitivity: \(lhs.id), \(middle.id), \(rhs.id)")
                    }
                    if equivalent(lhs, middle), equivalent(middle, rhs) {
                        XCTAssertTrue(equivalent(lhs, rhs), "Equivalence: \(lhs.id), \(middle.id), \(rhs.id)")
                    }
                }
            }
        }
    }

    func testDefaultPriorityRemovesThePreviousThreeOptionCycle() {
        let options = CodexDynamicModelMapper.options(from: [
            record(id: "gpt-5.2", isDefault: true, efforts: ["low", "high"], defaultEffort: "high"),
            record(id: "gpt-5.4", efforts: ["low"], defaultEffort: "low")
        ])

        // Previously: 5.2-low < 5.2-high (effort), 5.2-high < 5.4-low
        // (default), and 5.4-low < 5.2-low (base version).
        XCTAssertEqual(options.map(\.id), ["gpt-5.2-high", "gpt-5.4-low", "gpt-5.2-low"])
        XCTAssertTrue(CodexDynamicModelMapper.optionPrecedes(options[0], options[2]))
    }

    func testEqualDisplayNamesUseNormalizedOptionIdentity() {
        let alpha = option(id: "future-alpha", base: "future-model", name: "Shared", effort: .high)
        let beta = option(id: "future-beta", base: "future-model", name: "shared", effort: .high)

        XCTAssertEqual(alpha.displayName.localizedCaseInsensitiveCompare(beta.displayName), .orderedSame)
        for input in [[alpha, beta], [beta, alpha]] {
            XCTAssertEqual(input.sorted(by: CodexDynamicModelMapper.optionPrecedes).map(\.id), [alpha.id, beta.id])
        }
    }

    func testMapperOrderIsIndependentOfUniqueRecordPermutation() {
        let records = [
            record(id: "gpt-5.2", isDefault: true, efforts: ["high", "low"], defaultEffort: "high"),
            record(id: "gpt-5.4", efforts: ["low"], defaultEffort: "low"),
            record(id: "future-b", displayName: "Shared"),
            record(id: "future-a", displayName: "shared")
        ]
        let expected = CodexDynamicModelMapper.options(from: records)
        for permutation in permutations(records) {
            XCTAssertEqual(CodexDynamicModelMapper.options(from: permutation), expected)
        }
    }

    private func option(
        id: String,
        base: String,
        name: String,
        effort: CodexReasoningEffort?,
        isDefault: Bool = false
    ) -> CodexDynamicModelOption {
        CodexDynamicModelOption(id: id, displayName: name, description: "", isDefault: isDefault, baseID: base, reasoningEffort: effort)
    }

    private func record(
        id: String,
        displayName: String? = nil,
        isDefault: Bool = false,
        efforts: [String] = [],
        defaultEffort: String? = nil
    ) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: displayName ?? id,
            description: "",
            isDefault: isDefault,
            supportedReasoningEfforts: efforts.map { CodexDynamicReasoningRecord(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: defaultEffort
        )
    }

    private func permutations(_ records: [CodexDynamicModelRecord]) -> [[CodexDynamicModelRecord]] {
        guard records.count > 1 else { return [records] }
        return records.indices.flatMap { index in
            var rest = records
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }
}

final class CodexMapperDiscoveryParityTests: XCTestCase {
    func testCompleteOptionsMatchRecordsReferenceAcrossCatalogTransitions() {
        let ids = [
            "gpt-5.6",
            "gpt-5.6-sol",
            "gpt-5.5",
            "gpt-5.1-codex-max",
            "future",
            " FUTURE ",
            "future-max",
            "future-ultra",
            "future-fast-max",
            "future-ultrafast",
            "é",
            "e\u{301}",
            "İ",
            "i\u{307}",
            "模型-٢",
            "",
            " \n",
            "default"
        ]
        var catalogs: [[CodexDynamicModelRecord]] = [[]]
        for round in 0 ..< 24 {
            let records = ids.enumerated().map { index, id in
                CodexDynamicModelRecord(
                    id: id, model: index.isMultiple(of: 3) ? "" : id,
                    displayName: ["", id, "Shared", "shared", "İ-É 模型"][index % 5],
                    description: " description \(round)-\(index) ", isDefault: index == round % ids.count,
                    supportedReasoningEfforts: (index.isMultiple(of: 4) ? [] : ["low", "HIGH", "max", "maximum", "ultra", "unknown", " high "]).map {
                        .init(reasoningEffort: $0, description: " \($0)-\(round) ")
                    },
                    defaultReasoningEffort: [nil, "medium", "max", "ultra", "unknown"][index % 5],
                    serviceTiers: index.isMultiple(of: 2) ? [.init(id: " ULTRAFAST ", name: "", description: "speed")] : []
                )
            }
            let offset = round % records.count
            let rotated = Array(records[offset...]) + Array(records[..<offset])
            catalogs += [rotated, Array(rotated.reversed()), [], Array(rotated.prefix(3))]
        }
        for records in catalogs {
            assertCompleteParity(records)
        }
        // Revisit the first catalog after the intervening empty, reordered and partial mapper inputs.
        assertCompleteParity(catalogs[1])
    }

    func testDuplicateCapabilitiesStayFirstWinsForBothRecordOrders() {
        let first = CodexDynamicModelRecord(id: " future ", model: "future", displayName: "First", description: "first", isDefault: true, defaultReasoningEffort: "max")
        let second = CodexDynamicModelRecord(id: "FUTURE", model: "future", displayName: "Second", description: "second", isDefault: false, defaultReasoningEffort: "ultra")
        for records in [[first, second], [second, first]] {
            assertCompleteParity(records)
            let discovery = CodexModelDiscovery(records: records)
            for raw in ["future-max", "future-ultra", "future-fast-max", "future-ultrafast-ultra"] {
                XCTAssertEqual(CodexModelSpecifier(raw: raw, discovery: discovery), CodexModelSpecifier(raw: raw, discoveredRecords: records))
            }
        }
    }

    func testIndexedBaseComparatorMatchesRecordsIncludingExactUnicodeSpelling() {
        let bases = ["", "gpt-5.6", "gpt-5.6-sol", "gpt-5.5", "gpt-5.1-codex-max", "future", " FUTURE ", "future-max", "future-ultra", "future-fast", "future-ultrafast", "é", "e\u{301}", "İ", "i\u{307}"]
        for ids in [bases, Array(bases.reversed()), []] {
            let records = ids.map { CodexDynamicModelRecord(id: $0, model: $0, displayName: $0, description: "", isDefault: false, defaultReasoningEffort: "ultra") }
            let discovery = CodexModelDiscovery(records: records)
            for lhs in bases {
                for rhs in bases {
                    XCTAssertEqual(AIModel.codexBaseModelPrecedes(lhs, rhs, discovery: discovery), AIModel.codexBaseModelPrecedes(lhs, rhs, discoveredRecords: records), "\(lhs), \(rhs)")
                }
            }
        }
    }

    private func assertCompleteParity(_ records: [CodexDynamicModelRecord], file: StaticString = #filePath, line: UInt = #line) {
        let expected = CodexRecordsReferenceMapper.options(from: records)
        let actual = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(actual, expected, file: file, line: line)
        /// String equality alone cannot detect canonically equivalent but byte-distinct output.
        func bytes(_ options: [CodexDynamicModelOption]) -> [[[UInt8]]] {
            options.map { option in
                (
                    [option.id, option.displayName, option.description, option.baseID]
                        + option.supportedReasoningEffortRawValues
                        + [option.defaultReasoningEffortRawValue].compactMap(\.self)
                ).map { Array($0.utf8) }
            }
        }
        XCTAssertEqual(bytes(actual), bytes(expected), file: file, line: line)
    }
}

/// Records-path differential reference from 996ffdd12, CodexAIModelCatalog.swift.
/// Shares identity, parser, alias and ordering primitives with production; it is not an independent golden.
private enum CodexRecordsReferenceMapper {
    private struct EffortEntry {
        let effort: CodexReasoningEffort
        let description: String
        let isDefault: Bool
    }

    static func options(from records: [CodexDynamicModelRecord]) -> [CodexDynamicModelOption] {
        var options: [CodexDynamicModelOption] = []
        var seen = Set<String>()
        let advertisedIDs = Set(records.map { CodexModelIdentity.key($0.id) }.filter { !$0.isEmpty })

        // Capability changes participate in the registry signature and are persisted.
        // A future model can gain Ultrafast on refresh without a model-version allowlist.
        let speedRecords = records.compactMap { record -> CodexDynamicModelRecord? in
            guard !normalizeID(record.id).isEmpty,
                  CodexModelSpecifier(raw: record.id, discoveredRecords: records).serviceTier == nil,
                  let tier = record.serviceTiers.first(where: {
                      $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                          == CodexServiceTierVariantCatalog.ultrafastServiceTier
                  }) else { return nil }
            let id = "\(normalizeID(record.id))-\(CodexServiceTierVariantCatalog.ultrafastServiceTier)"
            guard !advertisedIDs.contains(CodexModelIdentity.key(id)) else { return nil }
            let name = tier.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? "Ultrafast" : name
            return CodexDynamicModelRecord(
                id: id, model: record.model, displayName: "\(record.displayName) \(label)",
                description: [record.description, tier.description].filter { !$0.isEmpty }.joined(separator: " "),
                isDefault: false, supportedReasoningEfforts: record.supportedReasoningEfforts,
                defaultReasoningEffort: record.defaultReasoningEffort
            )
        }
        for record in records + speedRecords {
            let baseID = normalizeID(record.id)
            guard !baseID.isEmpty else { continue }

            let baseName = formatBaseDisplayName(
                record.displayName,
                fallbackModel: record.model,
                fallbackID: baseID,
                records: records
            )
            let baseDescription = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawEfforts = record.supportedReasoningEfforts.map(\.reasoningEffort)
                + [record.defaultReasoningEffort].compactMap(\.self)
            // Extended effort parsing preserves exact model identities. Do not offer a
            // synthetic option that would resolve to another advertised model instead.
            let effortEntries = normalizedEfforts(for: record, fallbackDescription: baseDescription).filter { entry in
                ![CodexReasoningEffort.max, .ultra].contains(entry.effort)
                    || !advertisedIDs.contains(CodexModelIdentity.key("\(baseID)-\(entry.effort.rawValue)"))
            }

            if effortEntries.isEmpty {
                appendOption(
                    CodexDynamicModelOption(
                        id: baseID,
                        displayName: baseName,
                        description: baseDescription,
                        isDefault: record.isDefault,
                        baseID: baseID,
                        reasoningEffort: nil,
                        supportedReasoningEffortRawValues: rawEfforts,
                        defaultReasoningEffortRawValue: record.defaultReasoningEffort,
                        defaultReasoningEffort: CodexReasoningEffort.parse(record.defaultReasoningEffort)
                    ),
                    seen: &seen,
                    into: &options
                )
                continue
            }

            for effortEntry in effortEntries {
                let optionID = "\(baseID)-\(effortEntry.effort.rawValue)"
                let optionDescription = effortEntry.description.isEmpty ? baseDescription : effortEntry.description
                appendOption(
                    CodexDynamicModelOption(
                        id: optionID,
                        displayName: "\(baseName) \(effortEntry.effort.displayName)",
                        description: optionDescription,
                        isDefault: record.isDefault && effortEntry.isDefault,
                        baseID: baseID,
                        reasoningEffort: effortEntry.effort,
                        supportedReasoningEffortRawValues: rawEfforts,
                        defaultReasoningEffortRawValue: record.defaultReasoningEffort,
                        defaultReasoningEffort: CodexReasoningEffort.parse(record.defaultReasoningEffort)
                    ),
                    seen: &seen,
                    into: &options
                )
            }
        }

        return options.sorted { compareOptions($0, $1, discoveredRecords: records) }
    }

    private static func compareOptions(
        _ lhs: CodexDynamicModelOption,
        _ rhs: CodexDynamicModelOption,
        discoveredRecords: [CodexDynamicModelRecord]
    ) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault && !rhs.isDefault
        }

        let leftBase = CodexModelIdentity.key(lhs.baseID)
        let rightBase = CodexModelIdentity.key(rhs.baseID)
        if leftBase == rightBase {
            let leftRank = effortRank(lhs.reasoningEffort)
            let rightRank = effortRank(rhs.reasoningEffort)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
        } else {
            if AIModel.codexBaseModelPrecedes(leftBase, rightBase, discoveredRecords: discoveredRecords) { return true }
            if AIModel.codexBaseModelPrecedes(rightBase, leftBase, discoveredRecords: discoveredRecords) { return false }
        }

        let displayComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }
        return normalizedOptionID(lhs.id) < normalizedOptionID(rhs.id)
    }

    private static func appendOption(_ option: CodexDynamicModelOption, seen: inout Set<String>, into output: inout [CodexDynamicModelOption]) {
        let key = CodexModelIdentity.key(option.id)
        guard seen.insert(key).inserted else { return }
        output.append(option)
    }

    private static func normalizedOptionID(_ id: String) -> String {
        CodexModelIdentity.key(id)
    }

    private static func normalizedEfforts(for record: CodexDynamicModelRecord, fallbackDescription: String) -> [EffortEntry] {
        var descriptionsByEffort: [CodexReasoningEffort: String] = [:]
        for entry in record.supportedReasoningEfforts {
            guard let effort = CodexReasoningEffort.parse(entry.reasoningEffort),
                  descriptionsByEffort[effort] == nil else { continue }
            descriptionsByEffort[effort] = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let defaultEffort = CodexReasoningEffort.parse(record.defaultReasoningEffort)
        if let defaultEffort, descriptionsByEffort[defaultEffort] == nil {
            descriptionsByEffort[defaultEffort] = fallbackDescription
        }

        guard !descriptionsByEffort.isEmpty else { return [] }

        let effectiveDefault = defaultEffort
            ?? CodexReasoningEffort.displayOrder.first(where: { descriptionsByEffort[$0] != nil })
            ?? descriptionsByEffort.keys.first

        var output: [EffortEntry] = []
        for effort in CodexReasoningEffort.displayOrder {
            guard let description = descriptionsByEffort[effort] else { continue }
            output.append(
                EffortEntry(
                    effort: effort,
                    description: description,
                    isDefault: effectiveDefault == effort
                )
            )
        }
        return output
    }

    private static func effortRank(_ effort: CodexReasoningEffort?) -> Int {
        guard let effort else { return -1 }
        return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
    }

    private static func normalizeID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatBaseDisplayName(_ preferred: String, fallbackModel: String, fallbackID: String, records: [CodexDynamicModelRecord]) -> String {
        let preferredTrimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredTrimmed.isEmpty {
            return humanizeLabel(preferredTrimmed, records: records)
        }
        let fallbackModelTrimmed = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallbackModelTrimmed.isEmpty {
            return humanizeLabel(fallbackModelTrimmed, records: records)
        }
        return humanizeLabel(fallbackID, records: records)
    }

    private static func humanizeLabel(_ raw: String, records: [CodexDynamicModelRecord]) -> String {
        if let alias = AIModel.codexPreviewDisplayAlias(for: raw, discoveredRecords: records) {
            return alias
        }

        let tokens = raw.split { character in
            character == "_" || character == "-" || character == "/" || character.isWhitespace
        }
        guard !tokens.isEmpty else { return raw }

        var formatted: [String] = []
        formatted.reserveCapacity(tokens.count)
        for token in tokens {
            let value = String(token)
            let formattedToken = formatLabelToken(value)
            if isVersionToken(value), formatted.last == "GPT" {
                formatted[formatted.count - 1] = "GPT-\(formattedToken)"
            } else {
                formatted.append(formattedToken)
            }
        }
        return formatted.joined(separator: " ")
    }

    private static func formatLabelToken(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "gpt" { return "GPT" }
        if lower == "cli" { return "CLI" }
        if lower == "codex" { return "Codex" }
        if lower == "openai" { return "OpenAI" }
        if lower == "xhigh" { return "XHigh" }
        if lower == "ultra" { return "Ultra" }
        if lower == "low" { return "Low" }
        if lower == "medium" { return "Medium" }
        if lower == "high" { return "High" }
        if lower == "minimal" { return "Minimal" }
        if lower == "none" { return "None" }
        if isONumberToken(lower) { return lower.uppercased() }
        if isVersionToken(value) { return value }
        return lower.capitalized
    }

    private static func isONumberToken(_ lower: String) -> Bool {
        guard lower.first == "o", lower.count > 1 else { return false }
        return lower.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}
