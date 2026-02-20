import ArgumentParser

@main
struct MCS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcs",
        abstract: "My Claude Setup — Configure Claude Code with MCP servers, plugins, skills, and hooks",
        version: "2.0.0",
        subcommands: [InstallCommand.self, DoctorCommand.self, ConfigureCommand.self, CleanupCommand.self, UpdateCommand.self],
        defaultSubcommand: InstallCommand.self
    )
}
