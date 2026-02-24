import Foundation

/// Centralized path containment and relative-path utilities.
///
/// All security-sensitive path-boundary checks go through this single implementation
/// to prevent divergence across call sites.
enum PathContainment {
    /// Check if `path` is equal to or a child of `base`.
    /// Both inputs should already be symlink-resolved if symlink safety matters.
    static func isContained(path: String, within base: String) -> Bool {
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        return path == base || path.hasPrefix(normalizedBase)
    }

    /// Check if `url` is contained within `baseURL` after resolving symlinks.
    static func isContained(url: URL, within baseURL: URL) -> Bool {
        let resolvedPath = url.resolvingSymlinksInPath().path
        let resolvedBase = baseURL.resolvingSymlinksInPath().path
        return isContained(path: resolvedPath, within: resolvedBase)
    }

    /// Compute the relative path of `full` within `base`.
    /// Returns the original path unchanged if it is not within `base`.
    static func relativePath(of full: String, within base: String) -> String {
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        if full.hasPrefix(normalizedBase) {
            return String(full.dropFirst(normalizedBase.count))
        }
        return full
    }
}
