import Foundation

/// Handles the fetch → validate → trust cycle for updating a single git pack.
/// Used by both `UpdatePack` (interactive) and `LockfileOperations` (`--update`).
struct PackUpdater {
    let fetcher: PackFetcher
    let trustManager: PackTrustManager
    let environment: Environment
    let output: CLIOutput

    /// Result of attempting to update a single git pack.
    enum UpdateResult {
        case alreadyUpToDate
        case updated(PackRegistryFile.PackEntry)
        case skipped(String)
    }

    /// Fetch, validate, and re-trust a single git pack entry.
    /// The caller is responsible for skipping local packs and resolving the pack path.
    func updateGitPack(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        registry: PackRegistryFile
    ) -> UpdateResult {
        let fetchResult: PackFetcher.FetchResult?
        do {
            fetchResult = try fetcher.update(packPath: packPath, ref: entry.ref)
        } catch {
            return .skipped("fetch failed — \(error.localizedDescription)")
        }

        guard let result = fetchResult else {
            return .alreadyUpToDate
        }

        let loader = ExternalPackLoader(environment: environment, registry: registry)
        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: packPath)
        } catch {
            return .skipped("updated but manifest is invalid — \(error.localizedDescription)")
        }

        var scriptHashes = entry.trustedScriptHashes
        let newItems: [TrustableItem]
        do {
            newItems = try trustManager.detectNewScripts(
                currentHashes: entry.trustedScriptHashes,
                updatedPackPath: packPath,
                manifest: manifest
            )
        } catch {
            return .skipped("could not analyze scripts — \(error.localizedDescription)")
        }

        if !newItems.isEmpty {
            output.warn("\(entry.displayName) has new or modified scripts:")
            let decision: PackTrustManager.TrustDecision
            do {
                decision = try trustManager.promptForTrust(
                    manifest: manifest,
                    packPath: packPath,
                    items: newItems
                )
            } catch {
                return .skipped("trust verification failed — \(error.localizedDescription)")
            }
            guard decision.approved else {
                return .skipped("update skipped (trust not granted)")
            }
            for (path, hash) in decision.scriptHashes {
                scriptHashes[path] = hash
            }
        }

        let updatedEntry = PackRegistryFile.PackEntry(
            identifier: entry.identifier,
            displayName: manifest.displayName,
            author: manifest.author,
            version: manifest.version,
            sourceURL: entry.sourceURL,
            ref: entry.ref,
            commitSHA: result.commitSHA,
            localPath: entry.localPath,
            addedAt: entry.addedAt,
            trustedScriptHashes: scriptHashes,
            isLocal: entry.isLocal
        )

        return .updated(updatedEntry)
    }
}
