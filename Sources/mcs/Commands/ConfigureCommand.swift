import ArgumentParser
import Foundation

struct ConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Generate CLAUDE.local.md for a project"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Option(name: .long, help: "Tech pack to apply (e.g. ios). Can be specified multiple times.")
    var pack: [String] = []

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

        let configurator = ProjectConfigurator(
            environment: env,
            output: output,
            shell: shell
        )

        if pack.isEmpty {
            // Interactive flow — same as post-install configure
            try configurator.interactiveConfigure(at: projectPath)
        } else {
            // Explicit --pack flag
            let registry = TechPackRegistry.shared
            let resolvedPacks = pack.compactMap { registry.pack(for: $0) }

            for id in pack where registry.pack(for: id) == nil {
                output.warn("Unknown tech pack: \(id)")
            }

            guard let resolvedPack = resolvedPacks.first else {
                output.error("No valid tech pack specified.")
                let available = registry.availablePacks.map(\.identifier).joined(separator: ", ")
                output.plain("  Available packs: \(available)")
                throw ExitCode.failure
            }

            output.header("Configure Project")
            output.plain("")
            output.warn("This command should be run inside your project directory.")
            output.info("Project: \(projectPath.path)")
            output.info("Tech pack: \(resolvedPack.displayName)")

            try configurator.configure(at: projectPath, pack: resolvedPack)

            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }
    }
}
