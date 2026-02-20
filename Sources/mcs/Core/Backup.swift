import Foundation

/// Creates timestamped backups before overwriting files and tracks them for cleanup.
struct Backup {
    /// All backups created during this session.
    private(set) var createdBackups: [URL] = []

    /// Create a timestamped backup of the file at `path` if it exists.
    /// Returns the backup URL, or nil if the original file didn't exist.
    @discardableResult
    mutating func backupFile(at path: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let backupPath = URL(fileURLWithPath: "\(path.path).backup.\(timestamp)")

        try fm.copyItem(at: path, to: backupPath)
        createdBackups.append(backupPath)

        return backupPath
    }

    /// Find all backup files matching `*.backup.*` under the given directory.
    static func findBackups(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        var backups: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.contains(".backup.") {
                backups.append(url)
            }
        }
        return backups
    }

    /// Delete the given backup files. Returns paths that could not be deleted.
    @discardableResult
    static func deleteBackups(_ backups: [URL]) -> [URL] {
        let fm = FileManager.default
        var failures: [URL] = []
        for backup in backups {
            do {
                try fm.removeItem(at: backup)
            } catch {
                failures.append(backup)
            }
        }
        return failures
    }
}
