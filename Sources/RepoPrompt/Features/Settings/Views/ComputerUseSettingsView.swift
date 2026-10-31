import RepoPromptSettingsCore
import SwiftUI

@MainActor
final class ComputerUseAvailability: ObservableObject {
    @Published private(set) var messages = ["Checking Computer Use availability…"]
    @Published private(set) var terraAvailable = false
    private var generation = UUID()

    func invalidate() {
        generation = UUID()
    }

    func refresh(load: () async -> (messages: [String], terraAvailable: Bool)) async {
        invalidate()
        let token = generation
        messages = ["Checking Computer Use availability…"]
        let result = await load()
        guard !Task.isCancelled, generation == token else { return }
        messages = result.messages
        terraAvailable = result.terraAvailable
    }

    nonisolated static func snapshot(companion: Bool, runtime: URL?, signed: (URL) -> Bool) -> [String] {
        [
            companion ? "✓ Computer Use companion installed" : "Computer Use companion missing",
            runtime.map { signed($0) ? "✓ OpenAI-signed Codex runtime" : "Codex runtime is not OpenAI-signed" } ?? "Codex runtime unavailable"
        ]
    }

    nonisolated static func externalRuntimeURL(_ path: String, isExecutable: (String) -> Bool = { path in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }) -> URL? {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        return isExecutable(url.path) ? url : nil
    }

    nonisolated static func read(selection: CodexRuntimePreferences.Selection) -> [String] {
        let runtime: URL? = switch selection {
        case let .external(path):
            externalRuntimeURL(path)
        case .inherited, .bundled:
            (try? CodexRuntimeAuthority.resolveConfigured(selection: selection).get())?.executableURL
        case .invalidExternalPreference:
            nil
        }
        return snapshot(companion: CodexNativeSessionController.computerUseClientPath() != nil, runtime: runtime) {
            CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: $0.resolvingSymlinksInPath()) == nil
        }
    }
}

@MainActor
struct ComputerUseSettingsView: View {
    let onDirectChange: (Bool) -> Void
    @ObservedObject private var settings = GlobalSettingsStore.shared
    @StateObject private var availability = ComputerUseAvailability()
    private var preferences: GlobalScalarPreferences.AgentModeSettings? {
        settings.scalarPreferences.agentMode
    }

    private var model: String {
        preferences?.computerUseModel ?? "codexExec:gpt-6.1-terra-high"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Computer Use", isOn: Binding(
                    get: { settings.computerUseMasterEnabled }, set: { settings.setComputerUseMasterEnabled($0) }
                ))
            }
            Section {
                Picker("Provider", selection: .constant("codex")) { Text("Codex").tag("codex") }
                LabeledContent("Status") {
                    VStack(alignment: .leading) { ForEach(availability.messages, id: \.self) { Text($0) } }
                }
                Picker("Model", selection: Binding(get: { model }, set: { value in
                    settings.updateAgentModeScalar(commit: true) { $0.computerUseModel = value }
                })) {
                    Text("GPT-6.1 Terra High").tag("codexExec:gpt-6.1-terra-high").disabled(!availability.terraAvailable)
                    Text("GPT-6.1 Sol High").tag("codexExec:gpt-6.1-sol-high")
                    if !["codexExec:gpt-6.1-terra-high", "codexExec:gpt-6.1-sol-high"].contains(model) {
                        Text(model).tag(model).disabled(true)
                    }
                }
                Text("Terra High recommended; Sol High for tasks that need deeper reasoning")
            }
            Section("Where it can run") {
                Toggle("Codex chats", isOn: Binding(
                    // Display the remembered legacy/environment row even while the master vetoes execution.
                    get: { CodexComputerUseWorkflow.isEnabled(persistedValue: preferences?.codexComputerUseEnabled, master: nil) },
                    set: onDirectChange
                ))
                Toggle("Other chats (Claude, Devin, …) — through a \"Computer Use\" subagent", isOn: Binding(
                    get: { preferences?.computerUseSubagentEnabled ?? false },
                    set: { value in settings.updateAgentModeScalar(commit: true) { $0.computerUseSubagentEnabled = value } }
                ))
            }
            .disabled(!settings.computerUseMasterEnabled)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                Text("Computer Use needs to be enabled for each chat by typing /computer-use or clicking the \(Image(systemName: "desktopcomputer")) icon.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .task {
            let selection = CodexRuntimePreferences.activeSelection
            await availability.refresh {
                await Task.detached(priority: .utility) {
                    (ComputerUseAvailability.read(selection: selection), AgentCodexModelRegistry.shared.resolvedOptions(staticOptions: []).contains { $0.rawValue == "gpt-6.1-terra-high" })
                }.value
            }
        }
        .onDisappear { availability.invalidate() }
    }
}
