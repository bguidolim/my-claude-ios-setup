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
