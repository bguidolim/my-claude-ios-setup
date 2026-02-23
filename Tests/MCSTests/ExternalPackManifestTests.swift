import Foundation
import Testing

@testable import mcs

@Suite("ExternalPackManifest")
struct ExternalPackManifestTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-manifest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Complete manifest parsing

    @Test("Parse a complete manifest with all fields")
    func parseCompleteManifest() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: My Pack
            description: A test tech pack
            version: "1.0.0"
            minMCSVersion: "2.0.0"
            peerDependencies:
              - pack: ios
                minVersion: "1.0.0"
            components:
              - id: my-pack.server
                displayName: My Server
                description: An MCP server
                type: mcpServer
                dependencies:
                  - my-pack.dep
                isRequired: false
                installAction:
                  type: mcpServer
                  name: my-server
                  command: npx
                  args:
                    - "-y"
                    - "my-server@latest"
                  env:
                    MY_VAR: "1"
              - id: my-pack.dep
                displayName: My Dependency
                description: A brew package
                type: brewPackage
                isRequired: true
                installAction:
                  type: brewInstall
                  package: my-pkg
            templates:
              - sectionIdentifier: my-pack
                placeholders:
                  - __PROJECT__
                contentFile: templates/section.md
            hookContributions:
              - hookName: session_start
                fragmentFile: hooks/fragment.sh
                position: after
            gitignoreEntries:
              - .my-pack
            prompts:
              - key: project_name
                type: input
                label: "Project name"
                default: "MyProject"
              - key: framework
                type: select
                label: "Select framework"
                options:
                  - value: uikit
                    label: UIKit
                  - value: swiftui
                    label: SwiftUI
            configureProject:
              script: scripts/configure.sh
            supplementaryDoctorChecks:
              - type: commandExists
                name: My Tool
                section: Dependencies
                command: my-tool
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.identifier == "my-pack")
        #expect(manifest.displayName == "My Pack")
        #expect(manifest.description == "A test tech pack")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.minMCSVersion == "2.0.0")

        // Peer dependencies
        #expect(manifest.peerDependencies?.count == 1)
        #expect(manifest.peerDependencies?[0].pack == "ios")
        #expect(manifest.peerDependencies?[0].minVersion == "1.0.0")

        // Components
        #expect(manifest.components?.count == 2)
        let server = manifest.components![0]
        #expect(server.id == "my-pack.server")
        #expect(server.type == .mcpServer)
        #expect(server.dependencies == ["my-pack.dep"])
        #expect(server.isRequired == false)

        let dep = manifest.components![1]
        #expect(dep.id == "my-pack.dep")
        #expect(dep.type == .brewPackage)
        #expect(dep.isRequired == true)

        // Templates
        #expect(manifest.templates?.count == 1)
        #expect(manifest.templates?[0].sectionIdentifier == "my-pack")
        #expect(manifest.templates?[0].placeholders == ["__PROJECT__"])
        #expect(manifest.templates?[0].contentFile == "templates/section.md")

        // Hook contributions
        #expect(manifest.hookContributions?.count == 1)
        #expect(manifest.hookContributions?[0].hookName == "session_start")
        #expect(manifest.hookContributions?[0].fragmentFile == "hooks/fragment.sh")
        #expect(manifest.hookContributions?[0].position == .after)

        // Gitignore entries
        #expect(manifest.gitignoreEntries == [".my-pack"])

        // Prompts
        #expect(manifest.prompts?.count == 2)
        #expect(manifest.prompts?[0].key == "project_name")
        #expect(manifest.prompts?[0].type == .input)
        #expect(manifest.prompts?[0].defaultValue == "MyProject")
        #expect(manifest.prompts?[1].key == "framework")
        #expect(manifest.prompts?[1].type == .select)
        #expect(manifest.prompts?[1].options?.count == 2)

        // Configure project
        #expect(manifest.configureProject?.script == "scripts/configure.sh")

        // Supplementary doctor checks
        #expect(manifest.supplementaryDoctorChecks?.count == 1)
        #expect(manifest.supplementaryDoctorChecks?[0].type == .commandExists)
        #expect(manifest.supplementaryDoctorChecks?[0].name == "My Tool")
        #expect(manifest.supplementaryDoctorChecks?[0].command == "my-tool")
    }

    // MARK: - Minimal manifest

    @Test("Parse minimal manifest with only required fields")
    func parseMinimalManifest() throws {
        let yaml = """
            schemaVersion: 1
            identifier: minimal
            displayName: Minimal Pack
            description: Just the basics
            version: "0.1.0"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.identifier == "minimal")
        #expect(manifest.minMCSVersion == nil)
        #expect(manifest.peerDependencies == nil)
        #expect(manifest.components == nil)
        #expect(manifest.templates == nil)
        #expect(manifest.hookContributions == nil)
        #expect(manifest.gitignoreEntries == nil)
        #expect(manifest.prompts == nil)
        #expect(manifest.configureProject == nil)
        #expect(manifest.supplementaryDoctorChecks == nil)
    }

    // MARK: - Validation errors

    @Test("Validation rejects unsupported schema version")
    func rejectBadSchemaVersion() throws {
        let yaml = """
            schemaVersion: 99
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.unsupportedSchemaVersion(99)) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects invalid identifier with uppercase")
    func rejectUppercaseIdentifier() throws {
        let yaml = """
            schemaVersion: 1
            identifier: MyPack
            displayName: Test
            description: Test
            version: "1.0.0"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.invalidIdentifier("MyPack")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects empty identifier")
    func rejectEmptyIdentifier() throws {
        let yaml = """
            schemaVersion: 1
            identifier: ""
            displayName: Test
            description: Test
            version: "1.0.0"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.invalidIdentifier("")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects identifier starting with hyphen")
    func rejectHyphenStartIdentifier() throws {
        let yaml = """
            schemaVersion: 1
            identifier: "-bad"
            displayName: Test
            description: Test
            version: "1.0.0"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.invalidIdentifier("-bad")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects component ID without pack prefix")
    func rejectComponentIDPrefixViolation() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: wrong-prefix.server
                displayName: Server
                description: A server
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: server
                  command: npx
                  args: ["-y", "server@latest"]
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.componentIDPrefixViolation(
            componentID: "wrong-prefix.server",
            expectedPrefix: "my-pack."
        )) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects duplicate component IDs")
    func rejectDuplicateComponentIDs() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: my-pack.server
                displayName: Server 1
                description: First
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: server
                  command: npx
                  args: ["-y", "server@latest"]
              - id: my-pack.server
                displayName: Server 2
                description: Duplicate
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: server2
                  command: npx
                  args: ["-y", "server2@latest"]
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.duplicateComponentID("my-pack.server")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects template section not matching pack identifier")
    func rejectTemplateSectionMismatch() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: Test
            description: Test
            version: "1.0.0"
            templates:
              - sectionIdentifier: other-pack
                contentFile: templates/section.md
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.templateSectionMismatch(
            sectionIdentifier: "other-pack",
            packIdentifier: "my-pack"
        )) {
            try manifest.validate()
        }
    }

    @Test("Validation accepts template section with pack identifier prefix")
    func acceptTemplateSectionWithPrefix() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: Test
            description: Test
            version: "1.0.0"
            templates:
              - sectionIdentifier: my-pack.extra
                contentFile: templates/extra.md
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()
    }

    @Test("Validation rejects duplicate prompt keys")
    func rejectDuplicatePromptKeys() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: Test
            description: Test
            version: "1.0.0"
            prompts:
              - key: project
                type: input
                label: "Project"
              - key: project
                type: select
                label: "Project again"
                options:
                  - value: a
                    label: A
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.duplicatePromptKey("project")) {
            try manifest.validate()
        }
    }

    @Test("Validation accepts valid identifier with hyphens and numbers")
    func acceptValidIdentifier() throws {
        let yaml = """
            schemaVersion: 1
            identifier: my-pack-2
            displayName: Test
            description: Test
            version: "1.0.0"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()
    }

    // MARK: - Install action types

    @Test("Deserialize mcpServer install action with stdio transport")
    func mcpServerStdioAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.server
                displayName: Server
                description: An MCP server
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: my-server
                  command: npx
                  args:
                    - "-y"
                    - "my-server@latest"
                  env:
                    DISABLE_TELEMETRY: "1"
                  transport: stdio
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .mcpServer(let config) = manifest.components?[0].installAction else {
            Issue.record("Expected mcpServer install action")
            return
        }

        #expect(config.name == "my-server")
        #expect(config.command == "npx")
        #expect(config.args == ["-y", "my-server@latest"])
        #expect(config.env == ["DISABLE_TELEMETRY": "1"])
        #expect(config.transport == .stdio)
    }

    @Test("Deserialize mcpServer install action with http transport")
    func mcpServerHTTPAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.http-server
                displayName: HTTP Server
                description: An HTTP MCP server
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: my-http-server
                  transport: http
                  url: https://example.com/mcp
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .mcpServer(let config) = manifest.components?[0].installAction else {
            Issue.record("Expected mcpServer install action")
            return
        }

        #expect(config.name == "my-http-server")
        #expect(config.transport == .http)
        #expect(config.url == "https://example.com/mcp")

        // Convert to internal config
        let internal_ = config.toMCPServerConfig()
        #expect(internal_.name == "my-http-server")
        #expect(internal_.command == "http")
        #expect(internal_.args == ["https://example.com/mcp"])
    }

    @Test("Deserialize plugin install action")
    func pluginAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.plugin
                displayName: Plugin
                description: A plugin
                type: plugin
                installAction:
                  type: plugin
                  name: my-plugin@1.0.0
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .plugin(let name) = manifest.components?[0].installAction else {
            Issue.record("Expected plugin install action")
            return
        }
        #expect(name == "my-plugin@1.0.0")
    }

    @Test("Deserialize brewInstall install action")
    func brewInstallAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.brew
                displayName: Brew Pkg
                description: A brew package
                type: brewPackage
                installAction:
                  type: brewInstall
                  package: my-package
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .brewInstall(let package) = manifest.components?[0].installAction else {
            Issue.record("Expected brewInstall install action")
            return
        }
        #expect(package == "my-package")
    }

    @Test("Deserialize shellCommand install action")
    func shellCommandAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.skill
                displayName: Skill
                description: A skill via shell command
                type: skill
                installAction:
                  type: shellCommand
                  command: "npx -y skills add my-skill -g -a claude-code -y"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .shellCommand(let command) = manifest.components?[0].installAction else {
            Issue.record("Expected shellCommand install action")
            return
        }
        #expect(command == "npx -y skills add my-skill -g -a claude-code -y")
    }

    @Test("Deserialize gitignoreEntries install action")
    func gitignoreEntriesAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.gitignore
                displayName: Gitignore
                description: Gitignore entries
                type: configuration
                installAction:
                  type: gitignoreEntries
                  entries:
                    - .my-dir
                    - "*.generated"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .gitignoreEntries(let entries) = manifest.components?[0].installAction else {
            Issue.record("Expected gitignoreEntries install action")
            return
        }
        #expect(entries == [".my-dir", "*.generated"])
    }

    @Test("Deserialize settingsMerge install action")
    func settingsMergeAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.settings
                displayName: Settings
                description: Settings merge
                type: configuration
                installAction:
                  type: settingsMerge
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .settingsMerge = manifest.components?[0].installAction else {
            Issue.record("Expected settingsMerge install action")
            return
        }
    }

    @Test("Deserialize settingsFile install action")
    func settingsFileAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.settings-file
                displayName: Settings File
                description: Custom settings file
                type: configuration
                installAction:
                  type: settingsFile
                  source: config/settings.json
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .settingsFile(let source) = manifest.components?[0].installAction else {
            Issue.record("Expected settingsFile install action")
            return
        }
        #expect(source == "config/settings.json")
    }

    @Test("Deserialize copyPackFile install action")
    func copyPackFileAction() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.hook
                displayName: Hook
                description: A hook file
                type: hookFile
                installAction:
                  type: copyPackFile
                  source: hooks/my-hook.sh
                  destination: hooks/my-hook.sh
                  fileType: hook
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .copyPackFile(let config) = manifest.components?[0].installAction else {
            Issue.record("Expected copyPackFile install action")
            return
        }
        #expect(config.source == "hooks/my-hook.sh")
        #expect(config.destination == "hooks/my-hook.sh")
        #expect(config.fileType == .hook)
    }

    // MARK: - Doctor check types

    @Test("Deserialize all doctor check types")
    func allDoctorCheckTypes() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            supplementaryDoctorChecks:
              - type: commandExists
                name: Tool check
                section: Dependencies
                command: my-tool
              - type: fileExists
                name: Config file
                section: Configuration
                path: ~/.config/my-tool.json
              - type: directoryExists
                name: Data dir
                section: Configuration
                path: ~/.my-tool
              - type: fileContains
                name: Config has key
                section: Configuration
                path: ~/.config/my-tool.json
                pattern: "api_key"
              - type: fileNotContains
                name: No debug flag
                section: Configuration
                path: ~/.config/my-tool.json
                pattern: "debug: true"
              - type: shellScript
                name: Custom check
                section: Custom
                command: "test -f /tmp/ready"
                fixCommand: "touch /tmp/ready"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let checks = manifest.supplementaryDoctorChecks!

        #expect(checks.count == 6)
        #expect(checks[0].type == .commandExists)
        #expect(checks[0].command == "my-tool")
        #expect(checks[1].type == .fileExists)
        #expect(checks[1].path == "~/.config/my-tool.json")
        #expect(checks[2].type == .directoryExists)
        #expect(checks[3].type == .fileContains)
        #expect(checks[3].pattern == "api_key")
        #expect(checks[4].type == .fileNotContains)
        #expect(checks[4].pattern == "debug: true")
        #expect(checks[5].type == .shellScript)
        #expect(checks[5].fixCommand == "touch /tmp/ready")
    }

    @Test("Deserialize doctor check with scope and fixScript")
    func doctorCheckWithScopeAndFixScript() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            supplementaryDoctorChecks:
              - type: fileExists
                name: Project config
                section: Project
                path: .my-tool/config.yaml
                scope: project
                fixScript: scripts/fix-config.sh
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let check = manifest.supplementaryDoctorChecks![0]

        #expect(check.scope == .project)
        #expect(check.fixScript == "scripts/fix-config.sh")
    }

    // MARK: - Prompt types

    @Test("Deserialize all prompt types")
    func allPromptTypes() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            prompts:
              - key: project_file
                type: fileDetect
                label: "Xcode project"
                detectPattern: "*.xcodeproj"
              - key: name
                type: input
                label: "Project name"
                default: "MyApp"
              - key: platform
                type: select
                label: "Target platform"
                options:
                  - value: ios
                    label: iOS
                  - value: macos
                    label: macOS
              - key: version
                type: script
                label: "Detected version"
                scriptCommand: "cat VERSION"
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let prompts = manifest.prompts!

        #expect(prompts.count == 4)

        #expect(prompts[0].type == .fileDetect)
        #expect(prompts[0].detectPattern == "*.xcodeproj")

        #expect(prompts[1].type == .input)
        #expect(prompts[1].defaultValue == "MyApp")

        #expect(prompts[2].type == .select)
        #expect(prompts[2].options?.count == 2)
        #expect(prompts[2].options?[0] == ExternalPromptOption(value: "ios", label: "iOS"))
        #expect(prompts[2].options?[1] == ExternalPromptOption(value: "macos", label: "macOS"))

        #expect(prompts[3].type == .script)
        #expect(prompts[3].scriptCommand == "cat VERSION")
    }

    // MARK: - ExternalComponentType mapping

    @Test("ExternalComponentType maps to ComponentType correctly")
    func componentTypeMapping() {
        #expect(ExternalComponentType.mcpServer.componentType == .mcpServer)
        #expect(ExternalComponentType.plugin.componentType == .plugin)
        #expect(ExternalComponentType.skill.componentType == .skill)
        #expect(ExternalComponentType.hookFile.componentType == .hookFile)
        #expect(ExternalComponentType.command.componentType == .command)
        #expect(ExternalComponentType.brewPackage.componentType == .brewPackage)
        #expect(ExternalComponentType.configuration.componentType == .configuration)
    }

    // MARK: - ExternalHookPosition mapping

    @Test("ExternalHookPosition maps to HookPosition correctly")
    func hookPositionMapping() {
        #expect(ExternalHookPosition.before.hookPosition == .before)
        #expect(ExternalHookPosition.after.hookPosition == .after)
    }

    // MARK: - MCPServerConfig conversion

    @Test("ExternalMCPServerConfig converts to MCPServerConfig for stdio")
    func mcpServerConfigConversionStdio() {
        let external = ExternalMCPServerConfig(
            name: "test-server",
            command: "node",
            args: ["server.js"],
            env: ["PORT": "3000"],
            transport: .stdio,
            url: nil,
            scope: nil
        )

        let config = external.toMCPServerConfig()
        #expect(config.name == "test-server")
        #expect(config.command == "node")
        #expect(config.args == ["server.js"])
        #expect(config.env == ["PORT": "3000"])
    }

    @Test("ExternalMCPServerConfig converts to MCPServerConfig for http")
    func mcpServerConfigConversionHTTP() {
        let external = ExternalMCPServerConfig(
            name: "http-server",
            command: nil,
            args: nil,
            env: nil,
            transport: .http,
            url: "https://example.com/mcp",
            scope: nil
        )

        let config = external.toMCPServerConfig()
        #expect(config.name == "http-server")
        #expect(config.command == "http")
        #expect(config.args == ["https://example.com/mcp"])
        #expect(config.env == [:])
    }

    @Test("ExternalMCPServerConfig passes scope through to MCPServerConfig")
    func mcpServerConfigScopePassthrough() {
        let external = ExternalMCPServerConfig(
            name: "test-server",
            command: "node",
            args: ["server.js"],
            env: nil,
            transport: .stdio,
            url: nil,
            scope: .local
        )

        let config = external.toMCPServerConfig()
        #expect(config.scope == "local")
        #expect(config.resolvedScope == "local")
    }

    @Test("ExternalMCPServerConfig with project scope passes through")
    func mcpServerConfigProjectScope() {
        let external = ExternalMCPServerConfig(
            name: "team-server",
            command: "node",
            args: [],
            env: nil,
            transport: nil,
            url: nil,
            scope: .project
        )

        let config = external.toMCPServerConfig()
        #expect(config.scope == "project")
        #expect(config.resolvedScope == "project")
    }

    @Test("MCPServerConfig resolvedScope defaults to local when nil")
    func mcpServerConfigDefaultScope() {
        let config = MCPServerConfig(name: "test", command: "node", args: [], env: [:])
        #expect(config.scope == nil)
        #expect(config.resolvedScope == "local")
    }

    @Test("ExternalScope includes local variant")
    func externalScopeLocal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        let yaml = """
            schemaVersion: 1
            identifier: scope-test
            displayName: Scope Test
            description: Test scope
            version: "1.0.0"
            components:
              - id: scope-test.server
                displayName: Server
                description: A server
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: test-mcp
                  command: node
                  args: ["server.js"]
                  scope: local
            """
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let manifest = try ExternalPackManifest.load(from: file)
        let component = manifest.components!.first!
        if case .mcpServer(let config) = component.installAction {
            #expect(config.scope == .local)
        } else {
            Issue.record("Expected mcpServer action")
        }
    }

    // MARK: - Component with doctor checks

    @Test("Component with inline doctor checks deserializes correctly")
    func componentWithDoctorChecks() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.server
                displayName: Server
                description: A server
                type: mcpServer
                installAction:
                  type: mcpServer
                  name: server
                  command: npx
                  args: ["-y", "server@latest"]
                doctorChecks:
                  - type: fileExists
                    name: Server config
                    section: Configuration
                    path: ~/.server/config.json
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let component = manifest.components![0]

        #expect(component.doctorChecks?.count == 1)
        #expect(component.doctorChecks?[0].type == .fileExists)
        #expect(component.doctorChecks?[0].name == "Server config")
    }

    // MARK: - Default values

    @Test("Component defaults: dependencies is nil, isRequired is nil")
    func componentDefaults() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            components:
              - id: test.basic
                displayName: Basic
                description: A basic component
                type: configuration
                installAction:
                  type: settingsMerge
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let component = manifest.components![0]

        #expect(component.dependencies == nil)
        #expect(component.isRequired == nil)
        #expect(component.doctorChecks == nil)
    }

    // MARK: - Hook contribution default position

    @Test("Hook contribution without position defaults to nil")
    func hookContributionDefaultPosition() throws {
        let yaml = """
            schemaVersion: 1
            identifier: test
            displayName: Test
            description: Test
            version: "1.0.0"
            hookContributions:
              - hookName: session_start
                fragmentFile: hooks/fragment.sh
            """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(manifest.hookContributions?[0].position == nil)
    }
}
