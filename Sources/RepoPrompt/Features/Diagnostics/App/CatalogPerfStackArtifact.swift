import Darwin
import Foundation

/// No raw report is ever written. This parser recognizes only sample's call-tree grammar;
/// metadata, thread labels, image/source paths, addresses and diagnostics are never copied.
enum CatalogPerfStackArtifact {
    static let maximumBytes = 64 * 1024
    static let filename = "last.stacks.txt"
    private static let staging = "pending.stacks.txt"

    static func symbols(from raw: Data) -> Data? {
        guard raw.count <= 1024 * 1024, let text = String(data: raw, encoding: .utf8) else { return nil }
        let record = try? NSRegularExpression(pattern: #"^([ |+!:]*)[0-9]+\s+(.+)$"#)
        let frame = try? NSRegularExpression(pattern: #"^(.+?)  \(in [^\r\n]+?\)(?: \+ [0-9]+(?:,[0-9]+)*|  load address 0x[0-9a-fA-F]+ \+ 0x[0-9a-fA-F]+)  \[0x[0-9a-fA-F]+(?:,\s*0x[0-9a-fA-F]+)*\](?:\s+(?:\([^()\r\n]+:[0-9]+(?::[0-9]+)?\)|[^\s()]+:[0-9]+(?::[0-9]+)?))?$"#)
        let thread = try? NSRegularExpression(pattern: #"^Thread_(?:[0-9]+|<multiple>)(?::.*| .*)?$"#)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$<>(), :?&!*+=#[]-@")
        var inTree = false
        var hasThread = false
        var ended = false
        var output = Data()
        var frames = 0
        for line in text.components(separatedBy: "\n") {
            guard line.utf8.count <= 8192 else { return nil }
            if line == "Call graph:" {
                guard !inTree, !ended else { return nil }
                inTree = true
                continue
            }
            guard inTree else { continue }
            if line.hasPrefix("Total number in stack") {
                inTree = false
                ended = true
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let row = record?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let payloadRange = Range(row.range(at: 2), in: line),
                  let indentationRange = Range(row.range(at: 1), in: line) else { return nil }
            let payload = String(line[payloadRange])
            let range = NSRange(payload.startIndex..., in: payload)
            // Classify metadata after stripping count and whitespace exactly once.
            if payload.hasPrefix("Thread_") {
                guard thread?.firstMatch(in: payload, range: range) != nil else { return nil }
                hasThread = true
                output.append(contentsOf: "stack\n".utf8)
            } else {
                guard hasThread, let match = frame?.firstMatch(in: payload, range: range),
                      let symbolRange = Range(match.range(at: 1), in: payload) else { return nil }
                let symbol = String(payload[symbolRange])
                // Unresolved frames contain no useful symbol, but still have to match the grammar.
                if symbol == "???" { continue }
                guard symbol.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                      symbol.range(of: "0x", options: .caseInsensitive) == nil,
                      symbol.range(of: #"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-"#, options: .regularExpression) == nil,
                      symbol.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
                // Preserve relative call depth. Discard sample counts and branch glyphs.
                let depth = line[indentationRange].count / 2
                guard depth <= 128 else { return nil }
                output.append(contentsOf: (String(repeating: " ", count: depth) + symbol + "\n").utf8)
                frames += 1
            }
            guard output.count <= maximumBytes else { return nil }
        }
        return ended && frames > 0 ? output : nil
    }

    enum Failure: Error { case unsafeArtifact }

    /// Fixed private cache: com.pvncher.repoprompt.ce/CatalogPerfStall/last.stacks.txt.
    /// One artifact + one staging file, each <=64 KiB. Descriptor-relative, no symlink following.
    static func replace(_ data: Data, caches: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.unsafeArtifact }
        let cache = open(caches.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cache >= 0 else { throw Failure.unsafeArtifact }
        defer { close(cache) }
        let namespace = try directory("com.pvncher.repoprompt.ce", parent: cache, privateMode: false)
        defer { close(namespace) }
        let folder = try directory("CatalogPerfStall", parent: namespace)
        defer { close(folder) }
        // Lock the existing directory inode: no extra file or cross-process staging collision.
        guard flock(folder, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unsafeArtifact }
        defer { flock(folder, LOCK_UN) }
        try validate(filename, parent: folder)
        try validate(staging, parent: folder)
        guard unlinkat(folder, staging, 0) == 0 || errno == ENOENT else { throw Failure.unsafeArtifact }
        let file = openat(folder, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw Failure.unsafeArtifact }
        defer {
            close(file)
            unlinkat(folder, staging, 0)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.unsafeArtifact }
                offset += count
            }
        }
        guard renameat(folder, staging, folder, filename) == 0 else { throw Failure.unsafeArtifact }
    }

    private static func directory(_ name: String, parent: Int32, privateMode: Bool = true) throws -> Int32 {
        guard mkdirat(parent, name, mode_t(0o700)) == 0 || errno == EEXIST else { throw Failure.unsafeArtifact }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeArtifact }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              privateMode ? info.st_mode & 0o777 == 0o700 : info.st_mode & 0o022 == 0
        else {
            close(descriptor)
            throw Failure.unsafeArtifact
        }
        return descriptor
    }

    private static func validate(_ name: String, parent: Int32) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.unsafeArtifact }
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size <= maximumBytes else { throw Failure.unsafeArtifact }
    }
}
