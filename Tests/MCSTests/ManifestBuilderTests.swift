import Testing
import Foundation
@testable import mcs

@Suite("ManifestBuilder")
struct ManifestBuilderTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-manifest-builder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Round-trip: build → YAML → load → normalized → validate

    @Test("Round-trip preserves all artifact types through YAML")
    func roundTripFull() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create real files for hooks/skills/commands (FileCopy needs them)
        let hookURL = tmpDir.appendingPathComponent("pre_tool_use.sh")
        try "#!/bin/bash\nexit 0".write(to: hookURL, atomically: true, encoding: .utf8)
        let skillURL = tmpDir.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
        let cmdURL = tmpDir.appendingPathComponent("deploy.md")
        try "Deploy command".write(to: cmdURL, atomically: true, encoding: .utf8)

        // Build representative DiscoveredConfiguration
        var config = ConfigurationDiscovery.DiscoveredConfiguration()

        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "docs-server", command: "npx",
                args: ["-y", "docs-mcp@latest"],
                env: ["API_KEY": "secret123", "LOG_LEVEL": "debug"],
                url: nil, scope: "local"
            ),
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "remote", command: nil, args: [],
                env: [:],
                url: "https://example.com/mcp", scope: "user"
            ),
        ]

        config.hookFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "pre_tool_use.sh",
                absolutePath: hookURL,
                hookEvent: "PreToolUse"
            ),
        ]

        config.skillFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "review",
                absolutePath: skillURL
            ),
        ]

        config.commandFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "deploy.md",
                absolutePath: cmdURL
            ),
        ]

        config.plugins = ["pr-review-toolkit@claude-plugins-official"]

        config.gitignoreEntries = [".env", "*.log"]

        config.claudeSections = [
            ConfigurationDiscovery.DiscoveredClaudeSection(
                sectionIdentifier: "test-pack.instructions",
                content: "## Build & Test\nAlways use the build tool."
            ),
        ]

        config.claudeUserContent = "Custom user instructions"

        config.remainingSettingsData = try JSONSerialization.data(
            withJSONObject: ["env": ["THINKING_BUDGET": "10000"]],
            options: [.prettyPrinted, .sortedKeys]
        )

        let metadata = ManifestBuilder.Metadata(
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test tech pack for round-trip validation",
            author: "Test Author"
        )

        let result = ManifestBuilder().build(
            from: config,
            metadata: metadata,
            selectedMCPServers: Set(config.mcpServers.map(\.name)),
            selectedHookFiles: Set(config.hookFiles.map(\.filename)),
            selectedSkillFiles: Set(config.skillFiles.map(\.filename)),
            selectedCommandFiles: Set(config.commandFiles.map(\.filename)),
            selectedPlugins: Set(config.plugins),
            selectedSections: Set(config.claudeSections.map(\.sectionIdentifier)),
            includeUserContent: true,
            includeGitignore: true,
            includeSettings: true
        )

        // 1. Verify typed manifest metadata
        let manifest = result.manifest
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.identifier == "test-pack")
        #expect(manifest.displayName == "Test Pack")
        #expect(manifest.author == "Test Author")

        // 2. Write YAML to file, parse back, normalize, validate
        let yamlFile = tmpDir.appendingPathComponent("techpack.yaml")
        try result.manifestYAML.write(to: yamlFile, atomically: true, encoding: .utf8)

        let loaded = try ExternalPackManifest.load(from: yamlFile)
        let normalized = try loaded.normalized()
        try normalized.validate()

        // 3. Verify component counts — 2 MCP + 1 hook + 1 skill + 1 cmd + 1 plugin + 1 settings + 1 gitignore = 8
        let components = try #require(normalized.components)
        #expect(components.count == 8)

        // 4. Verify MCP servers
        let mcpComps = components.filter { $0.type == .mcpServer }
        #expect(mcpComps.count == 2)

        // Stdio server with sensitive env var → placeholder
        let stdioComp = try #require(mcpComps.first { $0.id.contains("docs-server") })
        guard case .mcpServer(let stdioConfig) = stdioComp.installAction else {
            Issue.record("Expected mcpServer install action for docs-server")
            return
        }
        #expect(stdioConfig.command == "npx")
        #expect(stdioConfig.args == ["-y", "docs-mcp@latest"])
        #expect(stdioConfig.env?["API_KEY"] == "__API_KEY__")
        #expect(stdioConfig.env?["LOG_LEVEL"] == "debug")

        // HTTP server with user scope
        let httpComp = try #require(mcpComps.first { $0.id.contains("remote") })
        guard case .mcpServer(let httpConfig) = httpComp.installAction else {
            Issue.record("Expected mcpServer install action for remote")
            return
        }
        #expect(httpConfig.url == "https://example.com/mcp")
        #expect(httpConfig.scope == .user)

        // 5. Verify hook with hookEvent
        let hookComp = try #require(components.first { $0.type == .hookFile })
        #expect(hookComp.hookEvent == "PreToolUse")
        guard case .copyPackFile(let hookFile) = hookComp.installAction else {
            Issue.record("Expected copyPackFile for hook")
            return
        }
        #expect(hookFile.source == "hooks/pre_tool_use.sh")
        #expect(hookFile.destination == "pre_tool_use.sh")
        #expect(hookFile.fileType == .hook)

        // 6. Verify skill
        let skillComp = try #require(components.first { $0.type == .skill })
        guard case .copyPackFile(let skillFile) = skillComp.installAction else {
            Issue.record("Expected copyPackFile for skill")
            return
        }
        #expect(skillFile.fileType == .skill)

        // 7. Verify command
        let cmdComp = try #require(components.first { $0.type == .command })
        guard case .copyPackFile(let cmdFile) = cmdComp.installAction else {
            Issue.record("Expected copyPackFile for command")
            return
        }
        #expect(cmdFile.fileType == .command)

        // 8. Verify plugin
        let pluginComp = try #require(components.first { $0.type == .plugin })
        guard case .plugin(let pluginName) = pluginComp.installAction else {
            Issue.record("Expected plugin install action")
            return
        }
        #expect(pluginName == "pr-review-toolkit@claude-plugins-official")

        // 9. Verify settings and gitignore (both .configuration type)
        let configComps = components.filter { $0.type == .configuration }
        #expect(configComps.count == 2)
        let settingsComp = configComps.first { $0.id.contains("settings") }
        #expect(settingsComp?.isRequired == true)
        let gitignoreComp = configComps.first { $0.id.contains("gitignore") }
        #expect(gitignoreComp?.isRequired == true)
        guard case .gitignoreEntries(let entries) = gitignoreComp?.installAction else {
            Issue.record("Expected gitignoreEntries install action")
            return
        }
        #expect(entries.contains(".env"))
        #expect(entries.contains("*.log"))

        // 10. Verify templates (section + user content = 2)
        let templates = try #require(normalized.templates)
        #expect(templates.count == 2)

        // 11. Verify prompts (auto-generated for API_KEY)
        let prompts = try #require(normalized.prompts)
        #expect(prompts.count == 1)
        #expect(prompts[0].key == "API_KEY")
        #expect(prompts[0].type == .input)

        // 12. Verify side-channel outputs
        #expect(result.filesToCopy.count == 3) // hook + skill + command
        #expect(result.settingsToWrite != nil)
        #expect(result.templateFiles.count == 2)
    }

    // MARK: - Empty configuration

    @Test("Empty configuration produces valid minimal manifest")
    func emptyConfigRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = ConfigurationDiscovery.DiscoveredConfiguration()
        let metadata = ManifestBuilder.Metadata(
            identifier: "empty-pack",
            displayName: "Empty Pack",
            description: "No artifacts",
            author: nil
        )

        let result = ManifestBuilder().build(
            from: config, metadata: metadata,
            selectedMCPServers: [], selectedHookFiles: [], selectedSkillFiles: [],
            selectedCommandFiles: [], selectedPlugins: [], selectedSections: [],
            includeUserContent: false, includeGitignore: false, includeSettings: false
        )

        // Typed manifest should have no components
        #expect(result.manifest.components == nil)
        #expect(result.manifest.templates == nil)
        #expect(result.manifest.prompts == nil)
        #expect(result.manifest.author == nil)

        // YAML round-trip should still parse and validate
        let yamlFile = tmpDir.appendingPathComponent("techpack.yaml")
        try result.manifestYAML.write(to: yamlFile, atomically: true, encoding: .utf8)

        let loaded = try ExternalPackManifest.load(from: yamlFile)
        let normalized = try loaded.normalized()
        try normalized.validate()

        #expect(normalized.identifier == "empty-pack")
    }

    // MARK: - Typed manifest direct assertion

    @Test("BuildResult exposes typed manifest matching input")
    func typedManifestDirectAssertion() throws {
        var config = ConfigurationDiscovery.DiscoveredConfiguration()
        config.plugins = ["my-plugin@org"]
        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "test-server", command: "uvx",
                args: ["test-mcp"],
                env: ["TOKEN": "secret"],
                url: nil, scope: "local"
            ),
        ]

        let metadata = ManifestBuilder.Metadata(
            identifier: "direct-test",
            displayName: "Direct Test",
            description: "Test typed manifest",
            author: "Tester"
        )

        let result = ManifestBuilder().build(
            from: config, metadata: metadata,
            selectedMCPServers: Set(config.mcpServers.map(\.name)),
            selectedHookFiles: [], selectedSkillFiles: [],
            selectedCommandFiles: [],
            selectedPlugins: Set(config.plugins),
            selectedSections: [],
            includeUserContent: false, includeGitignore: false, includeSettings: false
        )

        let manifest = result.manifest
        #expect(manifest.identifier == "direct-test")
        #expect(manifest.author == "Tester")

        let components = try #require(manifest.components)
        #expect(components.count == 2) // 1 MCP + 1 plugin

        // MCP server should have TOKEN replaced with placeholder
        let mcpComp = try #require(components.first { $0.type == .mcpServer })
        guard case .mcpServer(let mcpConfig) = mcpComp.installAction else {
            Issue.record("Expected mcpServer action")
            return
        }
        #expect(mcpConfig.command == "uvx")
        #expect(mcpConfig.env?["TOKEN"] == "__TOKEN__")

        // Plugin
        let pluginComp = try #require(components.first { $0.type == .plugin })
        guard case .plugin(let name) = pluginComp.installAction else {
            Issue.record("Expected plugin action")
            return
        }
        #expect(name == "my-plugin@org")

        // Prompt auto-generated for TOKEN
        let prompts = try #require(manifest.prompts)
        #expect(prompts.count == 1)
        #expect(prompts[0].key == "TOKEN")
    }
}
