import CryptoKit
import Foundation
import Testing

@testable import mcs

@Suite("Manifest")
struct ManifestTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-manifest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - SHA-256 hashing

    @Test("Compute file hash for known content produces expected SHA-256")
    func knownHash() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let hash = try Manifest.sha256(of: file)

        // SHA-256 of "hello\n"
        let expected = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        #expect(hash == expected)
    }

    // MARK: - Record and verify

    @Test("Record a file hash and verify it hasn't changed")
    func recordAndVerify() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        let sourceFile = tmpDir.appendingPathComponent("source.txt")
        try "original content".write(to: sourceFile, atomically: true, encoding: .utf8)

        var manifest = Manifest(path: manifestFile)
        try manifest.record(relativePath: "source.txt", sourceFile: sourceFile)
        try manifest.save()

        // Reload and check
        let loaded = Manifest(path: manifestFile)
        let result = loaded.check(relativePath: "source.txt", installedFile: sourceFile)
        #expect(result == true)
    }

    @Test("Detect hash change when file is modified")
    func detectModification() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        let sourceFile = tmpDir.appendingPathComponent("source.txt")
        try "original".write(to: sourceFile, atomically: true, encoding: .utf8)

        var manifest = Manifest(path: manifestFile)
        try manifest.record(relativePath: "source.txt", sourceFile: sourceFile)
        try manifest.save()

        // Modify the file
        try "modified content".write(to: sourceFile, atomically: true, encoding: .utf8)

        // Reload and check
        let loaded = Manifest(path: manifestFile)
        let result = loaded.check(relativePath: "source.txt", installedFile: sourceFile)
        #expect(result == false) // Drift detected
    }

    // MARK: - Missing manifest / file

    @Test("Handle missing manifest file gracefully")
    func missingManifest() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        // Should not throw; just starts with empty entries
        let manifest = Manifest(path: nonexistent)
        #expect(manifest.trackedPaths.isEmpty)
    }

    @Test("Check returns nil for untracked relative path")
    func checkUntrackedPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        let someFile = tmpDir.appendingPathComponent("some.txt")
        try "data".write(to: someFile, atomically: true, encoding: .utf8)

        let manifest = Manifest(path: manifestFile)
        let result = manifest.check(relativePath: "unknown.txt", installedFile: someFile)
        #expect(result == nil) // No record exists
    }

    // MARK: - trackedPaths

    @Test("trackedPaths returns sorted list of recorded files")
    func trackedPaths() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        let fileA = tmpDir.appendingPathComponent("a.txt")
        let fileB = tmpDir.appendingPathComponent("b.txt")
        try "a".write(to: fileA, atomically: true, encoding: .utf8)
        try "b".write(to: fileB, atomically: true, encoding: .utf8)

        var manifest = Manifest(path: manifestFile)
        try manifest.record(relativePath: "b.txt", sourceFile: fileB)
        try manifest.record(relativePath: "a.txt", sourceFile: fileA)

        #expect(manifest.trackedPaths == ["a.txt", "b.txt"])
    }

    // MARK: - Installed packs tracking

    @Test("Record and retrieve installed packs")
    func installedPacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/test")

        #expect(manifest.installedPacks.isEmpty)

        manifest.recordInstalledPack("ios")
        manifest.recordInstalledPack("web")
        #expect(manifest.installedPacks == Set(["ios", "web"]))

        // Duplicate insert is idempotent
        manifest.recordInstalledPack("ios")
        #expect(manifest.installedPacks.count == 2)

        try manifest.save()

        // Reload preserves packs
        let loaded = Manifest(path: manifestFile)
        #expect(loaded.installedPacks == Set(["ios", "web"]))
    }

    @Test("Initialize preserves installed packs")
    func initializePreservesPacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/v1")
        manifest.recordInstalledPack("ios")
        try manifest.save()

        // Re-initialize (simulates re-running install)
        var reloaded = Manifest(path: manifestFile)
        reloaded.initialize(sourceDirectory: "/v2")
        #expect(reloaded.installedPacks == Set(["ios"]))
    }

    // MARK: - Installed components tracking

    @Test("Record and retrieve installed components")
    func installedComponents() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/test")

        #expect(manifest.installedComponents.isEmpty)

        manifest.recordInstalledComponent("core.serena")
        manifest.recordInstalledComponent("core.docs-mcp-server")
        #expect(manifest.installedComponents == Set(["core.serena", "core.docs-mcp-server"]))

        // Duplicate insert is idempotent
        manifest.recordInstalledComponent("core.serena")
        #expect(manifest.installedComponents.count == 2)

        try manifest.save()

        // Reload preserves components
        let loaded = Manifest(path: manifestFile)
        #expect(loaded.installedComponents == Set(["core.serena", "core.docs-mcp-server"]))
    }

    @Test("Initialize clears installed components")
    func initializeClearsComponents() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/v1")
        manifest.recordInstalledComponent("core.serena")
        try manifest.save()

        // Re-initialize (simulates re-running install)
        var reloaded = Manifest(path: manifestFile)
        reloaded.initialize(sourceDirectory: "/v2")
        #expect(reloaded.installedComponents.isEmpty)
    }

    @Test("Initialize preserves file hash entries")
    func initializePreservesFileHashes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        let sourceFile = tmpDir.appendingPathComponent("hook.sh")
        try "#!/bin/bash\necho hello".write(to: sourceFile, atomically: true, encoding: .utf8)

        // First install: record file hash
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/v1")
        try manifest.record(relativePath: "hooks/session_start.sh", sourceFile: sourceFile)
        try manifest.save()

        // Re-initialize (simulates second install run)
        var reloaded = Manifest(path: manifestFile)
        reloaded.initialize(sourceDirectory: "/v2")

        // File hash entries should be preserved
        #expect(reloaded.trackedPaths.contains("hooks/session_start.sh"))
        #expect(reloaded.check(relativePath: "hooks/session_start.sh", installedFile: sourceFile) == true)
    }

    // MARK: - Persistence round-trip

    @Test("Metadata heuristic classifies file paths correctly")
    func metadataHeuristic() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")

        // Write a manifest with metadata and a file path that could confuse heuristics
        let content = """
        SCRIPT_DIR=/test/path
        INSTALLED_PACKS=ios,web
        INSTALLED_COMPONENTS=core.serena,core.docs-mcp-server
        hooks/session_start.sh=abc123
        skills/continuous-learning=def456
        config/settings.json=ghi789
        """
        try content.write(to: manifestFile, atomically: true, encoding: .utf8)

        let manifest = Manifest(path: manifestFile)

        // Metadata should be recognized
        #expect(manifest.scriptDir == "/test/path")
        #expect(manifest.installedPacks == Set(["ios", "web"]))
        #expect(manifest.installedComponents == Set(["core.serena", "core.docs-mcp-server"]))

        // File entries should not be treated as metadata
        #expect(manifest.trackedPaths.contains("hooks/session_start.sh"))
        #expect(manifest.trackedPaths.contains("skills/continuous-learning"))
        #expect(manifest.trackedPaths.contains("config/settings.json"))
        // Metadata should NOT appear in trackedPaths
        #expect(!manifest.trackedPaths.contains("INSTALLED_COMPONENTS"))
    }

    @Test("Manifest save and reload preserves all entries")
    func saveReloadRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        let fileA = tmpDir.appendingPathComponent("a.txt")
        let fileB = tmpDir.appendingPathComponent("b.txt")
        try "alpha".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta".write(to: fileB, atomically: true, encoding: .utf8)

        var manifest = Manifest(path: manifestFile)
        try manifest.record(relativePath: "a.txt", sourceFile: fileA)
        try manifest.record(relativePath: "b.txt", sourceFile: fileB)
        try manifest.save()

        // Reload
        let loaded = Manifest(path: manifestFile)
        #expect(loaded.trackedPaths == ["a.txt", "b.txt"])
        #expect(loaded.check(relativePath: "a.txt", installedFile: fileA) == true)
        #expect(loaded.check(relativePath: "b.txt", installedFile: fileB) == true)
    }
}
