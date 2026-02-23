import CryptoKit
import Foundation

/// Pure CryptoKit utilities for SHA-256 file hashing.
/// Extracted from the deleted `Manifest` type — used by `PackTrustManager`
/// for trust verification and by `ComponentExecutor` for directory copies.
enum FileHasher {
    /// Compute SHA-256 hash of a file.
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute SHA-256 hashes for all regular files in a directory (recursive).
    /// Returns sorted (relativePath, hash) pairs where relativePath is relative to the directory.
    static func directoryFileHashes(at url: URL) throws -> [(relativePath: String, hash: String)] {
        let fm = FileManager.default
        // Resolve symlinks to ensure consistent path comparison
        // (macOS /var → /private/var, /tmp → /private/tmp)
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(
            at: resolvedURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MCSError.fileOperationFailed(
                path: resolvedURL.path,
                reason: "Could not enumerate directory contents"
            )
        }

        var results: [(relativePath: String, hash: String)] = []
        let basePath = resolvedURL.path.hasSuffix("/") ? resolvedURL.path : resolvedURL.path + "/"
        while let fileURL = enumerator.nextObject() as? URL {
            let resolvedFile = fileURL.resolvingSymlinksInPath()
            let resourceValues = try resolvedFile.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            let relativePath = String(resolvedFile.path.dropFirst(basePath.count))
            let hash = try sha256(of: resolvedFile)
            results.append((relativePath, hash))
        }
        return results.sorted { $0.relativePath < $1.relativePath }
    }
}
