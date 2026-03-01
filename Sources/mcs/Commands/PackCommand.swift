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

struct AddPack: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a tech pack from a Git repository or local path"
    )

    @Argument(help: "Git URL, GitHub shorthand (user/repo), or local path")
    var source: String

    @Option(name: .long, help: "Git tag, branch, or commit (git packs only)")
    var ref: String?

    @Flag(name: .long, help: "Preview pack contents without installing")
    var preview: Bool = false

    var skipLock: Bool { preview }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()

        let resolver = PackSourceResolver()
        let packSource: PackSource
        do {
            packSource = try resolver.resolve(source)
        } catch let error as PackSourceError {
            output.error(error.localizedDescription)
            throw ExitCode.failure
        }

        if case .gitURL(let expanded) = packSource,
           source.range(of: PackSourceResolver.shorthandPattern, options: .regularExpression) != nil {
            output.info("Interpreting '\(source)' as GitHub shorthand: \(expanded)")
        }

        switch packSource {
        case .gitURL(let gitURL):
            try performGitAdd(gitURL: gitURL, env: env, output: output)
        case .localPath(let path):
            if ref != nil {
                output.warn("--ref is ignored for local packs")
            }
            try performLocalAdd(path: path, env: env, output: output)
        }
    }

    // MARK: - Git Add

    private func performGitAdd(gitURL: String, env: Environment, output: CLIOutput) throws {
        let shell = ShellRunner(environment: env)

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
        output.info("Fetching pack from \(gitURL)...")
        let tempID = "tmp-\(UUID().uuidString.prefix(8))"
        let fetchResult: PackFetcher.FetchResult
        do {
            fetchResult = try fetcher.fetch(url: gitURL, identifier: tempID, ref: ref)
        } catch {
            output.error("Failed to fetch pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 2. Validate manifest
        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: fetchResult.localPath)
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Invalid pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        output.success("Found pack: \(manifest.displayName)")

        // 3. Check for collisions with existing packs
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        if !checkDuplicate(manifest: manifest, sourceURL: gitURL, registryData: registryData, output: output) {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.info("Pack not added.")
            return
        }

        let collisions = checkCollisions(
            manifest: manifest,
            registryData: registryData,
            registry: registry,
            env: env,
            output: output
        )

        if !collisions.isEmpty {
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
        let decision: PackTrustManager.TrustDecision
        do {
            decision = try verifyTrust(manifest: manifest, packPath: fetchResult.localPath, output: output)
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
        guard let finalPath = PathContainment.safePath(
            relativePath: manifest.identifier,
            within: env.packsDirectory
        ) else {
            try? fetcher.remove(packPath: fetchResult.localPath)
            output.error("Pack identifier escapes packs directory — refusing to install")
            throw ExitCode.failure
        }
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
            author: manifest.author,
            sourceURL: gitURL,
            ref: ref,
            commitSHA: fetchResult.commitSHA,
            localPath: manifest.identifier,
            addedAt: ISO8601DateFormatter().string(from: Date()),
            trustedScriptHashes: decision.scriptHashes,
            isLocal: nil
        )

        do {
            var data = registryData
            registry.register(entry, in: &data)
            try registry.save(data)
        } catch {
            output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        output.success("Pack '\(manifest.displayName)' added successfully.")
        output.plain("")
        output.info("Next step: run 'mcs sync' to apply the pack to your project.")
    }

    // MARK: - Local Add

    private func performLocalAdd(path: URL, env: Environment, output: CLIOutput) throws {
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        // 1. Validate manifest at the local path
        output.info("Reading pack from \(path.path)...")
        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: path)
        } catch {
            output.error("Invalid pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        output.success("Found pack: \(manifest.displayName)")

        // 2. Check for collisions with existing packs
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        if !checkDuplicate(manifest: manifest, sourceURL: path.path, registryData: registryData, output: output) {
            output.info("Pack not added.")
            return
        }

        let collisions = checkCollisions(
            manifest: manifest,
            registryData: registryData,
            registry: registry,
            env: env,
            output: output
        )

        if !collisions.isEmpty {
            if !output.askYesNo("Continue anyway?", default: false) {
                output.info("Pack not added.")
                return
            }
        }

        // 3. Display summary
        displayPackSummary(manifest: manifest, output: output)

        if preview {
            output.info("Preview complete. No changes made.")
            return
        }

        // 4. Trust verification
        let decision: PackTrustManager.TrustDecision
        do {
            decision = try verifyTrust(manifest: manifest, packPath: path, output: output)
        } catch {
            output.error("Trust verification failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard decision.approved else {
            output.info("Pack not trusted. No changes made.")
            return
        }

        // 5. Register in pack registry (no clone/move — pack stays in-place)
        let entry = PackRegistryFile.PackEntry(
            identifier: manifest.identifier,
            displayName: manifest.displayName,
            author: manifest.author,
            sourceURL: path.path,
            ref: nil,
            commitSHA: Constants.ExternalPacks.localCommitSentinel,
            localPath: path.path,
            addedAt: ISO8601DateFormatter().string(from: Date()),
            trustedScriptHashes: decision.scriptHashes,
            isLocal: true
        )

        do {
            var data = registryData
            registry.register(entry, in: &data)
            try registry.save(data)
        } catch {
            output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        output.success("Pack '\(manifest.displayName)' added as local pack.")
        output.plain("")
        output.info("Next step: run 'mcs sync' to apply the pack to your project.")
    }

    // MARK: - Shared Helpers

    private func checkCollisions(
        manifest: ExternalPackManifest,
        registryData: PackRegistryFile.RegistryData,
        registry: PackRegistryFile,
        env: Environment,
        output: CLIOutput
    ) -> [PackCollision] {
        let existingManifestInputs: [PackRegistryFile.CollisionInput] = registryData.packs.map { entry in
            guard let packPath = entry.resolvedPath(packsDirectory: env.packsDirectory) else {
                output.warn("Pack '\(entry.identifier)' has an unsafe localPath — skipping collision check")
                return .empty(identifier: entry.identifier)
            }
            let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
            guard let existingManifest = try? ExternalPackManifest.load(from: manifestURL) else {
                output.warn("Could not load manifest for '\(entry.identifier)', collision detection may be incomplete")
                return .empty(identifier: entry.identifier)
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
        }

        return collisions
    }

    /// Warn if a pack with the same identifier is already registered.
    /// Returns `true` if the user wants to proceed, `false` to abort.
    private func checkDuplicate(
        manifest: ExternalPackManifest,
        sourceURL: String,
        registryData: PackRegistryFile.RegistryData,
        output: CLIOutput
    ) -> Bool {
        guard let existing = registryData.packs.first(where: { $0.identifier == manifest.identifier }) else {
            return true
        }

        if existing.sourceURL == sourceURL {
            output.warn("Pack '\(manifest.identifier)' is already installed.")
        } else {
            output.warn("Pack identifier '\(manifest.identifier)' is already registered from a different source:")
            output.plain("  Current: \(existing.sourceURL)")
            output.plain("  New:     \(sourceURL)")
        }
        return output.askYesNo("Replace existing pack?", default: false)
    }

    /// Analyze scripts and prompt for trust approval. Throws on failure.
    private func verifyTrust(
        manifest: ExternalPackManifest,
        packPath: URL,
        output: CLIOutput
    ) throws -> PackTrustManager.TrustDecision {
        let trustManager = PackTrustManager(output: output)
        let items = try trustManager.analyzeScripts(manifest: manifest, packPath: packPath)
        return try trustManager.promptForTrust(
            manifest: manifest,
            packPath: packPath,
            items: items
        )
    }

    private func displayPackSummary(manifest: ExternalPackManifest, output: CLIOutput) {
        output.plain("")
        output.sectionHeader("Pack Summary")
        output.plain("  Identifier: \(manifest.identifier)")
        if let author = manifest.author {
            output.plain("  Author:     \(author)")
        }
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

        output.plain("")
    }
}

// MARK: - Remove

struct RemovePack: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a tech pack"
    )

    @Argument(help: "Pack identifier to remove")
    var identifier: String

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    func perform() throws {
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

        guard let packPath = entry.resolvedPath(packsDirectory: env.packsDirectory) else {
            if entry.isLocalPack {
                output.error("Pack '\(entry.identifier)' has an invalid local path: '\(entry.localPath)'")
            } else {
                output.error("Pack localPath escapes packs directory — refusing to proceed")
            }
            throw ExitCode.failure
        }

        // 2. Show pack info
        output.info("Pack: \(entry.displayName)")
        if let author = entry.author {
            output.plain("  Author: \(author)")
        }
        if entry.isLocalPack {
            output.plain("  Source: \(entry.sourceURL) (local)")
        } else {
            output.plain("  Source: \(entry.sourceURL)")
            output.plain("  Local:  ~/.mcs/packs/\(entry.localPath)")
        }

        // 3. Discover affected scopes
        let techPackRegistry = TechPackRegistry.loadWithExternalPacks(environment: env, output: output)

        let indexFile = ProjectIndex(path: env.projectsIndexFile)
        let indexData: ProjectIndex.IndexData
        do {
            indexData = try indexFile.load()
        } catch {
            output.warn("Could not read project index — per-project cleanup may be incomplete.")
            indexData = ProjectIndex.IndexData()
        }
        let affectedEntries = indexFile.projects(withPack: identifier, in: indexData)

        let isGloballyConfigured: Bool
        do {
            let globalState = try ProjectState(stateFile: env.globalStateFile)
            isGloballyConfigured = globalState.configuredPacks.contains(identifier)
        } catch {
            output.warn("Could not read global state — global cleanup may be incomplete.")
            isGloballyConfigured = false
        }

        var liveProjectPaths: [String] = []
        var staleProjectPaths: [String] = []
        for projectEntry in affectedEntries {
            guard projectEntry.path != ProjectIndex.globalSentinel else { continue }
            if FileManager.default.fileExists(atPath: projectEntry.path) {
                liveProjectPaths.append(projectEntry.path)
            } else {
                staleProjectPaths.append(projectEntry.path)
            }
        }

        if isGloballyConfigured || !liveProjectPaths.isEmpty {
            output.plain("")
            output.plain("  Affected scopes:")
            if isGloballyConfigured {
                output.plain("    Global (~/.claude/)")
            }
            for path in liveProjectPaths {
                output.plain("    \(path)")
            }
        }
        if !staleProjectPaths.isEmpty {
            output.plain("  Stale references (will be pruned):")
            for path in staleProjectPaths {
                output.dimmed("    \(path)")
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

        // 5. Federated unconfigure — remove artifacts from all affected scopes
        if isGloballyConfigured {
            do {
                var globalState = try ProjectState(stateFile: env.globalStateFile)
                let configurator = Configurator(
                    environment: env,
                    output: output,
                    shell: shell,
                    registry: techPackRegistry,
                    strategy: GlobalSyncStrategy(environment: env)
                )
                configurator.unconfigurePack(
                    identifier,
                    state: &globalState,
                    refCountScope: ProjectIndex.packRemoveSentinel
                )
                try globalState.save()
            } catch {
                output.warn("Global cleanup failed: \(error.localizedDescription)")
            }
        }

        for projectPath in liveProjectPaths {
            do {
                let projectURL = URL(fileURLWithPath: projectPath)
                var projectState = try ProjectState(projectRoot: projectURL)
                let configurator = Configurator(
                    environment: env,
                    output: output,
                    shell: shell,
                    registry: techPackRegistry,
                    strategy: ProjectSyncStrategy(projectPath: projectURL, environment: env)
                )
                configurator.unconfigurePack(
                    identifier,
                    state: &projectState,
                    refCountScope: ProjectIndex.packRemoveSentinel
                )
                try projectState.save()
            } catch {
                output.warn("Cleanup for \(projectPath) failed: \(error.localizedDescription)")
            }
        }

        // 6. Update project index
        do {
            var updatedIndex = try indexFile.load()
            indexFile.removePack(identifier, from: &updatedIndex)
            for stalePath in staleProjectPaths {
                indexFile.remove(projectPath: stalePath, from: &updatedIndex)
            }
            try indexFile.save(updatedIndex)
        } catch {
            output.error("Could not update project index: \(error.localizedDescription)")
            output.error("Run 'mcs sync' to reconcile, or manually edit ~/.mcs/projects.yaml")
        }

        // 7. Remove from registry
        do {
            var data = registryData
            registry.remove(identifier: identifier, from: &data)
            try registry.save(data)
        } catch {
            output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 8. Delete local checkout (skip for local packs — don't delete user's source directory)
        if !entry.isLocalPack {
            do {
                try fetcher.remove(packPath: packPath)
            } catch {
                output.warn("Could not delete pack checkout: \(error.localizedDescription)")
            }
        }

        output.success("Pack '\(entry.displayName)' removed.")
    }
}

// MARK: - Update

struct UpdatePack: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update tech packs to the latest version"
    )

    @Argument(help: "Pack identifier to update (omit for all)")
    var identifier: String?

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        let registry = PackRegistryFile(path: env.packsRegistry)
        let updater = PackUpdater(
            fetcher: PackFetcher(shell: shell, output: output, packsDirectory: env.packsDirectory),
            trustManager: PackTrustManager(output: output),
            environment: env,
            output: output
        )

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
            if entry.isLocalPack {
                if identifier != nil {
                    output.info("\(entry.displayName) is a local pack — changes are picked up automatically on next sync.")
                } else {
                    output.dimmed("\(entry.displayName): local pack (always up to date)")
                }
                continue
            }

            output.info("Checking \(entry.displayName)...")

            guard let packPath = entry.resolvedPath(packsDirectory: env.packsDirectory) else {
                output.error("Pack '\(entry.identifier)' has an invalid path — skipping")
                continue
            }

            let result = updater.updateGitPack(entry: entry, packPath: packPath, registry: registry)
            switch result {
            case .alreadyUpToDate:
                output.success("\(entry.displayName): already up to date")
            case .updated(let updatedEntry):
                registry.register(updatedEntry, in: &updatedData)
                updatedCount += 1
                output.success("\(entry.displayName): updated (\(updatedEntry.commitSHA.prefix(7)))")
            case .skipped(let reason):
                output.warn("\(entry.identifier): \(reason)")
            }
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
            output.info("Run 'mcs sync' to apply updated pack components.")
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

        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            output.warn("Could not read pack registry: \(error.localizedDescription)")
            return
        }

        if registryData.packs.isEmpty {
            output.plain("")
            output.dimmed("No packs installed.")
            output.dimmed("Add one with: mcs pack add <source>")
        } else {
            output.plain("")
            for entry in registryData.packs {
                let status = packStatus(entry: entry, env: env)
                let authorLabel = entry.author.map { "  by \($0)" } ?? ""
                output.plain("  \(entry.identifier)\(authorLabel)  \(status)")
            }
        }

        output.plain("")
    }

    private func packStatus(entry: PackRegistryFile.PackEntry, env: Environment) -> String {
        let fm = FileManager.default

        guard let packPath = entry.resolvedPath(packsDirectory: env.packsDirectory) else {
            if entry.isLocalPack {
                return "(invalid local path: \(entry.localPath))"
            }
            return "(invalid path — escapes packs directory)"
        }

        guard fm.fileExists(atPath: packPath.path) else {
            if entry.isLocalPack {
                return "(local — missing at \(entry.localPath))"
            }
            return "(missing checkout)"
        }

        if entry.isLocalPack {
            return "\(entry.sourceURL) (local)"
        }

        let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        guard fm.fileExists(atPath: manifestURL.path) else {
            return "(invalid — no \(Constants.ExternalPacks.manifestFilename))"
        }

        return entry.sourceURL
    }
}
