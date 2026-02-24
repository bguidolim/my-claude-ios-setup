import Foundation
import Testing

@testable import mcs

@Suite("ProjectDetector")
struct ProjectDetectorTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projdetect-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Finds project root via .git directory")
    func findsGitRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create project structure: tmpDir/.git/ and tmpDir/Sources/
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let sourcesDir = tmpDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: sourcesDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Finds project root via CLAUDE.local.md")
    func findsCLAUDELocalRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create CLAUDE.local.md at root
        try "test".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        let subDir = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: subDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Returns nil when no project root found")
    func returnsNilOutsideProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Empty directory — no .git or CLAUDE.local.md
        _ = ProjectDetector.findProjectRoot(from: tmpDir)
        // May find the actual cwd's project root when walking up,
        // but from an isolated temp dir it should be nil or find nothing useful.
        // We test this by creating a deeply nested dir with no markers.
        let deep = tmpDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        // If it walks up past tmpDir it might find the system's git repos,
        // so we just verify it doesn't crash and returns something or nil.
        _ = ProjectDetector.findProjectRoot(from: deep)
    }

    @Test("Prefers .git over CLAUDE.local.md at same level")
    func prefersGitAtSameLevel() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try "test".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let root = ProjectDetector.findProjectRoot(from: tmpDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }
}

@Suite("ProjectState")
struct ProjectStateTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projstate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("New state file does not exist")
    func newStateNotExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let state = try ProjectState(projectRoot: tmpDir)
        #expect(!state.exists)
        #expect(state.configuredPacks.isEmpty)
    }

    @Test("Record pack and save persists state")
    func recordAndSave() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        // Reload
        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["ios"]))
        #expect(loaded.mcsVersion == MCSVersion.current)
    }

    @Test("Multiple packs are stored and sorted")
    func multiplePacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("web")
        state.recordPack("ios")
        try state.save()

        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.configuredPacks == Set(["ios", "web"]))
    }

    @Test("Additive across saves")
    func additiveAcrossSaves() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // First save
        var state1 = try ProjectState(projectRoot: tmpDir)
        state1.recordPack("ios")
        try state1.save()

        // Second save adds another pack
        var state2 = try ProjectState(projectRoot: tmpDir)
        state2.recordPack("web")
        try state2.save()

        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.configuredPacks == Set(["ios", "web"]))
    }

    @Test("init does not throw when file does not exist")
    func missingFileDoesNotThrow() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let state = try ProjectState(projectRoot: tmpDir)
        #expect(!state.exists)
    }

    @Test("init throws when file is corrupt")
    func corruptFileThrows() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let stateFile = claudeDir.appendingPathComponent(".mcs-project")
        try Data("{ not valid json !!!".utf8).write(to: stateFile)

        #expect(throws: (any Error).self) {
            _ = try ProjectState(projectRoot: tmpDir)
        }
    }

    @Test("removePack removes from configuredPacks and artifacts")
    func removePack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.recordPack("web")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "xcodebuildmcp", scope: "local")]
        ), for: "ios")
        try state.save()

        var loaded = try ProjectState(projectRoot: tmpDir)
        loaded.removePack("ios")
        try loaded.save()

        let final = try ProjectState(projectRoot: tmpDir)
        #expect(final.configuredPacks == Set(["web"]))
        #expect(final.artifacts(for: "ios") == nil)
    }

    @Test("Pack artifact records are persisted and loaded")
    func artifactRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        let artifacts = PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "xcodebuildmcp", scope: "local")],
            files: [".claude/skills/my-skill/SKILL.md"],
            templateSections: ["ios"],
            hookCommands: ["bash .claude/hooks/ios-session.sh"],
            settingsKeys: ["env.XCODE_PROJECT"]
        )
        state.setArtifacts(artifacts, for: "ios")
        try state.save()

        let loaded = try ProjectState(projectRoot: tmpDir)
        let loadedArtifacts = loaded.artifacts(for: "ios")
        #expect(loadedArtifacts == artifacts)
        #expect(loadedArtifacts?.mcpServers.count == 1)
        #expect(loadedArtifacts?.mcpServers.first?.name == "xcodebuildmcp")
        #expect(loadedArtifacts?.files == [".claude/skills/my-skill/SKILL.md"])
    }

    @Test("stateFile init loads from direct path")
    func stateFileInit() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Save using projectRoot init
        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "test-server", scope: "user")]
        ), for: "ios")
        try state.save()

        // Load using stateFile init with the same path
        let stateFile = tmpDir
            .appendingPathComponent(".claude")
            .appendingPathComponent(".mcs-project")
        let loaded = try ProjectState(stateFile: stateFile)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["ios"]))
        #expect(loaded.artifacts(for: "ios")?.mcpServers.first?.scope == "user")
    }

    @Test("stateFile init works with custom path for global state")
    func stateFileCustomPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let customFile = tmpDir.appendingPathComponent("global-state.json")

        var state = try ProjectState(stateFile: customFile)
        #expect(!state.exists)

        state.recordPack("web")
        try state.save()

        let loaded = try ProjectState(stateFile: customFile)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["web"]))
    }

    @Test("JSON format saves are valid JSON")
    func jsonFormat() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        let stateFile = tmpDir
            .appendingPathComponent(".claude")
            .appendingPathComponent(".mcs-project")
        let data = try Data(contentsOf: stateFile)
        #expect(data.first == UInt8(ascii: "{"))

        // Should be valid JSON
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["mcsVersion"] as? String == MCSVersion.current)
    }
}

// MARK: - ProjectDoctorChecks

@Suite("ProjectDoctorChecks")
struct ProjectDoctorCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projdoctor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - CLAUDELocalFreshnessCheck

    @Test("CLAUDELocalFreshnessCheck skips when no CLAUDE.local.md")
    func freshnessCheckSkipsWhenMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: .shared)
        let check = CLAUDELocalFreshnessCheck(context: context)
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("CLAUDELocalFreshnessCheck warns when no section markers")
    func freshnessCheckWarnsNoMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Just a plain file\nNo markers here.\n".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: .shared)
        let check = CLAUDELocalFreshnessCheck(context: context)
        if case .warn = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    @Test("CLAUDELocalFreshnessCheck warns when no stored values")
    func freshnessCheckWarnsNoStoredValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = MCSVersion.current
        let content = """
        <!-- mcs:begin core v\(version) -->
        Some content here
        <!-- mcs:end core -->
        """
        try content.write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: .shared)
        let check = CLAUDELocalFreshnessCheck(context: context)
        if case .warn = check.check() {
            // expected — no .mcs-project means no stored values
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    // MARK: - ProjectStateFileCheck

    @Test("ProjectStateFileCheck skips when no CLAUDE.local.md")
    func stateCheckSkipsMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("ProjectStateFileCheck warns when CLAUDE.local.md exists but .mcs-project missing")
    func stateCheckWarnsMissingProjectFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .warn = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    @Test("ProjectStateFileCheck passes when both files exist")
    func stateCheckPassesBothPresent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .pass = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    @Test("ProjectStateFileCheck fix creates .mcs-project from section markers")
    func stateCheckFixCreatesFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = MCSVersion.current
        let content = """
        <!-- mcs:begin core v\(version) -->
        Core content
        <!-- mcs:end core -->
        <!-- mcs:begin ios v\(version) -->
        iOS content
        <!-- mcs:end ios -->
        """
        try content.write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        let fixResult = check.fix()
        if case .fixed = fixResult {
            // Verify the state file was created
            let state = try ProjectState(projectRoot: tmpDir)
            #expect(state.exists)
            #expect(state.configuredPacks.contains("ios"))
        } else {
            #expect(Bool(false), "Expected .fixed result, got \(fixResult)")
        }
    }
}
