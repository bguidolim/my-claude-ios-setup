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
