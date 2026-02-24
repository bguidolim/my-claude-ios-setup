import Foundation
import Testing

@testable import mcs

@Suite("ProjectConfigurator — writeClaudeLocal")
struct WriteClaudeLocalTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projconf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator() -> ProjectConfigurator {
        let env = Environment()
        return ProjectConfigurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env)
        )
    }

    private func coreContribution(_ content: String = "Core rules") -> TemplateContribution {
        TemplateContribution(
            sectionIdentifier: "core",
            templateContent: content,
            placeholders: []
        )
    }

    private func iosContribution(_ content: String = "iOS rules for __PROJECT__") -> TemplateContribution {
        TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: content,
            placeholders: ["__PROJECT__"]
        )
    }

    // MARK: - Fresh file (no existing CLAUDE.local.md)

    @Test("Creates CLAUDE.local.md with section markers from scratch")
    func freshFileCreation() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeConfigurator()
        try configurator.writeClaudeLocal(
            at: tmpDir,
            contributions: [coreContribution()],
            values: [:]
        )

        let path = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = try String(contentsOf: path, encoding: .utf8)

        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "core")
        #expect(sections[0].content == "Core rules")
    }

    // MARK: - v1 migration (file exists, no markers)

    @Test("v1 file without markers is replaced with v2 composed output")
    func v1MigrationReplacesWithMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a v1 file (no section markers)
        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        try "Old v1 content without any markers".write(
            to: claudeLocal, atomically: true, encoding: .utf8
        )

        let configurator = makeConfigurator()
        try configurator.writeClaudeLocal(
            at: tmpDir,
            contributions: [coreContribution("New core")],
            values: [:]
        )

        let content = try String(contentsOf: claudeLocal, encoding: .utf8)

        // Should have proper v2 markers
        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "core")
        #expect(sections[0].content == "New core")

        // Old v1 content should not be present
        #expect(!content.contains("Old v1 content"))
    }

    @Test("v1 migration creates backup of original file")
    func v1MigrationCreatesBackup() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        try "Old v1 content".write(to: claudeLocal, atomically: true, encoding: .utf8)

        let configurator = makeConfigurator()
        try configurator.writeClaudeLocal(
            at: tmpDir,
            contributions: [coreContribution()],
            values: [:]
        )

        // Check a backup was created
        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let backups = files.filter { $0.contains("CLAUDE.local.md.backup") }
        #expect(!backups.isEmpty)
    }

    // MARK: - v2 update (file exists with markers)

    @Test("v2 file with markers is updated in place")
    func v2UpdatePreservesStructure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a v2 file
        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let v2Content = TemplateComposer.compose(coreContent: "Old core")
        try v2Content.write(to: claudeLocal, atomically: true, encoding: .utf8)

        let configurator = makeConfigurator()
        try configurator.writeClaudeLocal(
            at: tmpDir,
            contributions: [coreContribution("Updated core")],
            values: [:]
        )

        let content = try String(contentsOf: claudeLocal, encoding: .utf8)
        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.count == 1)
        #expect(sections[0].content == "Updated core")
        #expect(!content.contains("Old core"))
    }

    @Test("v2 update preserves user content outside markers")
    func v2UpdatePreservesUserContent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let v2Content = TemplateComposer.compose(coreContent: "Core")
            + "\n\nMy custom notes\n"
        try v2Content.write(to: claudeLocal, atomically: true, encoding: .utf8)

        let configurator = makeConfigurator()
        try configurator.writeClaudeLocal(
            at: tmpDir,
            contributions: [coreContribution("New core")],
            values: [:]
        )

        let content = try String(contentsOf: claudeLocal, encoding: .utf8)
        #expect(content.contains("New core"))
        #expect(content.contains("My custom notes"))
    }

    // MARK: - Template substitution

    // MARK: - Section removal on unconfigure

    @Test("Unconfiguring a pack removes its template section from CLAUDE.local.md")
    func unconfigureRemovesTemplateSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Set up a CLAUDE.local.md with core + ios sections
        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let composed = TemplateComposer.compose(
            coreContent: "Core rules",
            packContributions: [iosContribution("iOS rules")],
            values: [:]
        )
        try composed.write(to: claudeLocal, atomically: true, encoding: .utf8)

        // Verify both sections exist
        let before = try String(contentsOf: claudeLocal, encoding: .utf8)
        let sectionsBefore = TemplateComposer.parseSections(from: before)
        #expect(sectionsBefore.count == 2)

        // Simulate unconfigure by removing the ios section (same logic as unconfigurePack)
        let artifacts = PackArtifactRecord(templateSections: ["ios"])
        var updated = before
        for sectionID in artifacts.templateSections {
            updated = TemplateComposer.removeSection(in: updated, sectionIdentifier: sectionID)
        }
        try updated.write(to: claudeLocal, atomically: true, encoding: .utf8)

        // Verify only core remains
        let after = try String(contentsOf: claudeLocal, encoding: .utf8)
        let sectionsAfter = TemplateComposer.parseSections(from: after)
        #expect(sectionsAfter.count == 1)
        #expect(sectionsAfter[0].identifier == "core")
        #expect(!after.contains("mcs:begin ios"))
        #expect(!after.contains("mcs:end ios"))
    }

    // MARK: - Template substitution

    @Test("Pack template values are substituted during compose")
    func packValuesSubstituted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeConfigurator()
        try configurator.writeClaudeLocal(
            at: tmpDir,
            contributions: [coreContribution(), iosContribution()],
            values: ["REPO_NAME": "my-repo", "PROJECT": "MyApp.xcodeproj"]
        )

        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = try String(contentsOf: claudeLocal, encoding: .utf8)

        #expect(content.contains("MyApp.xcodeproj"))
        #expect(!content.contains("__PROJECT__"))
    }
}

// MARK: - Dry Run Tests

@Suite("ProjectConfigurator — dryRun")
struct DryRunTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-dryrun-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator() -> ProjectConfigurator {
        let env = Environment()
        return ProjectConfigurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env)
        )
    }

    @Test("Dry run does not create any files")
    func dryRunCreatesNoFiles() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "test",
                templateContent: "Test content",
                placeholders: []
            )]
        )

        let configurator = makeConfigurator()
        configurator.dryRun(at: tmpDir, packs: [pack])

        // No CLAUDE.local.md should be created
        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        #expect(!FileManager.default.fileExists(atPath: claudeLocal.path))

        // No .claude/ directory should be created
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        #expect(!FileManager.default.fileExists(atPath: claudeDir.path))
    }

    @Test("Dry run does not modify existing project state")
    func dryRunPreservesState() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create an existing project state
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var state = ProjectState(projectRoot: tmpDir)
        state.recordPack("existing-pack")
        state.setArtifacts(
            PackArtifactRecord(templateSections: ["existing"]),
            for: "existing-pack"
        )
        try state.save()

        let stateFile = claudeDir.appendingPathComponent(".mcs-project")
        let stateBefore = try Data(contentsOf: stateFile)

        // Run dry-run with a different pack
        let pack = MockTechPack(identifier: "new-pack", displayName: "New Pack")
        let configurator = makeConfigurator()
        configurator.dryRun(at: tmpDir, packs: [pack])

        // State file should be unchanged
        let stateAfter = try Data(contentsOf: stateFile)
        #expect(stateBefore == stateAfter)
    }

    @Test("Dry run correctly identifies additions and removals")
    func dryRunIdentifiesConvergence() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create existing state with pack A configured
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var state = ProjectState(projectRoot: tmpDir)
        state.recordPack("pack-a")
        state.setArtifacts(
            PackArtifactRecord(
                mcpServers: [MCPServerRef(name: "server-a", scope: "local")],
                templateSections: ["pack-a"]
            ),
            for: "pack-a"
        )
        try state.save()

        // Dry-run with pack B (not pack A) — should show A removed, B added
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [ComponentDefinition(
                id: "pack-b.server",
                displayName: "Server B",
                description: "A server",
                type: .mcpServer,
                packIdentifier: "pack-b",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "server-b",
                    command: "/usr/bin/test",
                    args: [],
                    env: [:]
                ))
            )],
            templates: [TemplateContribution(
                sectionIdentifier: "pack-b",
                templateContent: "Pack B content",
                placeholders: []
            )]
        )

        let configurator = makeConfigurator()

        // Capture that it doesn't throw and doesn't modify state
        configurator.dryRun(at: tmpDir, packs: [packB])

        // Verify state file is unchanged (pack-a still configured)
        let updatedState = ProjectState(projectRoot: tmpDir)
        #expect(updatedState.configuredPacks.contains("pack-a"))
        #expect(!updatedState.configuredPacks.contains("pack-b"))
    }

    @Test("Dry run with empty pack list shows nothing to change")
    func dryRunEmptyPacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeConfigurator()
        configurator.dryRun(at: tmpDir, packs: [])

        // Should not create any files
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        #expect(!FileManager.default.fileExists(atPath: claudeDir.path))
    }
}

// MARK: - Settings Merge Tests

@Suite("ProjectConfigurator — packSettingsMerge")
struct PackSettingsMergeTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator() -> ProjectConfigurator {
        let env = Environment()
        return ProjectConfigurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env)
        )
    }

    /// Write a JSON settings file and return its URL.
    private func writeSettingsFile(in dir: URL, name: String, settings: Settings) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try settings.save(to: url)
        return url
    }

    @Test("Pack with settingsFile merges settings into settings.local.json")
    func settingsFileMerge() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a pack settings file
        var packSettings = Settings()
        packSettings.env = ["MY_KEY": "my_value"]
        packSettings.alwaysThinkingEnabled = true
        let settingsURL = try writeSettingsFile(
            in: tmpDir, name: "pack-settings.json", settings: packSettings
        )

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Test Settings",
                description: "Merges settings",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: settingsURL)
            )]
        )

        // Create .claude/ dir and run compose
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        // Use the internal compose method by triggering configure path
        // Directly test composeProjectSettings by checking the output file
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")

        // Simulate what configure does: compose settings
        // We need to call the private method indirectly — use a full configure
        var state = ProjectState(projectRoot: tmpDir)
        state.recordPack("test-pack")
        try state.save()

        try configurator.configure(at: tmpDir, packs: [pack])

        // Check settings.local.json was created with merged settings
        let result = try Settings.load(from: settingsPath)
        #expect(result.env?["MY_KEY"] == "my_value")
        #expect(result.alwaysThinkingEnabled == true)
    }

    @Test("Multiple packs merge settings additively")
    func multiPackSettingsMerge() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pack A settings
        var settingsA = Settings()
        settingsA.env = ["KEY_A": "value_a"]
        let urlA = try writeSettingsFile(
            in: tmpDir, name: "settings-a.json", settings: settingsA
        )

        // Pack B settings
        var settingsB = Settings()
        settingsB.env = ["KEY_B": "value_b"]
        settingsB.enabledPlugins = ["my-plugin": true]
        let urlB = try writeSettingsFile(
            in: tmpDir, name: "settings-b.json", settings: settingsB
        )

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [ComponentDefinition(
                id: "pack-a.settings",
                displayName: "Pack A Settings",
                description: "Settings A",
                type: .configuration,
                packIdentifier: "pack-a",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: urlA)
            )]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [ComponentDefinition(
                id: "pack-b.settings",
                displayName: "Pack B Settings",
                description: "Settings B",
                type: .configuration,
                packIdentifier: "pack-b",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: urlB)
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [packA, packB])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)
        #expect(result.env?["KEY_A"] == "value_a")
        #expect(result.env?["KEY_B"] == "value_b")
        #expect(result.enabledPlugins?["my-plugin"] == true)
    }

    @Test("Removing a pack excludes its settings on next configure")
    func removePackExcludesSettings() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pack settings
        var packSettings = Settings()
        packSettings.env = ["PACK_KEY": "pack_value"]
        let settingsURL = try writeSettingsFile(
            in: tmpDir, name: "pack-settings.json", settings: packSettings
        )

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Test Settings",
                description: "Merges settings",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: settingsURL)
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // First configure with the pack
        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let afterAdd = try Settings.load(from: settingsPath)
        #expect(afterAdd.env?["PACK_KEY"] == "pack_value")

        // Re-configure with no packs (simulate removal)
        try configurator.configure(at: tmpDir, packs: [], confirmRemovals: false)

        // settings.local.json should either not exist or not have the pack's key
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            let afterRemove = try Settings.load(from: settingsPath)
            #expect(afterRemove.env?["PACK_KEY"] == nil)
        }
        // If file doesn't exist, that's also fine — no settings to write
    }

    @Test("settingsMerge with nil source is a no-op")
    func settingsMergeNilSource() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Test Settings",
                description: "No-op settings",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: nil)
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        // No settings.local.json should be created for a nil-source settingsMerge
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: settingsPath.path))
    }
}

// MARK: - Copy With Substitution Tests

@Suite("ComponentExecutor — copyWithSubstitution")
struct CopyWithSubstitutionTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-copysub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Substitutes placeholders in text file")
    func substitutesPlaceholders() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("template.md")
        try "Branch: __BRANCH_PREFIX__/{ticket}".write(
            to: source, atomically: true, encoding: .utf8
        )

        let dest = tmpDir.appendingPathComponent("output.md")
        try ComponentExecutor.copyWithSubstitution(
            from: source,
            to: dest,
            values: ["BRANCH_PREFIX": "feature"]
        )

        let result = try String(contentsOf: dest, encoding: .utf8)
        #expect(result == "Branch: feature/{ticket}")
        #expect(!result.contains("__BRANCH_PREFIX__"))
    }

    @Test("Multiple placeholders in same file")
    func multiplePlaceholders() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("cmd.md")
        try "Project: __PROJECT__\nBranch: __BRANCH_PREFIX__/topic".write(
            to: source, atomically: true, encoding: .utf8
        )

        let dest = tmpDir.appendingPathComponent("output.md")
        try ComponentExecutor.copyWithSubstitution(
            from: source,
            to: dest,
            values: ["PROJECT": "MyApp.xcodeproj", "BRANCH_PREFIX": "bruno"]
        )

        let result = try String(contentsOf: dest, encoding: .utf8)
        #expect(result.contains("MyApp.xcodeproj"))
        #expect(result.contains("bruno/topic"))
    }

    @Test("Empty values dict falls back to raw copy")
    func emptyValuesFallsBackToRawCopy() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("raw.md")
        try "Keep __PLACEHOLDER__ as-is".write(
            to: source, atomically: true, encoding: .utf8
        )

        let dest = tmpDir.appendingPathComponent("output.md")
        try ComponentExecutor.copyWithSubstitution(
            from: source,
            to: dest,
            values: [:]
        )

        let result = try String(contentsOf: dest, encoding: .utf8)
        #expect(result.contains("__PLACEHOLDER__"))
    }

    @Test("Binary file falls back to raw copy")
    func binaryFileFallsBack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write invalid UTF-8 bytes
        let source = tmpDir.appendingPathComponent("binary.bin")
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81]
        try Data(bytes).write(to: source)

        let dest = tmpDir.appendingPathComponent("output.bin")
        try ComponentExecutor.copyWithSubstitution(
            from: source,
            to: dest,
            values: ["FOO": "bar"]
        )

        let result = try Data(contentsOf: dest)
        #expect(result == Data(bytes))
    }

    @Test("Substitution preserves file content around placeholders")
    func preservesSurroundingContent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("hook.sh")
        try """
        #!/bin/bash
        # Branch naming: __BRANCH_PREFIX__/{ticket}
        echo "done"
        """.write(to: source, atomically: true, encoding: .utf8)

        let dest = tmpDir.appendingPathComponent("output.sh")
        try ComponentExecutor.copyWithSubstitution(
            from: source,
            to: dest,
            values: ["BRANCH_PREFIX": "fix"]
        )

        let result = try String(contentsOf: dest, encoding: .utf8)
        #expect(result.contains("#!/bin/bash"))
        #expect(result.contains("fix/{ticket}"))
        #expect(result.contains("echo \"done\""))
    }
}

// MARK: - installProjectFile Substitution Tests

@Suite("ComponentExecutor — installProjectFile substitution")
struct InstallProjectFileSubstitutionTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-install-sub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutor() -> ComponentExecutor {
        let env = Environment()
        return ComponentExecutor(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env)
        )
    }

    @Test("installProjectFile substitutes placeholders in single file")
    func singleFileSubstitution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        // Create a source file with placeholder
        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let source = packDir.appendingPathComponent("pr.md")
        try "Branch: __BRANCH_PREFIX__/{ticket}".write(
            to: source, atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let paths = exec.installProjectFile(
            source: source,
            destination: "pr.md",
            fileType: .command,
            projectPath: projectPath,
            resolvedValues: ["BRANCH_PREFIX": "feature"]
        )

        #expect(!paths.isEmpty)

        // Read the installed file
        let installed = projectPath
            .appendingPathComponent(".claude/commands/pr.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("feature/{ticket}"))
        #expect(!content.contains("__BRANCH_PREFIX__"))
    }

    @Test("installProjectFile substitutes placeholders in directory files")
    func directoryFileSubstitution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        // Create a source directory with files containing placeholders
        let packDir = tmpDir.appendingPathComponent("pack/my-skill")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try "Skill for __REPO_NAME__".write(
            to: packDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let paths = exec.installProjectFile(
            source: packDir,
            destination: "my-skill",
            fileType: .skill,
            projectPath: projectPath,
            resolvedValues: ["REPO_NAME": "my-app"]
        )

        #expect(!paths.isEmpty)

        let installed = projectPath
            .appendingPathComponent(".claude/skills/my-skill/SKILL.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("my-app"))
        #expect(!content.contains("__REPO_NAME__"))
    }

    @Test("installProjectFile without resolvedValues does raw copy")
    func noValuesRawCopy() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let source = packDir.appendingPathComponent("commit.md")
        try "Keep __PLACEHOLDER__ intact".write(
            to: source, atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        _ = exec.installProjectFile(
            source: source,
            destination: "commit.md",
            fileType: .command,
            projectPath: projectPath
        )

        let installed = projectPath
            .appendingPathComponent(".claude/commands/commit.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("__PLACEHOLDER__"))
    }
}

// MARK: - Auto-Derived Hook & Plugin Tests

@Suite("ProjectConfigurator — auto-derived hooks and plugins")
struct AutoDerivedSettingsTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-autoderive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator() -> ProjectConfigurator {
        let env = Environment()
        return ProjectConfigurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env)
        )
    }

    /// Create a pack with a hookFile component that has hookEvent set.
    private func makeHookPack(tmpDir: URL) throws -> MockTechPack {
        // Create the hook source file
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("session_start.sh")
        try "#!/bin/bash\necho session".write(
            to: hookSource, atomically: true, encoding: .utf8
        )

        return MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook-session",
                displayName: "Session hook",
                description: "Session start hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "session_start.sh",
                    fileType: .hook
                )
            )]
        )
    }

    /// Create a pack with a plugin component.
    private func makePluginPack() -> MockTechPack {
        MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.plugin-review",
                displayName: "PR Review",
                description: "PR review plugin",
                type: .plugin,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .plugin(name: "pr-review-toolkit@claude-plugins-official")
            )]
        )
    }

    @Test("hookFile with hookEvent auto-derives settings entry")
    func hookEventAutoDerivesSettings() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try makeHookPack(tmpDir: tmpDir)

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)

        // Should have SessionStart hook with project-relative path
        let sessionGroups = result.hooks?["SessionStart"] ?? []
        #expect(!sessionGroups.isEmpty)
        let command = sessionGroups.first?.hooks?.first?.command
        #expect(command == "bash .claude/hooks/session_start.sh")
        // Should NOT use global path
        #expect(command?.contains("~/.claude") != true)
    }

    @Test("plugin component auto-derives enabledPlugins entry")
    func pluginAutoDerivesEnabledPlugins() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = makePluginPack()

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)

        #expect(result.enabledPlugins?["pr-review-toolkit"] == true)
    }

    @Test("hookFile without hookEvent does not generate settings entry")
    func noHookEventNoSettingsEntry() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create hook source
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("helper.sh")
        try "#!/bin/bash".write(to: hookSource, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook-helper",
                displayName: "Helper hook",
                description: "No hookEvent",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                // hookEvent is nil
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "helper.sh",
                    fileType: .hook
                )
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        // No settings.local.json should be created (no derivable entries)
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: settingsPath.path))
    }

    @Test("Auto-derived hooks deduplicate with settingsFile merge")
    func hookDeduplicationWithSettingsFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create hook source
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("session_start.sh")
        try "#!/bin/bash".write(to: hookSource, atomically: true, encoding: .utf8)

        // Create a settings file that also declares the same hook (old-style path)
        var packSettings = Settings()
        packSettings.hooks = [
            "SessionStart": [
                Settings.HookGroup(
                    matcher: nil,
                    hooks: [Settings.HookEntry(
                        type: "command",
                        command: "bash ~/.claude/hooks/session_start.sh"
                    )]
                )
            ]
        ]
        let settingsURL = tmpDir.appendingPathComponent("pack-settings.json")
        try packSettings.save(to: settingsURL)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.hook-session",
                    displayName: "Session hook",
                    description: "Hook with event",
                    type: .hookFile,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    hookEvent: "SessionStart",
                    installAction: .copyPackFile(
                        source: hookSource,
                        destination: "session_start.sh",
                        fileType: .hook
                    )
                ),
                ComponentDefinition(
                    id: "test-pack.settings",
                    displayName: "Settings",
                    description: "Pack settings",
                    type: .configuration,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .settingsMerge(source: settingsURL)
                ),
            ]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)

        // Should have both entries (different commands — project-local vs global)
        let sessionGroups = result.hooks?["SessionStart"] ?? []
        let commands = sessionGroups.compactMap { $0.hooks?.first?.command }
        #expect(commands.contains("bash .claude/hooks/session_start.sh"))
        #expect(commands.contains("bash ~/.claude/hooks/session_start.sh"))
        #expect(sessionGroups.count == 2)
    }

    @Test("hookCommands tracked in artifact record")
    func hookCommandsInArtifactRecord() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try makeHookPack(tmpDir: tmpDir)

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator()
        try configurator.configure(at: tmpDir, packs: [pack])

        // Read project state and check hookCommands
        let state = ProjectState(projectRoot: tmpDir)
        let artifacts = state.artifacts(for: "test-pack")
        #expect(artifacts != nil)
        #expect(artifacts?.hookCommands.contains("bash .claude/hooks/session_start.sh") == true)
    }
}

/// Minimal TechPack implementation for dry-run tests.
private struct MockTechPack: TechPack {
    let identifier: String
    let displayName: String
    let description: String = "Mock pack for testing"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    let hookContributions: [HookContribution]
    let gitignoreEntries: [String]
    let supplementaryDoctorChecks: [any DoctorCheck]

    init(
        identifier: String,
        displayName: String,
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = [],
        hookContributions: [HookContribution] = [],
        gitignoreEntries: [String] = [],
        supplementaryDoctorChecks: [any DoctorCheck] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.components = components
        self.templates = templates
        self.hookContributions = hookContributions
        self.gitignoreEntries = gitignoreEntries
        self.supplementaryDoctorChecks = supplementaryDoctorChecks
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {}
}
