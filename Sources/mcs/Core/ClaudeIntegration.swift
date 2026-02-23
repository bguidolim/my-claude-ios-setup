import Foundation

/// Wrapper for the `claude` CLI to manage MCP servers and plugins.
struct ClaudeIntegration: Sendable {
    let shell: ShellRunner

    /// The claude CLI command, with CLAUDECODE unset to avoid nesting checks.
    private var claudeEnv: [String: String] {
        ["CLAUDECODE": ""]
    }

    // MARK: - MCP Servers

    /// Add an MCP server (removes existing entry first for idempotence).
    @discardableResult
    func mcpAdd(
        name: String,
        scope: String = "user",
        arguments: [String] = []
    ) -> ShellResult {
        // Remove first to avoid "already exists" errors
        mcpRemove(name: name, scope: scope)

        var args = ["mcp", "add", "-s", scope, name]
        args.append(contentsOf: arguments)
        return shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand] + args,
            additionalEnvironment: claudeEnv
        )
    }

    /// Remove an MCP server.
    @discardableResult
    func mcpRemove(name: String, scope: String = "user") -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "mcp", "remove", "-s", scope, name],
            additionalEnvironment: claudeEnv
        )
    }

    // MARK: - Plugins

    /// Register a plugin marketplace.
    @discardableResult
    func pluginMarketplaceAdd(repo: String) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "marketplace", "add", repo],
            additionalEnvironment: claudeEnv
        )
    }

    /// Install a plugin (registers marketplace first).
    @discardableResult
    func pluginInstall(fullName: String) -> ShellResult {
        // Extract marketplace from "name@marketplace" format
        let parts = fullName.split(separator: "@")
        if parts.count == 2 {
            let marketplace = String(parts[1])
            let repo: String? = switch marketplace {
            case Constants.Plugins.officialMarketplace:
                Constants.Plugins.officialMarketplaceRepo
            default:
                nil
            }
            if let repo {
                pluginMarketplaceAdd(repo: repo)
            }
        }

        return shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "install", fullName],
            additionalEnvironment: claudeEnv
        )
    }

    /// Remove a plugin.
    @discardableResult
    func pluginRemove(fullName: String) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "remove", fullName],
            additionalEnvironment: claudeEnv
        )
    }
}
