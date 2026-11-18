import Darwin
import Foundation
import OSLog
import RepoPromptProcess
import RepoPromptSecureStorage

enum CodexChromePluginProvisioning {
    static let pluginID = "chrome@openai-bundled"
    static let serverName = "node_repl"
    static let disabledPluginKey = "plugins.\"chrome@openai-bundled\".enabled"
    private static let marketplacePath = ".tmp/bundled-marketplaces/openai-bundled"
    private static let logger = Logger(subsystem: "com.repoprompt", category: "CodexChromePlugin")
    private static let installationPath = "plugins/cache/openai-bundled/chrome"

    enum Failure: Error {
        case unavailableMarketplace
        case installFailed
        case invalidInstallation
        case existingInstallationMismatch
    }

    static func prepare(runtime: CodexRuntimeAuthority.Runtime) async -> Bool {
        let executable = runtime.executableURL
        let home = runtime.statePaths.codexHome
        guard runtime.version == CodexRuntimeAuthority.bundledVersion else {
            logger.notice("Chrome unavailable: unsupported Codex runtime version")
            return false
        }
        return await Task.detached(priority: .utility) {
            do {
                try ProviderProcessLaunchPolicy.check()
                guard CodexComputerUseWorkflow.runtimeUnavailableMessage(executableURL: executable) == nil else {
                    throw Failure.installFailed
                }
                let manager = FileManager.default
                let applications = [URL(fileURLWithPath: "/Applications"), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
                let source = applications.flatMap { directory in
                    ["ChatGPT.app", "Codex.app"].map { directory.appendingPathComponent($0) }
                }.first { bundle in
                    manager.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/plugins/openai-bundled/.agents/plugins/marketplace.json").path)
                        && RuntimeCodeSigningDetector.validatesStaticCode(at: bundle, requirementSource: CodexComputerUseWorkflow.openAISigningRequirement)
                }
                guard let source else { throw Failure.unavailableMarketplace }
                try stageAndPromote(
                    marketplace: source.appendingPathComponent("Contents/Resources/plugins/openai-bundled"),
                    destinationHome: home
                ) { staging in
                    try install(using: executable, stagingHome: staging)
                }
                return true
            } catch {
                logger.notice("Chrome unavailable: bundled marketplace installation or compatibility check failed")
                return false
            }
        }.value
    }

    static func matchesOwnedTransport(_ effective: [String: Any], owned: [String: CodexUserMCPImportValidation.Value]) -> Bool {
        let keys = ["command", "args", "env", "env_vars", "cwd", "url", "environment_id"]
        let live = normalizedTransport(effective, keys: keys)
        let approved = normalizedTransport(owned.mapValues(jsonValue), keys: keys)
        return NSDictionary(dictionary: live).isEqual(to: approved)
    }

    private static func normalizedTransport(_ definition: [String: Any], keys: [String]) -> [String: Any] {
        definition.filter { key, value in
            keys.contains(key) && !(value is NSNull)
                && (value as? [Any])?.isEmpty != true && (value as? [String: Any])?.isEmpty != true
        }
    }

    private static func jsonValue(_ value: CodexUserMCPImportValidation.Value) -> Any {
        switch value {
        case let .string(value): value
        case let .boolean(value): value
        case let .number(value, _): value
        case let .array(values): values.map(jsonValue)
        case let .object(values): values.mapValues(jsonValue)
        }
    }

    static func threadOverrides(config: [String: Any], armedDirect: Bool, approved: Bool, installed: Bool) -> [String: Any] {
        guard armedDirect, approved, installed,
              let servers = config["mcp_servers"] as? [String: Any],
              let server = servers[serverName] as? [String: Any],
              let command = server["command"] as? String, command.hasPrefix("/"),
              server["url"] == nil || server["url"] is NSNull,
              (server["tools"] as? [String: Any])?.isEmpty != false
        else { return [:] }

        var overrides: [String: Any] = [
            "features.plugins": true,
            "features.plugin_hooks": false,
            "features.remote_plugin": false,
            "plugins._default.enabled": false,
            disabledPluginKey: true,
            "mcp_servers.node_repl.enabled": true,
            "mcp_servers.node_repl.env.BROWSER_USE_AVAILABLE_BACKENDS": "chrome",
            "mcp_servers.node_repl.default_tools_approval_mode": "prompt"
        ]
        if let plugins = config["plugins"] as? [String: Any] {
            for id in plugins.keys where id != pluginID && id != "_default" {
                let component = CodexIntegrationConfiguration.cliPathComponent(forNormalizedServerName: id)
                overrides["plugins.\(component).enabled"] = false
            }
        }
        return overrides
    }

    static func logUnavailableGrant() {
        logger.notice("Chrome unavailable: node_repl is missing, unapproved, or incompatible")
    }

    static func stageAndPromote(marketplace: URL, destinationHome: URL, install: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let stagedMarketplace = staging.appendingPathComponent(marketplacePath, isDirectory: true)
        try manager.createDirectory(at: stagedMarketplace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: marketplace, to: stagedMarketplace)
        let source = try JSONEncoder().encode(stagedMarketplace.path)
        guard let quotedPath = String(data: source, encoding: .utf8) else { throw Failure.installFailed }
        let config = "[marketplaces.openai-bundled]\nsource_type = \"local\"\nsource = \(quotedPath.replacingOccurrences(of: "\\/", with: "/"))\n"
        try config.write(to: staging.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try install(staging)
        try promote(stagingHome: staging, destinationHome: destinationHome)
    }

    private static func install(using executable: URL, stagingHome: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["plugin", "add", pluginID]
        process.currentDirectoryURL = stagingHome
        process.environment = [
            "CODEX_HOME": stagingHome.path,
            "CODEX_SQLITE_HOME": stagingHome.path,
            "HOME": stagingHome.path,
            "PATH": "/usr/bin:/bin"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw Failure.installFailed
        }
        guard process.terminationStatus == 0 else { throw Failure.installFailed }
    }

    /// Promote only an installer-produced cache. The installer's config contains a persistent grant.
    static func promote(stagingHome: URL, destinationHome: URL) throws {
        let manager = FileManager.default
        let source = stagingHome.appendingPathComponent(installationPath, isDirectory: true)
        let installed = try installation(in: source)
        let destination = destinationHome.appendingPathComponent(installationPath, isDirectory: true)
        let parent = destination.deletingLastPathComponent()
        let root = destinationHome.resolvingSymlinksInPath()
        var cacheDirectory = root
        for component in ["plugins", "cache", "openai-bundled"] {
            cacheDirectory.appendPathComponent(component, isDirectory: true)
            do {
                try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: false)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try requireDirectory(cacheDirectory)
            }
        }
        if manager.fileExists(atPath: destination.path) {
            try verifyExisting(destination, matches: installed)
            return
        }

        let pending = parent.appendingPathComponent(".chrome-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: pending) }
        try manager.copyItem(at: source, to: pending)
        do {
            try manager.moveItem(at: pending, to: destination)
        } catch {
            // Another controller may have promoted the same installation first.
            guard manager.fileExists(atPath: destination.path) else { throw error }
            try verifyExisting(destination, matches: installed)
        }
    }

    private static func verifyExisting(_ destination: URL, matches expected: Installation) throws {
        guard try installation(in: destination) == expected else {
            throw Failure.existingInstallationMismatch
        }
    }

    private struct Installation: Equatable {
        let directory: String
        let files: [String: Data]
    }

    private static func installation(in directory: URL) throws -> Installation {
        let manager = FileManager.default
        try requireDirectory(directory)
        let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count == 1, let version = children.first,
              version.lastPathComponent.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                      || [43, 45, 46, 95].contains($0)
              })
        else {
            throw Failure.invalidInstallation
        }
        try requireDirectory(version)
        let manifestDirectory = version.appendingPathComponent(".codex-plugin", isDirectory: true)
        try requireDirectory(manifestDirectory)
        let manifestURL = manifestDirectory.appendingPathComponent("plugin.json")
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, size <= 256 * 1024
        else {
            throw Failure.invalidInstallation
        }
        let manifest = try Data(contentsOf: manifestURL)
        guard let metadata = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              metadata["name"] as? String == "chrome"
        else {
            throw Failure.invalidInstallation
        }
        var files: [String: Data] = [:]
        try collectFiles(in: version, relativeTo: version, files: &files)
        return Installation(directory: version.lastPathComponent, files: files)
    }

    private static func collectFiles(in directory: URL, relativeTo root: URL, files: inout [String: Data]) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            let values = try child.resourceValues(forKeys: keys)
            guard values.isSymbolicLink == false else { throw Failure.invalidInstallation }
            if values.isDirectory == true {
                try collectFiles(in: child, relativeTo: root, files: &files)
            } else if values.isRegularFile == true {
                let path = String(child.path.dropFirst(root.path.count + 1))
                files[path] = try Data(contentsOf: child, options: .mappedIfSafe)
            } else {
                throw Failure.invalidInstallation
            }
        }
    }

    private static func requireDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw Failure.invalidInstallation
        }
    }
}
