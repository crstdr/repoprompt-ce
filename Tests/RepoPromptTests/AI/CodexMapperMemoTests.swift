import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexMapperMemoTests: XCTestCase {
    private func records() -> [CodexDynamicModelRecord] {
        ["gpt-6.1-sol", "gpt-6-luna", "gpt-5.3-codex", "gpt-5.5", "gpt-5.4", "gpt-5.2", "o3", "o4-mini", "codex-mini", "future-model"].enumerated().map { index, id in
            CodexDynamicModelRecord(id: id, model: id, displayName: id, description: "Description \(index)", isDefault: index == 0, supportedReasoningEfforts: ["low", "medium", "high", "xhigh"].map { .init(reasoningEffort: $0, description: $0) }, defaultReasoningEffort: "high")
        }
    }

    func testRepeatedMappingAndPickerTiming() throws {
        let records = records()
        let key = "CodexDynamicModelRecords"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        try defaults.set(JSONEncoder().encode(records), forKey: key)
        func measure(_ name: String, _ body: () -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            print("CODEX_BASELINE \(name) wall_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) cpu_ms=\(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)")
        }
        measure("mapper cold") { _ = CodexDynamicModelMapper.options(from: records) }
        measure("picker cold") { _ = CodexAIModelCatalog.modelsForPicker(staticModels: []) }
        for pair in 0 ..< 5 {
            for cached in pair.isMultiple(of: 2) ? [false, true] : [true, false] {
                measure(cached ? "cached 37" : "mapper repeated 37") {
                    for _ in 0 ..< 37 {
                        if cached { _ = CodexDynamicModelStore.modelOptions(defaults: defaults) }
                        else { _ = CodexDynamicModelMapper.options(from: records) }
                    }
                }
            }
        }
        measure("picker repeated 37") { for _ in 0 ..< 37 {
            _ = CodexAIModelCatalog.modelsForPicker(staticModels: [])
        } }
    }

    func testPayloadTransitionsAndConcurrentReplacement() throws {
        let suiteA = "CodexMapperMemoTests-A-\(UUID())"
        let suiteB = "CodexMapperMemoTests-B-\(UUID())"
        let a = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let b = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer { a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }
        let key = "CodexDynamicModelRecords"
        let original = records()
        let duplicate = CodexDynamicModelRecord(id: "GPT-6.1-SOL", model: "other", displayName: "é", description: "changed", isDefault: false, supportedReasoningEfforts: [.init(reasoningEffort: "ultra", description: "extra")], defaultReasoningEffort: "ultra", serviceTiers: [.init(id: "ultrafast", name: "Fast", description: "speed")])
        func unicodeRecord(_ spelling: String) -> CodexDynamicModelRecord {
            CodexDynamicModelRecord(id: spelling, model: spelling, displayName: spelling, description: spelling, isDefault: true, supportedReasoningEfforts: [.init(reasoningEffort: spelling, description: spelling)], defaultReasoningEffort: spelling)
        }
        let composed = [unicodeRecord("é")]
        let decomposed = [unicodeRecord("e\u{301}")]
        XCTAssertNotEqual(try JSONEncoder().encode(composed), try JSONEncoder().encode(decomposed))
        let inputs = [original, [duplicate] + original, Array(original.reversed()) + [duplicate], [], composed, decomposed, composed]
        for input in inputs {
            try a.set(JSONEncoder().encode(input), forKey: key)
            let expected = CodexDynamicModelMapper.options(from: input)
            for _ in 0 ..< 2 {
                let actual = CodexDynamicModelStore.modelOptions(defaults: a)
                XCTAssertEqual(actual, expected)
                func bytes(_ options: [CodexDynamicModelOption]) -> [[[UInt8]]] {
                    options.map { option in
                        ([option.id, option.baseID, option.displayName, option.description] + option.supportedReasoningEffortRawValues + [option.defaultReasoningEffortRawValue].compactMap(\.self)).map { Array($0.utf8) }
                    }
                }
                XCTAssertEqual(bytes(actual), bytes(expected))
            }
        }
        a.set(Data("malformed".utf8), forKey: key)
        XCTAssertEqual(CodexDynamicModelStore.modelOptions(defaults: a), [])
        a.removeObject(forKey: key)
        XCTAssertEqual(CodexDynamicModelStore.modelOptions(defaults: a), [])
        let dataA = try JSONEncoder().encode(original)
        let dataB = try JSONEncoder().encode([duplicate])
        a.set(dataA, forKey: key)
        b.set(dataB, forKey: key)
        let expectedA = CodexDynamicModelMapper.options(from: original)
        let expectedB = CodexDynamicModelMapper.options(from: [duplicate])
        let lock = NSLock()
        var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let result = CodexDynamicModelStore.modelOptions(defaults: index.isMultiple(of: 2) ? a : b)
            if result != (index.isMultiple(of: 2) ? expectedA : expectedB) { lock.lock()
                mismatches += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(mismatches, 0)
        // Force a miss, then replace the exact store payload during computation.
        let capturedData = try JSONEncoder().encode([duplicate] + original)
        a.set(capturedData, forKey: key)
        let captured = CodexDynamicModelStore.test_modelOptions(defaults: a) { a.set(dataB, forKey: key) }
        XCTAssertEqual(captured, CodexDynamicModelMapper.options(from: [duplicate] + original))
        a.set(capturedData, forKey: key) // No store read between replacement and restoration.
        var recomputed = false
        XCTAssertEqual(CodexDynamicModelStore.test_modelOptions(defaults: a) { recomputed = true }, captured)
        XCTAssertTrue(recomputed, "A result computed for a replaced payload must not be installed")
        a.set(dataB, forKey: key)
        XCTAssertEqual(CodexDynamicModelStore.modelOptions(defaults: a), expectedB)
        recomputed = false
        XCTAssertEqual(CodexDynamicModelStore.test_modelOptions(defaults: a) { recomputed = true }, expectedB)
        XCTAssertFalse(recomputed)

        let oversized = [CodexDynamicModelRecord(id: "large", model: "large", displayName: "large", description: String(repeating: "x", count: 1_050_000), isDefault: false)]
        try a.set(JSONEncoder().encode(oversized), forKey: key)
        _ = CodexDynamicModelStore.modelOptions(defaults: a)
        recomputed = false
        _ = CodexDynamicModelStore.test_modelOptions(defaults: a) { recomputed = true }
        XCTAssertTrue(recomputed)
    }
}
