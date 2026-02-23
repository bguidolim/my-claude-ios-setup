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

        // 2b. Warn if overriding a built-in pack
        let builtInIDs = Set(TechPackRegistry.shared.availablePacks.map(\.identifier))
        if builtInIDs.contains(manifest.identifier) {
            output.warn("Pack '\(manifest.identifier)' will override the built-in pack with the same identifier.")
            if !output.askYesNo("Override built-in pack?", default: false) {
                try? fetcher.remove(packPath: fetchResult.localPath)
                output.info("Pack not added.")
                return
            }
        }

        // 3. Check for collisions with existing packs
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
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

        // 2. Show what will be removed
        output.info("Pack: \(entry.displayName) v\(entry.version)")
        output.plain("  Source: \(entry.sourceURL)")
        output.plain("  Local:  ~/.claude/packs/\(entry.localPath)")
        output.plain("")

        // 3. Confirm
        if !force {
            guard output.askYesNo("Remove pack '\(entry.displayName)'?", default: false) else {
                output.info("Pack not removed.")
                return
            }
        }

        // 4. Remove from registry
        do {
            var data = registryData
            registry.remove(identifier: identifier, from: &data)
            try registry.save(data)
        } catch {
            output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 5. Delete local checkout
        let packPath = env.packsDirectory.appendingPathComponent(entry.localPath)
        do {
            try fetcher.remove(packPath: packPath)
        } catch {
            output.warn("Could not delete pack checkout: \(error.localizedDescription)")
        }

        output.success("Pack '\(entry.displayName)' removed.")
        output.info("Run 'mcs install' to clean up any installed artifacts.")
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

        // Built-in packs (show compiled-in packs, noting overrides)
        let compiledPacks = TechPackRegistry.shared.availablePacks
        let fullRegistry = TechPackRegistry.loadWithExternalPacks(environment: env, output: output)
        if !compiledPacks.isEmpty {
            output.sectionHeader("Built-in")
            for pack in compiledPacks {
                let overridden = fullRegistry.isExternalPack(pack.identifier)
                let suffix = overridden ? "  (overridden by external)" : ""
                output.plain("  \(pack.identifier)  \(pack.displayName)  (built-in)\(suffix)")
            }
        }

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
