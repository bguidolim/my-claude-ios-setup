import Foundation
import CryptoKit

/// Tracks SHA-256 hashes of installed files, installed pack IDs, and metadata.
/// Stored at ~/.claude/.mcs-manifest.
struct Manifest: Sendable {
    private let path: URL
    private var entries: [String: String] // relativePath -> sha256
    private var metadata: [String: String] // key=value pairs that aren't file hashes

    init(path: URL) {
        self.path = path
        self.entries = [:]
        self.metadata = [:]
        self.load()
    }

    // MARK: - Public API

    /// Record the hash of a source file.
    mutating func record(relativePath: String, sourceFile: URL) throws {
        let hash = try Self.sha256(of: sourceFile)
        entries[relativePath] = hash
    }

    /// Check if an installed file matches its recorded hash.
    /// Returns nil if no record exists, true if matching, false if drifted.
    func check(relativePath: String, installedFile: URL) -> Bool? {
        guard let recorded = entries[relativePath] else { return nil }
        guard let current = try? Self.sha256(of: installedFile) else { return nil }
        return recorded == current
    }

    /// All tracked relative paths.
    var trackedPaths: [String] {
        Array(entries.keys).sorted()
    }

    /// The SCRIPT_DIR recorded in the manifest (points to the source repo).
    var scriptDir: String? {
        metadata["SCRIPT_DIR"]
    }

    /// Whether this manifest was created by the old bash installer.
    /// The bash installer recorded SCRIPT_DIR pointing to a directory containing setup.sh.
    var isLegacyBashManifest: Bool {
        guard let dir = scriptDir else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: dir).appendingPathComponent("setup.sh").path
        )
    }

    /// The tech pack identifiers that were explicitly installed.
    var installedPacks: Set<String> {
        guard let raw = metadata["INSTALLED_PACKS"], !raw.isEmpty else { return [] }
        return Set(raw.components(separatedBy: ","))
    }

    /// Record that a pack was installed.
    mutating func recordInstalledPack(_ identifier: String) {
        var packs = installedPacks
        packs.insert(identifier)
        metadata["INSTALLED_PACKS"] = packs.sorted().joined(separator: ",")
    }

    /// Initialize the manifest with a source directory header.
    mutating func initialize(sourceDirectory: String) {
        let previousPacks = metadata["INSTALLED_PACKS"]
        metadata["SCRIPT_DIR"] = sourceDirectory
        entries = [:]
        // Preserve installed packs across re-initialization
        if let previousPacks {
            metadata["INSTALLED_PACKS"] = previousPacks
        }
    }

    /// Save to disk.
    func save() throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var lines: [String] = []
        // Write metadata first
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)=\(value)")
        }
        // Then file entries
        for (path, hash) in entries.sorted(by: { $0.key < $1.key }) {
            lines.append("\(path)=\(hash)")
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: self.path, atomically: true, encoding: .utf8)
    }

    // MARK: - Internal

    /// Known metadata key names. Everything else is treated as a file hash entry.
    private static let metadataKeys: Set<String> = ["SCRIPT_DIR", "INSTALLED_PACKS"]

    private mutating func load() {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
            let value = String(trimmed[trimmed.index(after: eqIndex)...])

            if Self.metadataKeys.contains(key) {
                metadata[key] = value
            } else {
                entries[key] = value
            }
        }
    }

    /// Compute SHA-256 hash of a file.
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
