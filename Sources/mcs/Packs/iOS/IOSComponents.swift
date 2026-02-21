import Foundation

/// Component definitions for the iOS tech pack.
enum IOSComponents {
    static let xcodeBuildMCP = ComponentDefinition(
        id: "ios.xcodebuildmcp",
        displayName: "XcodeBuildMCP",
        description: "MCP server for Xcode build, test, and simulator workflows",
        type: .mcpServer,
        packIdentifier: "ios",
        dependencies: ["core.node"],
        isRequired: false,
        installAction: .mcpServer(MCPServerConfig(
            name: "XcodeBuildMCP",
            command: "npx",
            args: ["-y", "xcodebuildmcp@latest", "mcp"],
            env: ["XCODEBUILDMCP_SENTRY_DISABLED": "1"]
        ))
    )

    static let sosumi = ComponentDefinition(
        id: "ios.sosumi",
        displayName: "Sosumi",
        description: "Apple documentation search via MCP (HTTP transport)",
        type: .mcpServer,
        packIdentifier: "ios",
        dependencies: [],
        isRequired: false,
        installAction: .mcpServer(.http(name: "sosumi", url: "https://sosumi.ai/mcp"))
    )

    static let xcodeBuildMCPSkill = ComponentDefinition(
        id: "ios.skill.xcodebuildmcp",
        displayName: "XcodeBuildMCP skill",
        description: "Skill that loads XcodeBuildMCP tool catalog and workflow guidance",
        type: .skill,
        packIdentifier: "ios",
        dependencies: ["ios.xcodebuildmcp"],
        isRequired: false,
        installAction: .shellCommand(
            command: "npx -y skills add cameroncooke/xcodebuildmcp -g -a claude-code -y"
        ),
        supplementaryChecks: [XcodeBuildMCPSkillCheck()]
    )

    static let gitignore = ComponentDefinition(
        id: "ios.gitignore",
        displayName: "iOS gitignore entries",
        description: "Add .xcodebuildmcp to global gitignore",
        type: .configuration,
        packIdentifier: "ios",
        dependencies: [],
        isRequired: true,
        installAction: .gitignoreEntries(entries: [IOSConstants.FileNames.xcodeBuildMCPDirectory])
    )

    static let all: [ComponentDefinition] = [
        xcodeBuildMCP,
        sosumi,
        xcodeBuildMCPSkill,
        gitignore,
    ]
}
