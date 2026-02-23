import ArgumentParser
import Foundation

struct PackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Manage external tech packs",
        subcommands: [AddPack.self, RemovePack.self, UpdatePack.self, ListPacks.self]
    )
}

// MARK: - Add

struct AddPack: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an external tech pack from a Git repository"
    )

    @Argument(help: "Git repository URL")
    var url: String

    @Option(name: .long, help: "Git tag, branch, or commit")
    var ref: String?

    @Flag(name: .long, help: "Preview pack contents without installing")
    var preview: Bool = false

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        // Validate URL to prevent git argument injection and restrict to safe protocols
        guard !url.hasPrefix("-") else {
            output.error("Invalid URL: must not start with '-'")
            throw ExitCode.failure
        }
        let allowedPrefixes = ["https://", "git@", "ssh://", "git://", "file://"]
        guard allowedPrefixes.contains(where: { url.hasPrefix($0) }) else {
            output.error("Invalid URL: must start with https://, git@, ssh://, git://, or file://")
            throw ExitCode.failure
        }
        if let ref, ref.hasPrefix("-") {
            output.error("Invalid ref: must not start with '-'")
            throw ExitCode.failure
        }

        let fetcher = PackFetcher(
            shell: shell,
            output: output,
            packsDirectory: env.packsDirectory
        )
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        // 1. Clone to a temporary location first
        output.info("Fetching pack from \(url)...")
        let tempID = "tmp-\(UUID().uuidString.prefix(8))"
        let fetchResult: PackFetcher.FetchResult
        do {
            fetchResult = try fetcher.fetch(url: url, identifier: tempID, ref: ref)
        } catch {
            output.error("Failed to fetch pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 2. Validate manifest
        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: fetchResult.localPath)
        } catch {
            // Clean up temp checkout
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Invalid pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        output.success("Found pack: \(manifest.displayName) v\(manifest.version)")

        // 3. Check for collisions with existing packs
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 3b. Check peer dependencies (warning only — peer packs may be added later)
        let peerResults = PeerDependencyValidator.validate(
            manifest: manifest,
            registeredPacks: registryData.packs
        )
        for result in peerResults where result.status != .satisfied {
            switch result.status {
            case .missing:
                output.warn("Pack '\(manifest.identifier)' requires peer pack '\(result.peerPack)' (>= \(result.minVersion)) which is not registered.")
                output.dimmed("  Install it with: mcs pack add <\(result.peerPack)-pack-url>")
            case .versionTooLow(let actual):
                output.warn("Pack '\(manifest.identifier)' requires peer pack '\(result.peerPack)' >= \(result.minVersion), but v\(actual) is registered.")
                output.dimmed("  Update it with: mcs pack update \(result.peerPack)")
            case .satisfied:
                break
            }
        }

        // Build collision input from loaded manifests for better detection
        let existingManifestInputs: [PackRegistryFile.CollisionInput] = registryData.packs.map { entry in
            let packPath = env.packsDirectory.appendingPathComponent(entry.localPath)
            let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
            guard let existingManifest = try? ExternalPackManifest.load(from: manifestURL) else {
                output.warn("Could not load manifest for '\(entry.identifier)', collision detection may be incomplete")
                return PackRegistryFile.CollisionInput(
                    identifier: entry.identifier,
                    mcpServerNames: [],
                    skillDirectories: [],
                    templateSectionIDs: [],
                    componentIDs: []
                )
            }
            return PackRegistryFile.CollisionInput(from: existingManifest)
        }

        let newInput = PackRegistryFile.CollisionInput(from: manifest)
        let collisions = registry.detectCollisions(
            newPack: newInput,
            existingPacks: existingManifestInputs
        )

        if !collisions.isEmpty {
            output.warn("Collisions detected with existing packs:")
            for collision in collisions {
                output.plain("  \(collision.type): '\(collision.artifactName)' conflicts with pack '\(collision.existingPackIdentifier)'")
            }
            if !output.askYesNo("Continue anyway?", default: false) {
                try? fetcher.remove(packPath: fetchResult.localPath)
                output.info("Pack not added.")
                return
            }
        }

        // 4. Display summary
        displayPackSummary(manifest: manifest, output: output)

        if preview {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.info("Preview complete. No changes made.")
            return
        }

        // 5. Trust verification
        let trustManager = PackTrustManager(output: output)
        let items: [TrustableItem]
        do {
            items = try trustManager.analyzeScripts(manifest: manifest, packPath: fetchResult.localPath)
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Failed to analyze pack scripts: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let decision: PackTrustManager.TrustDecision
        do {
            decision = try trustManager.promptForTrust(
                manifest: manifest,
                packPath: fetchResult.localPath,
                items: items
            )
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Trust verification failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard decision.approved else {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.info("Pack not trusted. No changes made.")
            return
        }

        // 6. Move from temp location to final location
        let finalPath = env.packsDirectory.appendingPathComponent(manifest.identifier)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: finalPath.path) {
                try fm.removeItem(at: finalPath)
            }
            try fm.moveItem(at: fetchResult.localPath, to: finalPath)
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Failed to move pack to final location: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 7. Register in pack registry
        let entry = PackRegistryFile.PackEntry(
            identifier: manifest.identifier,
            displayName: manifest.displayName,
            version: manifest.version,
            sourceURL: url,
            ref: ref,
            commitSHA: fetchResult.commitSHA,
            localPath: manifest.identifier,
            addedAt: ISO8601DateFormatter().string(from: Date()),
            trustedScriptHashes: decision.scriptHashes
        )

        do {
            var data = registryData
            registry.register(entry, in: &data)
            try registry.save(data)
        } catch {
            output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        output.success("Pack '\(manifest.displayName)' v\(manifest.version) added successfully.")
        output.plain("")
        output.info("Next step: run 'mcs install --pack \(manifest.identifier)' to install components.")
    }

    private func displayPackSummary(manifest: ExternalPackManifest, output: CLIOutput) {
        output.plain("")
        output.sectionHeader("Pack Summary")
        output.plain("  Identifier: \(manifest.identifier)")
        output.plain("  Version:    \(manifest.version)")
        output.plain("  \(manifest.description)")

        if let components = manifest.components, !components.isEmpty {
            output.plain("")
            output.plain("  Components (\(components.count)):")
            for component in components {
                output.plain("    - \(component.displayName) (\(component.type.rawValue))")
            }
        }

        if let templates = manifest.templates, !templates.isEmpty {
            output.plain("  Templates (\(templates.count)):")
            for template in templates {
                output.plain("    - \(template.sectionIdentifier)")
            }
        }

        if let hooks = manifest.hookContributions, !hooks.isEmpty {
            output.plain("  Hook contributions (\(hooks.count)):")
            for hook in hooks {
                output.plain("    - \(hook.hookName)")
            }
        }

        output.plain("")
    }
}

// MARK: - Remove

struct RemovePack: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an external tech pack"
    )

    @Argument(help: "Pack identifier to remove")
    var identifier: String

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        let registry = PackRegistryFile(path: env.packsRegistry)
        let fetcher = PackFetcher(
            shell: shell,
            output: output,
            packsDirectory: env.packsDirectory
        )

        // 1. Look up pack in registry
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard let entry = registry.pack(identifier: identifier, in: registryData) else {
            output.error("Pack '\(identifier)' is not installed.")
            throw ExitCode.failure
        }

        let packPath = env.packsDirectory.appendingPathComponent(entry.localPath)

        // 2. Load manifest from checkout (if available) to know what to reverse
        let manifest: ExternalPackManifest?
        if FileManager.default.fileExists(atPath: packPath.path) {
            let loader = ExternalPackLoader(
                environment: env,
                registry: registry
            )
            do {
                manifest = try loader.validate(at: packPath)
            } catch {
                output.warn("Could not read pack manifest: \(error.localizedDescription)")
                output.warn("Artifacts will not be cleaned up.")
                manifest = nil
            }
        } else {
            output.warn("Pack checkout missing at \(packPath.path)")
            output.warn("Artifacts will not be cleaned up.")
            manifest = nil
        }

        // 3. Show removal plan
        output.info("Pack: \(entry.displayName) v\(entry.version)")
        output.plain("  Source: \(entry.sourceURL)")
        output.plain("  Local:  ~/.claude/packs/\(entry.localPath)")
        if let manifest {
            let componentCount = manifest.components?.count ?? 0
            let hookCount = manifest.hookContributions?.count ?? 0
            let gitignoreCount = manifest.gitignoreEntries?.count ?? 0
            if componentCount + hookCount + gitignoreCount > 0 {
                output.plain("")
                output.plain("  Will remove:")
                if componentCount > 0 {
                    output.plain("    \(componentCount) component(s)")
                }
                if hookCount > 0 {
                    output.plain("    \(hookCount) hook fragment(s)")
                }
                if gitignoreCount > 0 {
                    output.plain("    \(gitignoreCount) gitignore entry/entries")
                }
            }
        }
        output.plain("")

        // 4. Confirm
        if !force {
            guard output.askYesNo("Remove pack '\(entry.displayName)'?", default: false) else {
                output.info("Pack not removed.")
                return
            }
        }

        // 5. Uninstall artifacts BEFORE deleting checkout
        if let manifest {
            var uninstaller = PackUninstaller(
                environment: env,
                output: output,
                shell: shell,
                backup: Backup()
            )
            let summary = uninstaller.uninstall(manifest: manifest, packPath: packPath)
            if summary.totalRemoved > 0 {
                output.info("Cleaned up \(summary.totalRemoved) artifact(s)")
            }
            for err in summary.errors {
                output.warn(err)
            }
        }

        // 6. Remove from registry
        do {
            var data = registryData
            registry.remove(identifier: identifier, from: &data)
            try registry.save(data)
        } catch {
            output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 7. Delete local checkout
        do {
            try fetcher.remove(packPath: packPath)
        } catch {
            output.warn("Could not delete pack checkout: \(error.localizedDescription)")
        }

        output.success("Pack '\(entry.displayName)' removed.")
        output.info("Note: Project-level CLAUDE.local.md may still reference this pack. Run 'mcs configure' to update.")
    }
}

// MARK: - Update

struct UpdatePack: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an external tech pack to the latest version"
    )

    @Argument(help: "Pack identifier to update (omit for all)")
    var identifier: String?

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)
        let fetcher = PackFetcher(
            shell: shell,
            output: output,
            packsDirectory: env.packsDirectory
        )
        let trustManager = PackTrustManager(output: output)

        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let packsToUpdate: [PackRegistryFile.PackEntry]
        if let identifier {
            guard let entry = registry.pack(identifier: identifier, in: registryData) else {
                output.error("Pack '\(identifier)' is not installed.")
                throw ExitCode.failure
            }
            packsToUpdate = [entry]
        } else {
            packsToUpdate = registryData.packs
        }

        if packsToUpdate.isEmpty {
            output.info("No external packs installed.")
            return
        }

        var updatedData = registryData
        var updatedCount = 0

        for entry in packsToUpdate {
            output.info("Checking \(entry.displayName)...")

            let packPath = env.packsDirectory.appendingPathComponent(entry.localPath)

            // Fetch updates
            let updateResult: PackFetcher.FetchResult?
            do {
                updateResult = try fetcher.update(packPath: packPath, ref: entry.ref)
            } catch {
                output.warn("Failed to update '\(entry.identifier)': \(error.localizedDescription)")
                continue
            }

            guard let updateResult else {
                output.success("\(entry.displayName): already up to date")
                continue
            }

            // Re-validate manifest
            let manifest: ExternalPackManifest
            do {
                manifest = try loader.validate(at: packPath)
            } catch {
                output.warn("\(entry.identifier): updated but manifest is invalid: \(error.localizedDescription)")
                continue
            }

            // Check for new scripts requiring re-trust
            let newItems: [TrustableItem]
            do {
                newItems = try trustManager.detectNewScripts(
                    currentHashes: entry.trustedScriptHashes,
                    updatedPackPath: packPath,
                    manifest: manifest
                )
            } catch {
                output.warn("\(entry.identifier): could not analyze scripts: \(error.localizedDescription)")
                continue
            }

            var scriptHashes = entry.trustedScriptHashes
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
                    output.warn("Trust verification failed: \(error.localizedDescription)")
                    continue
                }

                guard decision.approved else {
                    output.info("\(entry.displayName): update skipped (trust not granted)")
                    continue
                }
                // Merge new hashes
                for (path, hash) in decision.scriptHashes {
                    scriptHashes[path] = hash
                }
            }

            // Update registry entry
            let updatedEntry = PackRegistryFile.PackEntry(
                identifier: entry.identifier,
                displayName: manifest.displayName,
                version: manifest.version,
                sourceURL: entry.sourceURL,
                ref: entry.ref,
                commitSHA: updateResult.commitSHA,
                localPath: entry.localPath,
                addedAt: entry.addedAt,
                trustedScriptHashes: scriptHashes
            )
            registry.register(updatedEntry, in: &updatedData)
            updatedCount += 1

            output.success("\(entry.displayName): updated to v\(manifest.version) (\(updateResult.commitSHA.prefix(7)))")
        }

        // Save all updates
        if updatedCount > 0 {
            do {
                try registry.save(updatedData)
            } catch {
                output.error("Failed to save registry: \(error.localizedDescription)")
                throw ExitCode.failure
            }
            output.plain("")
            output.info("Run 'mcs install' to apply updated pack components.")
        }
    }
}

// MARK: - List

struct ListPacks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed tech packs"
    )

    func run() throws {
        let env = Environment()
        let output = CLIOutput()

        let registry = PackRegistryFile(path: env.packsRegistry)

        output.header("Tech Packs")

        // External packs
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            output.warn("Could not read pack registry: \(error.localizedDescription)")
            return
        }

        if registryData.packs.isEmpty {
            output.plain("")
            output.dimmed("No external packs installed.")
            output.dimmed("Add one with: mcs pack add <git-url>")
        } else {
            output.plain("")
            output.sectionHeader("External")
            for entry in registryData.packs {
                let status = packStatus(entry: entry, env: env)
                output.plain("  \(entry.identifier)  v\(entry.version)  \(status)")
            }
        }

        output.plain("")
    }

    private func packStatus(entry: PackRegistryFile.PackEntry, env: Environment) -> String {
        let packPath = env.packsDirectory.appendingPathComponent(entry.localPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: packPath.path) else {
            return "(missing checkout)"
        }

        let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        guard fm.fileExists(atPath: manifestURL.path) else {
            return "(invalid — no \(Constants.ExternalPacks.manifestFilename))"
        }

        return entry.sourceURL
    }
}
