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

extension ComponentType {
    /// Maps component types to doctor check section headers.
    var doctorSection: String { rawValue }
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

    /// Additional doctor checks that cannot be auto-derived from installAction.
    /// Used for components with .shellCommand or multi-step verification needs.
    let supplementaryChecks: [any DoctorCheck]

    init(
        id: String,
        displayName: String,
        description: String,
        type: ComponentType,
        packIdentifier: String?,
        dependencies: [String],
        isRequired: Bool,
        installAction: ComponentInstallAction,
        supplementaryChecks: [any DoctorCheck] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.type = type
        self.packIdentifier = packIdentifier
        self.dependencies = dependencies
        self.isRequired = isRequired
        self.installAction = installAction
        self.supplementaryChecks = supplementaryChecks
    }
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
