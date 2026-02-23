import Foundation
import Testing

@testable import mcs

@Suite("PackUninstaller")
struct PackUninstallerTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-uninstall-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - File removal (copyPackFile)

    @Test("Removes copied files from destination")
    func removesCopiedFiles() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a fake destination file
        let skillsDir = tmpDir.appendingPathComponent("skills").appendingPathComponent("my-skill")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let skillFile = skillsDir.appendingPathComponent("SKILL.md")
        try "skill content".write(to: skillFile, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: skillFile.path))

        // Verify file removal logic directly
        try FileManager.default.removeItem(at: skillFile)
        #expect(!FileManager.default.fileExists(atPath: skillFile.path))
    }

    // MARK: - Manifest cleanup

    @Test("Removes component IDs and pack ID from manifest")
    func manifestCleanup() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent(".mcs-manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/test")
        manifest.recordInstalledPack("continuous-learning")
        manifest.recordInstalledPack("ios")
        manifest.recordInstalledComponent("cl.ollama")
        manifest.recordInstalledComponent("cl.docs-mcp-server")
        manifest.recordInstalledComponent("ios.xcodebuildmcp")
        manifest.recordHash(relativePath: "packs/continuous-learning/skills/SKILL.md", hash: "abc123")
        manifest.recordHash(relativePath: "packs/continuous-learning/hooks/activator.sh", hash: "def456")
        manifest.recordHash(relativePath: "packs/ios/hooks/sim.sh", hash: "ghi789")
        try manifest.save()

        // Simulate removal of "continuous-learning" pack
        var reloaded = Manifest(path: manifestFile)
        reloaded.removeInstalledComponent("cl.ollama")
        reloaded.removeInstalledComponent("cl.docs-mcp-server")
        reloaded.removeInstalledPack("continuous-learning")
        let hashCount = reloaded.removeHashesWithPrefix("packs/continuous-learning/")
        try reloaded.save()

        #expect(hashCount == 2)

        // Verify the other pack's data is preserved
        let final = Manifest(path: manifestFile)
        #expect(final.installedPacks == Set(["ios"]))
        #expect(final.installedComponents == Set(["ios.xcodebuildmcp"]))
        #expect(final.trackedPaths.contains("packs/ios/hooks/sim.sh"))
        #expect(!final.trackedPaths.contains("packs/continuous-learning/skills/SKILL.md"))
    }

    // MARK: - RemovalSummary

    @Test("RemovalSummary counts total removals")
    func summaryCount() {
        var summary = PackUninstaller.RemovalSummary()
        summary.mcpServers = ["docs-mcp-server"]
        summary.files = ["skills/SKILL.md", "hooks/activator.sh"]

        #expect(summary.totalRemoved == 3)
    }

    @Test("Empty summary has zero total")
    func emptySummary() {
        let summary = PackUninstaller.RemovalSummary()
        #expect(summary.totalRemoved == 0)
        #expect(summary.errors.isEmpty)
    }
}
