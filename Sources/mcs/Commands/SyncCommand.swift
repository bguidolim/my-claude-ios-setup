import ArgumentParser
import Foundation

struct SyncCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync Claude Code configuration for a project"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Option(name: .long, help: "Tech pack to apply (e.g. ios). Can be specified multiple times.")
    var pack: [String] = []

    @Flag(name: .long, help: "Apply all registered packs without prompts")
    var all: Bool = false

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    @Flag(name: .long, help: "Checkout locked pack versions from mcs.lock.yaml before syncing")
    var lock = false

    @Flag(name: .long, help: "Fetch latest pack versions and update mcs.lock.yaml")
    var update = false

    var skipLock: Bool { dryRun }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        guard ensureClaudeCLI(shell: shell, environment: env, output: output) else {
            throw ExitCode.failure
        }

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

        let lockOps = LockfileOperations(environment: env, output: output, shell: shell)

        // Handle --lock: checkout locked versions before loading packs
        if lock {
            try lockOps.checkoutLockedVersions(at: projectPath)
        }

        // Handle --update: fetch latest for all packs before loading
        if update {
            try lockOps.updatePacks()
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

        if all {
            // Apply all registered packs (CI-friendly)
            let allPacks = registry.availablePacks
            guard !allPacks.isEmpty else {
                output.error("No packs registered. Run 'mcs pack add <url>' first.")
                throw ExitCode.failure
            }

            output.header("Sync Project")
            output.plain("")
            output.info("Project: \(projectPath.path)")
            output.info("Packs: \(allPacks.map(\.displayName).joined(separator: ", "))")

            if dryRun {
                configurator.dryRun(at: projectPath, packs: allPacks)
            } else {
                try configurator.configure(at: projectPath, packs: allPacks, confirmRemovals: false)
                output.header("Done")
                output.info("Run 'mcs doctor' to verify configuration")
            }
        } else if !pack.isEmpty {
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

            output.header("Sync Project")
            output.plain("")
            output.info("Project: \(projectPath.path)")
            output.info("Packs: \(resolvedPacks.map(\.displayName).joined(separator: ", "))")

            if dryRun {
                configurator.dryRun(at: projectPath, packs: resolvedPacks)
            } else {
                try configurator.configure(at: projectPath, packs: resolvedPacks, confirmRemovals: false)
                output.header("Done")
                output.info("Run 'mcs doctor' to verify configuration")
            }
        } else {
            // Interactive flow — multi-select of all registered packs
            try configurator.interactiveConfigure(at: projectPath, dryRun: dryRun)
        }

        // Write lockfile after successful sync (unless dry-run)
        if !dryRun {
            try lockOps.writeLockfile(at: projectPath)
        }
    }
}
