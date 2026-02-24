import Foundation
import Testing

@testable import mcs

@Suite("ComponentExecutor")
struct ComponentExecutorTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-compexec-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutor() -> ComponentExecutor {
        let env = Environment()
        return ComponentExecutor(
            environment: env,
            output: CLIOutput(),
            shell: ShellRunner(environment: env)
        )
    }

    // MARK: - removeProjectFile path containment

    @Test("Removes file within project directory")
    func removesFileInsideProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let exec = makeExecutor()
        exec.removeProjectFile(relativePath: "test.txt", projectPath: tmpDir)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Blocks path traversal via ../")
    func blocksPathTraversal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a file outside the project directory
        let outsideFile = tmpDir
            .deletingLastPathComponent()
            .appendingPathComponent("mcs-traversal-target-\(UUID().uuidString).txt")
        try "sensitive".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let exec = makeExecutor()
        exec.removeProjectFile(
            relativePath: "../\(outsideFile.lastPathComponent)",
            projectPath: tmpDir
        )

        // File outside project must NOT be deleted
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    @Test("Blocks deeply nested path traversal")
    func blocksDeeplyNestedTraversal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outsideFile = tmpDir
            .deletingLastPathComponent()
            .appendingPathComponent("mcs-deep-target-\(UUID().uuidString).txt")
        try "sensitive".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let exec = makeExecutor()
        exec.removeProjectFile(
            relativePath: "subdir/../../\(outsideFile.lastPathComponent)",
            projectPath: tmpDir
        )

        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}
