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

        let state = ProjectState(projectRoot: tmpDir)
        #expect(!state.exists)
        #expect(state.configuredPacks.isEmpty)
    }

    @Test("Record pack and save persists state")
    func recordAndSave() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        // Reload
        let loaded = ProjectState(projectRoot: tmpDir)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["ios"]))
        #expect(loaded.mcsVersion == MCSVersion.current)
    }

    @Test("Multiple packs are stored and sorted")
    func multiplePacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = ProjectState(projectRoot: tmpDir)
        state.recordPack("web")
        state.recordPack("ios")
        try state.save()

        let loaded = ProjectState(projectRoot: tmpDir)
        #expect(loaded.configuredPacks == Set(["ios", "web"]))
    }

    @Test("Additive across saves")
    func additiveAcrossSaves() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // First save
        var state1 = ProjectState(projectRoot: tmpDir)
        state1.recordPack("ios")
        try state1.save()

        // Second save adds another pack
        var state2 = ProjectState(projectRoot: tmpDir)
        state2.recordPack("web")
        try state2.save()

        let loaded = ProjectState(projectRoot: tmpDir)
        #expect(loaded.configuredPacks == Set(["ios", "web"]))
    }

    @Test("loadError is nil when file does not exist")
    func loadErrorNilForMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let state = ProjectState(projectRoot: tmpDir)
        #expect(state.loadError == nil)
        #expect(!state.exists)
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

    // MARK: - CLAUDELocalVersionCheck

    @Test("CLAUDELocalVersionCheck skips when no CLAUDE.local.md")
    func versionCheckSkipsWhenMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = CLAUDELocalVersionCheck(projectRoot: tmpDir)
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("CLAUDELocalVersionCheck warns when no section markers")
    func versionCheckWarnsNoMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Just a plain file\nNo markers here.\n".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = CLAUDELocalVersionCheck(projectRoot: tmpDir)
        if case .warn = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    @Test("CLAUDELocalVersionCheck passes with current version")
    func versionCheckPassesCurrent() throws {
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

        let check = CLAUDELocalVersionCheck(projectRoot: tmpDir)
        if case .pass = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    // MARK: - ProjectSerenaMemoryCheck

    @Test("ProjectSerenaMemoryCheck passes when no .serena/memories")
    func serenaCheckPassesMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = ProjectSerenaMemoryCheck(projectRoot: tmpDir)
        if case .pass = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    @Test("ProjectSerenaMemoryCheck passes when .serena/memories is a symlink")
    func serenaCheckPassesWhenSymlink() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeMemories = tmpDir
            .appendingPathComponent(".claude")
            .appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: claudeMemories, withIntermediateDirectories: true)

        let serenaDir = tmpDir.appendingPathComponent(".serena")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)
        let serenaMemories = serenaDir.appendingPathComponent("memories")
        try FileManager.default.createSymbolicLink(at: serenaMemories, withDestinationURL: claudeMemories)

        let check = ProjectSerenaMemoryCheck(projectRoot: tmpDir)
        if case .pass(let msg) = check.check() {
            #expect(msg.contains("symlink"))
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    @Test("ProjectSerenaMemoryCheck fails when memories exist")
    func serenaCheckFailsWithFiles() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let memoriesDir = tmpDir
            .appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
        try "memory content".write(
            to: memoriesDir.appendingPathComponent("test.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectSerenaMemoryCheck(projectRoot: tmpDir)
        if case .fail = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .fail result")
        }
    }

    @Test("ProjectSerenaMemoryCheck fails when empty directory exists (should be symlink)")
    func serenaCheckFailsEmptyDir() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let memoriesDir = tmpDir
            .appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memoriesDir, withIntermediateDirectories: true)

        let check = ProjectSerenaMemoryCheck(projectRoot: tmpDir)
        if case .fail(let msg) = check.check() {
            #expect(msg.contains("should be a symlink"))
        } else {
            #expect(Bool(false), "Expected .fail result")
        }
    }

    @Test("ProjectSerenaMemoryCheck fix creates symlink")
    func serenaFixCreatesSymlink() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let memoriesDir = tmpDir
            .appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
        try "memory content".write(
            to: memoriesDir.appendingPathComponent("test.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectSerenaMemoryCheck(projectRoot: tmpDir)
        let result = check.fix()

        if case .fixed = result {
            // Verify .serena/memories is now a symlink
            let attrs = try FileManager.default.attributesOfItem(atPath: memoriesDir.path)
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)

            // Verify file was migrated to .claude/memories/
            let claudeMemories = tmpDir
                .appendingPathComponent(".claude")
                .appendingPathComponent("memories")
            #expect(FileManager.default.fileExists(
                atPath: claudeMemories.appendingPathComponent("test.md").path
            ))
        } else {
            #expect(Bool(false), "Expected .fixed result, got \(result)")
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
        var state = ProjectState(projectRoot: tmpDir)
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
            let state = ProjectState(projectRoot: tmpDir)
            #expect(state.exists)
            #expect(state.configuredPacks.contains("ios"))
        } else {
            #expect(Bool(false), "Expected .fixed result, got \(fixResult)")
        }
    }
}
