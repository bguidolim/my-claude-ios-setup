import ArgumentParser
import Foundation

struct ConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Configure a project with tech packs"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Option(name: .long, help: "Tech pack to apply (e.g. ios). Can be specified multiple times.")
    var pack: [String] = []

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    @Flag(name: .long, help: "Checkout locked pack versions from mcs.lock.yaml before configuring")
    var lock = false

    @Flag(name: .long, help: "Fetch latest pack versions and update mcs.lock.yaml")
    var update = false

    mutating func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        let projectPath: URL
        if let p = path {
            projectPath = URL(fileURLWithPath: p)
        } else {
            projectPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw MCSError.fileOperationFailed(
                path: projectPath.path,
                reason: "Directory does not exist"
            )
        }

        // Handle --lock: checkout locked versions before loading packs
        if lock {
            try checkoutLockedVersions(at: projectPath, env: env, output: output, shell: shell)
        }

        // Handle --update: fetch latest for all packs before loading
        if update {
            try updatePacks(env: env, output: output, shell: shell)
        }

        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )

        let configurator = ProjectConfigurator(
            environment: env,
            output: output,
            shell: shell,
            registry: registry
        )

        if pack.isEmpty {
            // Interactive flow — multi-select of all registered packs
            try configurator.interactiveConfigure(at: projectPath, dryRun: dryRun)
        } else {
            // Non-interactive --pack flag (CI-friendly)
            let resolvedPacks: [any TechPack] = pack.compactMap { registry.pack(for: $0) }

            for id in pack where registry.pack(for: id) == nil {
                output.warn("Unknown tech pack: \(id)")
            }

            guard !resolvedPacks.isEmpty else {
                output.error("No valid tech pack specified.")
                let available = registry.availablePacks.map(\.identifier).joined(separator: ", ")
                output.plain("  Available packs: \(available)")
                throw ExitCode.failure
            }

            output.header("Configure Project")
            output.plain("")
            output.info("Project: \(projectPath.path)")
            output.info("Packs: \(resolvedPacks.map(\.displayName).joined(separator: ", "))")

            if dryRun {
                configurator.dryRun(at: projectPath, packs: resolvedPacks)
            } else {
                try configurator.configure(at: projectPath, packs: resolvedPacks)

                output.header("Done")
                output.info("Run 'mcs doctor' to verify configuration")
            }
        }

        // Write lockfile after successful configure (unless dry-run)
        if !dryRun {
            try writeLockfile(at: projectPath, env: env, output: output)
        }
    }

    // MARK: - Lockfile Operations

    /// Checkout exact pack versions from the lockfile.
    private func checkoutLockedVersions(
        at projectPath: URL,
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner
    ) throws {
        guard let lockfile = try Lockfile.load(projectRoot: projectPath) else {
            output.error("No mcs.lock.yaml found. Run 'mcs configure' first to create one.")
            throw ExitCode.failure
        }

        output.info("Checking out locked pack versions...")

        for locked in lockfile.packs {
            let packPath = env.packsDirectory.appendingPathComponent(locked.identifier)
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
                // Try fetching first, then checkout
                _ = shell.run(
                    "/usr/bin/git",
                    arguments: ["-C", packPath.path, "fetch", "--all"]
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
    private func updatePacks(
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner
    ) throws {
        let registryFile = PackRegistryFile(path: env.packsRegistry)
        let registryData = try registryFile.load()

        if registryData.packs.isEmpty {
            output.info("No packs registered. Nothing to update.")
            return
        }

        output.info("Fetching latest pack versions...")
        let fetcher = PackFetcher(
            shell: shell,
            output: output,
            packsDirectory: env.packsDirectory
        )

        var updatedData = registryData
        for entry in registryData.packs {
            let packPath = env.packsDirectory.appendingPathComponent(entry.localPath)
            do {
                if let result = try fetcher.update(packPath: packPath, ref: entry.ref) {
                    // Update the registry entry with new SHA
                    let loader = ExternalPackLoader(environment: env, registry: registryFile)
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

    /// Write the lockfile after a successful configure.
    private func writeLockfile(
        at projectPath: URL,
        env: Environment,
        output: CLIOutput
    ) throws {
        let registryFile = PackRegistryFile(path: env.packsRegistry)
        let registryData = try registryFile.load()

        // Only include packs that are configured for this project
        let projectState = ProjectState(projectRoot: projectPath)
        let configuredIDs = projectState.configuredPacks

        guard !configuredIDs.isEmpty else { return }

        // Check for mismatches with existing lockfile
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
