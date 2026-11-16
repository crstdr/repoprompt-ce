import CryptoKit
import Foundation
import OSLog

/// Entry: agent_run service completion (or direct-headless CU validation).
/// Records one content-free boundary outcome; coarse reasons identify existing guard sites.
/// Scope ends at completion: inherited workers cannot emit a second record. No authority is stored.
package final class ComputerUseRunDiagnostic: @unchecked Sendable {
    package enum Reason: String, CaseIterable {
        case admission_collision
        case admission_companion
        case admission_disabled
        case admission_ineligible
        case admission_proof
        case admission_runtime
        case argument_keys
        case argument_operation
        case argument_type
        case arm_admission
        case arm_permits
        case arm_runtime
        case capture_candidate_absent
        case capture_candidate_mismatch
        case capture_context
        case capture_endpoint
        case capture_parent_run
        case external_arm_proof_missing
        case external_dispatch_proof_missing
        case headless_keys
        case headless_operation
        case headless_type
        case headless_unavailable
        case init_binding
        case init_child
        case init_endpoint
        case init_grant
        case init_model_allowed
        case init_model_available
        case init_owner
        case init_parent
        case init_policy
        case init_provider
        case init_session
        case native_ensureCodexNativeSession_1
        case proof_acceptCreation_1
        case proof_captureRestoredChild_1
        case proof_captureRestoredChild_2
        case proof_captureRestoredChild_3
        case proof_captureRestoredChild_4
        case proof_claimCreation_1
        case proof_claimCreation_2
        case proof_claimCreation_3
        case proof_markInstructionDispatch_1
        case proof_requireCurrent_1
        case proof_reserve_1
        case proof_reserve_2
        case proof_withInstructionSubmission_1
        case service_executeSteer_1
        case service_executeSteer_2
        case service_executeSteer_3
        case service_executeSteer_4
        case service_executeSteer_5
        case service_executeSteer_6
        case start_parent_child_index
        case start_existing_child
        case start_pinned_model
        case start_child_permits
        case steer_controlled_child
        case steer_restored_model
        case steer_model_effort
        case vm_armComputerUseForLocalUser_1
        case activate_final_proof
        case vm_mcpActivateControlContext_1
        case vm_mcpActivateControlContext_2
        case vm_mcpActivateControlContext_3
        case vm_mcpDispatchInstruction_1
        case start_run_prepared_proof
        case vm_requireActivationOwner_1
        case vm_requireConfigurationAdmission_1
        case vm_startAgentRun_1
        case vm_startAgentRun_2
        case local_arm_policy
        case vm_submitPreparedUserTurn_1
        case vm_submitUserTurn_1
        case vm_submitUserTurn_2
        case vm_withMCPInstructionSubmission_1
    }

    package enum Backend: String { case app, directHeadless = "direct_headless" }
    package enum Tag: String { case absent, bool = "B", string = "S", number = "N", object = "O", array = "A", null = "Z" }
    package static let keys = ["op", "computer_use", "message", "timeout", "detach", "session_name"]
    package static let scope = BoxedTaskLocal<ComputerUseRunDiagnostic?>(nil)
    package static let admissionScope = BoxedTaskLocal<Bool>(false)
    package static func admission<T>(_ reason: Reason, _ original: T) -> T {
        if admissionScope.get() { return record(reason, original) }
        return original
    }

    private static let speculative = BoxedTaskLocal<Bool>(false)
    private static let logger = Logger(subsystem: "com.repoprompt.ce", category: "ComputerUseRun")
    private static func build(displayVersion: String?, buildVersion: String?) -> String {
        func component(_ input: String?) -> String {
            guard let value = input,
                  !value.isEmpty, value.utf8.count <= 64,
                  value.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || [43, 45, 46, 95].contains($0) }) else { return "unknown" }
            return value
        }
        #if DEBUG
            let channel = "debug"
        #else
            let channel = "release"
        #endif
        return "\(channel)/\(component(displayVersion))(\(component(buildVersion)))"
    }

    private let lock = NSLock()
    private let prefix: String
    private let shape: String
    private var interested: Bool
    private var first: Reason?
    private var provisional: Reason?
    private var finished = false

    package init(backend: Backend, operation: String, invocationID: UUID?, interested: Bool, tags: [Tag], keyCount: Int, displayVersion: String? = nil, buildVersion: String? = nil) {
        let op = ["start", "steer"].contains(operation) ? operation : "other"
        let hash = invocationID.map { id in SHA256.hash(data: Data(id.uuidString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "none"
        prefix = "event=cu-run schema=cu_run_v1 backend=\(backend.rawValue) op=\(op) inv=\(hash) build=\(Self.build(displayVersion: displayVersion, buildVersion: buildVersion))"
        shape = "keys=" + Self.keys.enumerated().map { i, key in "\(key):\(tags.indices.contains(i) ? tags[i].rawValue : Tag.absent.rawValue)" }.joined(separator: ",") + " unknown_keys=\(max(0, keyCount - tags.count(where: { $0 != .absent })))"
        self.interested = interested
    }

    /// Returns the existing error/message unchanged; diagnostics never classify by its contents.
    package static func record<T>(_ reason: Reason, _ original: T) -> T {
        scope.get()?.record(reason, provisional: speculative.get())
        return original
    }

    private func record(_ reason: Reason, provisional isProvisional: Bool) {
        lock.withLock {
            guard !finished else { return }
            interested = true
            if isProvisional { if provisional == nil { provisional = reason } }
            else if first == nil { first = reason }
        }
    }

    /// A swallowed steer probe is an observation until the target requires CU authority.
    package static func probe<T>(_ operation: () throws -> T) -> T? {
        speculative.withValue(true) { try? operation() }
    }

    package func promoteProbe() {
        lock.withLock {
            guard !finished else { return }
            interested = true
            if first == nil { first = provisional }
        }
    }

    package func finish(success: Bool) {
        let line: String? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard interested else { return nil }
            let argument = first?.rawValue.hasPrefix("argument_") == true || first?.rawValue.hasPrefix("headless_") == true && first != .headless_unavailable
            let outcome = argument ? "invalid_argument" : (first != nil ? "denied" : (success ? "ok" : "failed"))
            let reason = first?.rawValue ?? (success ? "none" : "unclassified")
            let degraded = first == nil ? provisional.map { " degraded=\($0.rawValue)" } ?? "" : ""
            return "\(prefix) arg=\(argument ? "reject" : "ok") outcome=\(outcome) reason=\(reason) \(shape)\(degraded)"
        }
        guard let line else { return }
        Self.logger.notice("\(line, privacy: .public)")
        #if DEBUG
            Self.capture.lock.withLock { if Self.capture.enabled { Self.capture.lines.append(line) } }
        #endif
    }

    #if DEBUG
        private final class Capture: @unchecked Sendable {
            let lock = NSLock()
            var enabled = false
            var lines: [String] = []
        }

        private static let capture = Capture()
        package static func beginCaptureForTesting() {
            capture.lock.withLock { capture.lines = []
                capture.enabled = true
            }
        }

        package static func endCaptureForTesting() -> [String] {
            capture.lock.withLock { capture.enabled = false
                return capture.lines
            }
        }
    #endif
}
