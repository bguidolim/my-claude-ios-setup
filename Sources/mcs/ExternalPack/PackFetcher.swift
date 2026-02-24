import Foundation

/// Git clone/fetch operations for external tech packs.
struct PackFetcher: Sendable {
    let shell: ShellRunner
    let output: CLIOutput
    let packsDirectory: URL // ~/.mcs/packs/

    struct FetchResult: Sendable {
        let localPath: URL     // Where the pack was cloned to
        let commitSHA: String  // The checked-out commit
        let ref: String?       // The tag/branch if specified
    }

    // MARK: - Fetch (Clone)

    /// Clone a pack repo to `~/.mcs/packs/<identifier>/`.
    /// If `ref` is specified, check out that ref (tag, branch, or commit).
    /// If the pack directory already exists, it is removed first for a clean state.
    func fetch(url: String, identifier: String, ref: String?) throws -> FetchResult {
        try ensureGitAvailable()
        try ensurePacksDirectory()

        let packPath = packsDirectory.appendingPathComponent(identifier)

        // Clean state: remove existing checkout if present
        let fm = FileManager.default
        if fm.fileExists(atPath: packPath.path) {
            try fm.removeItem(at: packPath)
        }

        // Clone
        var args = ["clone", "--depth", "1"]
        if let ref {
            args += ["--branch", ref]
        }
        args += [url, packPath.path]

        let result = shell.run("/usr/bin/git", arguments: args)
        guard result.succeeded else {
            throw PackFetchError.cloneFailed(url: url, stderr: result.stderr)
        }

        let commitSHA = try currentCommit(at: packPath)

        return FetchResult(
            localPath: packPath,
            commitSHA: commitSHA,
            ref: ref
        )
    }

    // MARK: - Update

    /// Update an existing pack checkout.
    /// Returns a `FetchResult` if updated, or `nil` if already at the latest commit.
    func update(packPath: URL, ref: String?) throws -> FetchResult? {
        try ensureGitAvailable()

        let beforeSHA = try currentCommit(at: packPath)
        let workDir = packPath.path

        // Fetch latest from remote
        let fetchResult = shell.run(
            "/usr/bin/git", arguments: ["fetch", "--depth", "1", "origin"],
            workingDirectory: workDir
        )
        guard fetchResult.succeeded else {
            throw PackFetchError.fetchFailed(path: packPath.path, stderr: fetchResult.stderr)
        }

        if let ref {
            // Check out the specific ref
            let checkoutResult = shell.run(
                "/usr/bin/git", arguments: ["checkout", ref],
                workingDirectory: workDir
            )
            if !checkoutResult.succeeded {
                // Try fetching the ref explicitly (e.g. a new tag)
                let fetchTagResult = shell.run(
                    "/usr/bin/git", arguments: ["fetch", "--depth", "1", "origin", "tag", ref],
                    workingDirectory: workDir
                )
                guard fetchTagResult.succeeded else {
                    throw PackFetchError.refNotFound(ref: ref, stderr: checkoutResult.stderr)
                }
                let retryCheckout = shell.run(
                    "/usr/bin/git", arguments: ["checkout", ref],
                    workingDirectory: workDir
                )
                guard retryCheckout.succeeded else {
                    throw PackFetchError.refNotFound(ref: ref, stderr: retryCheckout.stderr)
                }
            }
        } else {
            // Tracking default branch — reset to remote HEAD
            let resetResult = shell.run(
                "/usr/bin/git", arguments: ["reset", "--hard", "origin/HEAD"],
                workingDirectory: workDir
            )
            guard resetResult.succeeded else {
                throw PackFetchError.updateFailed(path: packPath.path, stderr: resetResult.stderr)
            }
        }

        let afterSHA = try currentCommit(at: packPath)

        if afterSHA == beforeSHA {
            return nil // Already at latest
        }

        return FetchResult(
            localPath: packPath,
            commitSHA: afterSHA,
            ref: ref
        )
    }

    // MARK: - Current Commit

    /// Get the current commit SHA of a pack checkout.
    func currentCommit(at path: URL) throws -> String {
        let result = shell.run(
            "/usr/bin/git", arguments: ["rev-parse", "HEAD"],
            workingDirectory: path.path
        )
        guard result.succeeded, !result.stdout.isEmpty else {
            throw PackFetchError.commitResolutionFailed(path: path.path, stderr: result.stderr)
        }
        return result.stdout
    }

    // MARK: - Remove

    /// Remove a pack's local checkout.
    func remove(packPath: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packPath.path) else { return }
        try fm.removeItem(at: packPath)
    }

    // MARK: - Helpers

    private func ensureGitAvailable() throws {
        guard shell.commandExists("git") else {
            throw PackFetchError.gitNotInstalled
        }
    }

    private func ensurePacksDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: packsDirectory.path) {
            try fm.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Errors

/// Errors that can occur during pack fetch operations.
enum PackFetchError: Error, LocalizedError, Sendable {
    case gitNotInstalled
    case cloneFailed(url: String, stderr: String)
    case fetchFailed(path: String, stderr: String)
    case refNotFound(ref: String, stderr: String)
    case updateFailed(path: String, stderr: String)
    case commitResolutionFailed(path: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case .gitNotInstalled:
            return "Git is not installed. Please install git to manage external packs."
        case .cloneFailed(let url, let stderr):
            return "Failed to clone '\(url)': \(stderr)"
        case .fetchFailed(let path, let stderr):
            return "Failed to fetch updates for '\(path)': \(stderr)"
        case .refNotFound(let ref, let stderr):
            return "Ref '\(ref)' not found: \(stderr)"
        case .updateFailed(let path, let stderr):
            return "Failed to update '\(path)': \(stderr)"
        case .commitResolutionFailed(let path, let stderr):
            return "Failed to resolve commit at '\(path)': \(stderr)"
        }
    }
}
