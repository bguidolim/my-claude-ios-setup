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

    // MARK: - Persistence round-trip

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
