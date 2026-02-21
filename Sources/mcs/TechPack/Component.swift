import Foundation

/// Types of components that can be installed
enum ComponentType: String, Sendable, CaseIterable {
    case mcpServer = "MCP Servers"
    case plugin = "Plugins"
    case skill = "Skills"
    case hookFile = "Hooks"
    case command = "Commands"
    case brewPackage = "Dependencies"
    case configuration = "Configurations"
}

/// Definition of an installable component
struct ComponentDefinition: Sendable, Identifiable {
    let id: String // Unique identifier, e.g., "core.docs-mcp-server"
    let displayName: String // e.g., "docs-mcp-server"
    let description: String // Human-readable description
    let type: ComponentType
    let packIdentifier: String? // nil for core components
    let dependencies: [String] // IDs of components this depends on
    let isRequired: Bool // If true, always installed with its pack/core
    let installAction: ComponentInstallAction
}

/// How to install a component
enum ComponentInstallAction: Sendable {
    case mcpServer(MCPServerConfig)
    case plugin(name: String)
    case copySkill(source: String, destination: String)
    case copyHook(source: String, destination: String)
    case copyCommand(source: String, destination: String, placeholders: [String: String])
    case brewInstall(package: String)
    case shellCommand(command: String)
    case settingsMerge
    case gitignoreEntries(entries: [String])
}

/// Configuration for an MCP server
struct MCPServerConfig: Sendable {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]

    /// HTTP transport MCP server (no command, just URL)
    static func http(name: String, url: String) -> MCPServerConfig {
        MCPServerConfig(name: name, command: "http", args: [url], env: [:])
    }
}
