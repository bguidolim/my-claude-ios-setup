import Foundation

/// Detects the project root by walking up from a starting directory.
/// Looks for `.git/` or `CLAUDE.local.md` as project root indicators.
enum ProjectDetector {
    /// Walk up from `startingAt` looking for a project root marker.
    /// Returns the first ancestor directory containing `.git/` or `CLAUDE.local.md`, or nil.
    static func findProjectRoot(from startingPath: URL) -> URL? {
        let fm = FileManager.default
        var current = startingPath.standardizedFileURL

        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            if fm.fileExists(atPath: current.appendingPathComponent(Constants.FileNames.claudeLocalMD).path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Convenience: find project root from the current working directory.
    static func findProjectRoot() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return findProjectRoot(from: cwd)
    }
}
