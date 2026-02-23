import Foundation

/// Tracks per-pack artifacts installed into a project, enabling clean removal
/// when a pack is deselected during `mcs configure`.
struct PackArtifactRecord: Codable, Equatable, Sendable {
    /// MCP servers registered for this pack (name + scope for `claude mcp remove`).
    var mcpServers: [MCPServerRef] = []
    /// Project-relative paths of files installed by this pack.
    var files: [String] = []
    /// Section identifiers contributed to CLAUDE.local.md.
    var templateSections: [String] = []
    /// Hook commands registered in settings.local.json.
    var hookCommands: [String] = []
    /// Settings keys contributed by this pack.
    var settingsKeys: [String] = []
}

/// Reference to a registered MCP server for later removal.
struct MCPServerRef: Codable, Equatable, Sendable {
    var name: String
    var scope: String
}

/// Per-project state stored at `<project>/.claude/.mcs-project`.
/// Tracks which tech packs have been configured for this specific project,
/// along with per-pack artifact records for convergence.
struct ProjectState {
    private let path: URL
    private var storage: StateStorage

    /// JSON-backed storage model.
    private struct StateStorage: Codable {
        var mcsVersion: String?
        var configuredAt: String?
        var configuredPacks: [String] = []
        var packArtifacts: [String: PackArtifactRecord] = [:]
    }

    init(projectRoot: URL) {
        self.path = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
        self.storage = StateStorage()
        load()
    }

    /// Whether the state file exists on disk.
    var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// The set of pack identifiers configured for this project.
    var configuredPacks: Set<String> {
        Set(storage.configuredPacks)
    }

    /// Record that a pack was configured for this project.
    mutating func recordPack(_ identifier: String) {
        if !storage.configuredPacks.contains(identifier) {
            storage.configuredPacks.append(identifier)
            storage.configuredPacks.sort()
        }
    }

    /// Remove a pack from the configured list.
    mutating func removePack(_ identifier: String) {
        storage.configuredPacks.removeAll { $0 == identifier }
        storage.packArtifacts.removeValue(forKey: identifier)
    }

    /// The MCS version that last wrote this file.
    var mcsVersion: String? {
        storage.mcsVersion
    }

    // MARK: - Pack Artifacts

    /// Get the artifact record for a pack, if any.
    func artifacts(for packID: String) -> PackArtifactRecord? {
        storage.packArtifacts[packID]
    }

    /// Set the artifact record for a pack.
    mutating func setArtifacts(_ record: PackArtifactRecord, for packID: String) {
        storage.packArtifacts[packID] = record
    }

    // MARK: - Persistence

    /// Save to disk. Updates internal state with timestamp and version.
    mutating func save() throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        storage.configuredAt = ISO8601DateFormatter().string(from: Date())
        storage.mcsVersion = MCSVersion.current

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storage)
        try data.write(to: path)
    }

    /// Non-nil if `load()` encountered an error reading an existing file.
    /// Callers can check this to distinguish "file doesn't exist" from "file is corrupt/unreadable".
    private(set) var loadError: Error?

    // MARK: - Private

    private mutating func load() {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let data = try Data(contentsOf: path)
            // Try JSON first (new format)
            if data.first == UInt8(ascii: "{") {
                storage = try JSONDecoder().decode(StateStorage.self, from: data)
            } else {
                // Legacy flat key=value format — migrate
                migrateLegacyFormat(data)
            }
        } catch {
            self.loadError = error
        }
    }

    /// Parse the old `KEY=VALUE` format into the new JSON model.
    private mutating func migrateLegacyFormat(_ data: Data) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        var legacy: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
            let value = String(trimmed[trimmed.index(after: eqIndex)...])
            legacy[key] = value
        }

        if let packs = legacy["CONFIGURED_PACKS"], !packs.isEmpty {
            storage.configuredPacks = packs.components(separatedBy: ",").sorted()
        }
        storage.mcsVersion = legacy["MCS_VERSION"]
        storage.configuredAt = legacy["CONFIGURED_AT"]
    }
}
