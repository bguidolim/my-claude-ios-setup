import ArgumentParser
import Foundation

/// Shared lockfile operations used by SyncCommand.
struct LockfileOperations {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner

    /// Checkout exact pack versions from the lockfile.
    /// Aborts if any checkout fails, since `--lock` guarantees reproducibility.
    func checkoutLockedVersions(at projectPath: URL) throws {
        guard let lockfile = try Lockfile.load(projectRoot: projectPath) else {
            output.error("No mcs.lock.yaml found. Run 'mcs sync' first to create one.")
            throw ExitCode.failure
        }

        output.info("Checking out locked pack versions...")

        var failedPacks: [String] = []
        for locked in lockfile.packs {
            // Validate commit SHA is a valid hex string (defense against flag injection)
            guard locked.commitSHA.range(of: #"^[0-9a-f]{7,64}$"#, options: .regularExpression) != nil else {
                output.warn("  \(locked.identifier): invalid commit SHA '\(locked.commitSHA)'")
                failedPacks.append(locked.identifier)
                continue
            }

            guard let packPath = PathContainment.safePath(
                relativePath: locked.identifier,
                within: environment.packsDirectory
            ) else {
                output.warn("  \(locked.identifier): identifier escapes packs directory — skipping")
                failedPacks.append(locked.identifier)
                continue
            }

            guard FileManager.default.fileExists(atPath: packPath.path) else {
                output.warn("  Pack '\(locked.identifier)' not found locally. Run 'mcs pack add \(locked.sourceURL)' first.")
                failedPacks.append(locked.identifier)
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
                    failedPacks.append(locked.identifier)
                }
            }
        }

        if !failedPacks.isEmpty {
            output.error("Failed to checkout locked versions for: \(failedPacks.joined(separator: ", "))")
            output.error("Sync aborted to prevent inconsistent configuration.")
            throw ExitCode.failure
        }
    }

    /// Fetch latest versions for all registered packs.
    /// Re-validates trust when scripts change (mirrors `mcs pack update` behavior).
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
        let trustManager = PackTrustManager(output: output)

        var updatedData = registryData
        for entry in registryData.packs {
            guard let packPath = PathContainment.safePath(
                relativePath: entry.localPath,
                within: environment.packsDirectory
            ) else {
                output.warn("  \(entry.identifier): localPath escapes packs directory — skipping")
                continue
            }

            do {
                if let result = try fetcher.update(packPath: packPath, ref: entry.ref) {
                    let loader = ExternalPackLoader(environment: environment, registry: registryFile)
                    let manifest: ExternalPackManifest
                    do {
                        manifest = try loader.validate(at: packPath)
                    } catch {
                        output.warn("  \(entry.identifier): updated but manifest is invalid — \(error.localizedDescription)")
                        continue
                    }

                    // Check for new/modified scripts requiring re-trust
                    var scriptHashes = entry.trustedScriptHashes
                    let newItems = try trustManager.detectNewScripts(
                        currentHashes: entry.trustedScriptHashes,
                        updatedPackPath: packPath,
                        manifest: manifest
                    )
                    if !newItems.isEmpty {
                        output.warn("  \(entry.displayName) has new or modified scripts:")
                        let decision = try trustManager.promptForTrust(
                            manifest: manifest,
                            packPath: packPath,
                            items: newItems
                        )
                        guard decision.approved else {
                            output.info("  \(entry.displayName): update skipped (trust not granted)")
                            continue
                        }
                        for (path, hash) in decision.scriptHashes {
                            scriptHashes[path] = hash
                        }
                    }

                    let updatedEntry = PackRegistryFile.PackEntry(
                        identifier: entry.identifier,
                        displayName: manifest.displayName,
                        version: manifest.version,
                        sourceURL: entry.sourceURL,
                        ref: entry.ref,
                        commitSHA: result.commitSHA,
                        localPath: entry.localPath,
                        addedAt: entry.addedAt,
                        trustedScriptHashes: scriptHashes
                    )
                    registryFile.register(updatedEntry, in: &updatedData)
                    output.success("  \(entry.identifier): updated to v\(manifest.version) (\(String(result.commitSHA.prefix(7))))")
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

        let projectState = try ProjectState(projectRoot: projectPath)
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
