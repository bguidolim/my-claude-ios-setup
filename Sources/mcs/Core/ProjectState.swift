import Foundation

/// Per-project state stored at `<project>/.claude/.mcs-project`.
/// Tracks which tech packs have been configured for this specific project.
struct ProjectState {
    private let path: URL
    private var data: [String: String]

    init(projectRoot: URL) {
        self.path = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
        self.data = [:]
        load()
    }

    /// Whether the state file exists on disk.
    var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// The set of pack identifiers configured for this project.
    var configuredPacks: Set<String> {
        guard let raw = data["CONFIGURED_PACKS"], !raw.isEmpty else { return [] }
        return Set(raw.components(separatedBy: ","))
    }

    /// Record that a pack was configured for this project.
    mutating func recordPack(_ identifier: String) {
        var packs = configuredPacks
        packs.insert(identifier)
        data["CONFIGURED_PACKS"] = packs.sorted().joined(separator: ",")
    }

    /// The MCS version that last wrote this file.
    var mcsVersion: String? {
        data["MCS_VERSION"]
    }

    /// Save to disk. Updates internal state with timestamp and version.
    mutating func save() throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        data["CONFIGURED_AT"] = ISO8601DateFormatter().string(from: Date())
        data["MCS_VERSION"] = MCSVersion.current

        let lines = data
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Non-nil if `load()` encountered an error reading an existing file.
    /// Callers can check this to distinguish "file doesn't exist" from "file is corrupt/unreadable".
    private(set) var loadError: Error?

    // MARK: - Private

    private mutating func load() {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let content = try String(contentsOf: path, encoding: .utf8)
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[trimmed.startIndex..<eqIndex])
                let value = String(trimmed[trimmed.index(after: eqIndex)...])
                data[key] = value
            }
        } catch {
            self.loadError = error
        }
    }
}
