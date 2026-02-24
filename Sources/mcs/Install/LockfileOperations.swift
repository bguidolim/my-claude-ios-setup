import ArgumentParser
import Foundation

/// Shared lockfile operations used by SyncCommand and ConfigureCommand.
struct LockfileOperations {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner

    /// Checkout exact pack versions from the lockfile.
    func checkoutLockedVersions(at projectPath: URL) throws {
        guard let lockfile = try Lockfile.load(projectRoot: projectPath) else {
            output.error("No mcs.lock.yaml found. Run 'mcs sync' first to create one.")
            throw ExitCode.failure
        }

        output.info("Checking out locked pack versions...")

        for locked in lockfile.packs {
            let packPath = environment.packsDirectory.appendingPathComponent(locked.identifier)
            guard FileManager.default.fileExists(atPath: packPath.path) else {
                output.warn("Pack '\(locked.identifier)' not found locally. Run 'mcs pack add \(locked.sourceURL)' first.")
                continue
            }

            let result = shell.run(
                "/usr/bin/git",
                arguments: ["-C", packPath.path, "checkout", locked.commitSHA]
            )
            if result.succeeded {
                output.success("  \(locked.identifier): checked out \(String(locked.commitSHA.prefix(7)))")
            } else {
                // Shallow-fetch latest, then retry checkout
                _ = shell.run(
                    "/usr/bin/git",
                    arguments: ["-C", packPath.path, "fetch", "--depth", "1", "origin"]
                )
                let retry = shell.run(
                    "/usr/bin/git",
                    arguments: ["-C", packPath.path, "checkout", locked.commitSHA]
                )
                if retry.succeeded {
                    output.success("  \(locked.identifier): fetched and checked out \(String(locked.commitSHA.prefix(7)))")
                } else {
                    output.warn("  \(locked.identifier): failed to checkout \(String(locked.commitSHA.prefix(7)))")
                }
            }
        }
    }

    /// Fetch latest versions for all registered packs.
    func updatePacks() throws {
        let registryFile = PackRegistryFile(path: environment.packsRegistry)
        let registryData = try registryFile.load()

        if registryData.packs.isEmpty {
            output.info("No packs registered. Nothing to update.")
            return
        }

        output.info("Fetching latest pack versions...")
        let fetcher = PackFetcher(
            shell: shell,
            output: output,
            packsDirectory: environment.packsDirectory
        )

        var updatedData = registryData
        for entry in registryData.packs {
            let packPath = environment.packsDirectory.appendingPathComponent(entry.localPath)
            do {
                if let result = try fetcher.update(packPath: packPath, ref: entry.ref) {
                    let loader = ExternalPackLoader(environment: environment, registry: registryFile)
                    if let manifest = try? loader.validate(at: packPath) {
                        let updatedEntry = PackRegistryFile.PackEntry(
                            identifier: entry.identifier,
                            displayName: manifest.displayName,
                            version: manifest.version,
                            sourceURL: entry.sourceURL,
                            ref: entry.ref,
                            commitSHA: result.commitSHA,
                            localPath: entry.localPath,
                            addedAt: entry.addedAt,
                            trustedScriptHashes: entry.trustedScriptHashes
                        )
                        registryFile.register(updatedEntry, in: &updatedData)
                        output.success("  \(entry.identifier): updated to v\(manifest.version) (\(String(result.commitSHA.prefix(7))))")
                    }
                } else {
                    output.dimmed("  \(entry.identifier): already up to date")
                }
            } catch {
                output.warn("  \(entry.identifier): fetch failed — \(error.localizedDescription)")
            }
        }

        try registryFile.save(updatedData)
    }

    /// Write the lockfile after a successful sync.
    func writeLockfile(at projectPath: URL) throws {
        let registryFile = PackRegistryFile(path: environment.packsRegistry)
        let registryData = try registryFile.load()

        let projectState = ProjectState(projectRoot: projectPath)
        let configuredIDs = projectState.configuredPacks

        guard !configuredIDs.isEmpty else { return }

        if let existing = try Lockfile.load(projectRoot: projectPath) {
            let mismatches = existing.detectMismatches(registryEntries: registryData.packs)
            for mismatch in mismatches {
                if let currentSHA = mismatch.currentSHA {
                    output.warn("Pack '\(mismatch.identifier)' is at \(String(currentSHA.prefix(7))) but lockfile expected \(String(mismatch.lockedSHA.prefix(7))).")
                }
            }
        }

        let lockfile = Lockfile.generate(
            registryEntries: registryData.packs,
            selectedPackIDs: configuredIDs
        )
        try lockfile.save(projectRoot: projectPath)
        output.success("Updated mcs.lock.yaml")
    }
}
