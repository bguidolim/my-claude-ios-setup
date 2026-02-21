import ArgumentParser

/// Single source of truth for the CLI version.
/// Used in markers, sidecar files, and `--version` output.
enum MCSVersion {
    static let current = "2.0.0"
}

@main
struct MCS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcs",
        abstract: "My Claude Setup — Configure Claude Code with MCP servers, plugins, skills, and hooks",
        version: MCSVersion.current,
        subcommands: [InstallCommand.self, DoctorCommand.self, ConfigureCommand.self, CleanupCommand.self],
        defaultSubcommand: InstallCommand.self
    )
}
