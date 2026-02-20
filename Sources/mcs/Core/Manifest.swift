import Foundation
import CryptoKit

/// Tracks SHA-256 hashes of installed files to detect drift.
/// Stored at ~/.claude/.setup-manifest.
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

    /// Initialize the manifest with a source directory header.
    mutating func initialize(sourceDirectory: String) {
        metadata["SCRIPT_DIR"] = sourceDirectory
        entries = [:]
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

    private mutating func load() {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
            let value = String(trimmed[trimmed.index(after: eqIndex)...])

            // Metadata keys are uppercase (e.g. SCRIPT_DIR)
            if key == key.uppercased() && key.contains("_") {
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
