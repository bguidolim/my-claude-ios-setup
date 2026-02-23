import Foundation
import Testing

@testable import mcs

@Suite("HookInjector")
struct HookInjectorTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-hook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHookFile(in dir: URL, content: String) throws -> URL {
        let file = dir.appendingPathComponent("session_start.sh")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - remove()

    @Test("Remove an existing hook fragment")
    func removeExisting() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hookContent = """
            #!/bin/bash
            check_status() {
                # --- mcs:begin learning-check v2.0.0 ---
                echo "learning check"
                # --- mcs:end learning-check ---

                \(Constants.Hooks.extensionMarker)
                echo "done"
            }
            """
        let hookFile = try makeHookFile(in: tmpDir, content: hookContent)
        var backup = Backup()
        let output = CLIOutput(colorsEnabled: false)

        let removed = HookInjector.remove(
            identifier: "learning-check",
            from: hookFile,
            backup: &backup,
            output: output
        )

        #expect(removed == true)

        let updated = try String(contentsOf: hookFile, encoding: .utf8)
        #expect(!updated.contains("mcs:begin learning-check"))
        #expect(!updated.contains("learning check"))
        #expect(!updated.contains("mcs:end learning-check"))
        // Extension marker and surrounding code preserved
        #expect(updated.contains(Constants.Hooks.extensionMarker))
        #expect(updated.contains("echo \"done\""))
    }

    @Test("Remove preserves other sections")
    func removePreservesOthers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hookContent = """
            #!/bin/bash
            check_status() {
                # --- mcs:begin section-a v1.0.0 ---
                echo "section A"
                # --- mcs:end section-a ---

                # --- mcs:begin section-b v1.0.0 ---
                echo "section B"
                # --- mcs:end section-b ---

                \(Constants.Hooks.extensionMarker)
            }
            """
        let hookFile = try makeHookFile(in: tmpDir, content: hookContent)
        var backup = Backup()
        let output = CLIOutput(colorsEnabled: false)

        let removed = HookInjector.remove(
            identifier: "section-a",
            from: hookFile,
            backup: &backup,
            output: output
        )

        #expect(removed == true)

        let updated = try String(contentsOf: hookFile, encoding: .utf8)
        #expect(!updated.contains("section A"))
        #expect(updated.contains("section B"))
        #expect(updated.contains("mcs:begin section-b"))
    }

    @Test("Remove nonexistent section returns false")
    func removeNonexistent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hookContent = """
            #!/bin/bash
            check_status() {
                \(Constants.Hooks.extensionMarker)
            }
            """
        let hookFile = try makeHookFile(in: tmpDir, content: hookContent)
        var backup = Backup()
        let output = CLIOutput(colorsEnabled: false)

        let removed = HookInjector.remove(
            identifier: "nonexistent",
            from: hookFile,
            backup: &backup,
            output: output
        )

        #expect(removed == false)
    }

    @Test("Remove from missing file returns false")
    func removeMissingFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let missing = tmpDir.appendingPathComponent("nonexistent.sh")
        var backup = Backup()
        let output = CLIOutput(colorsEnabled: false)

        let removed = HookInjector.remove(
            identifier: "anything",
            from: missing,
            backup: &backup,
            output: output
        )

        #expect(removed == false)
    }

    // MARK: - inject() still works after refactor

    @Test("Inject adds fragment at extension marker")
    func injectBasic() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hookContent = """
            #!/bin/bash
            check_status() {
                \(Constants.Hooks.extensionMarker)
                echo "done"
            }
            """
        let hookFile = try makeHookFile(in: tmpDir, content: hookContent)
        var backup = Backup()
        let output = CLIOutput(colorsEnabled: false)

        HookInjector.inject(
            fragment: "    echo \"injected\"",
            identifier: "test-fragment",
            version: "1.0.0",
            into: hookFile,
            backup: &backup,
            output: output
        )

        let updated = try String(contentsOf: hookFile, encoding: .utf8)
        #expect(updated.contains("mcs:begin test-fragment v1.0.0"))
        #expect(updated.contains("echo \"injected\""))
        #expect(updated.contains("mcs:end test-fragment"))
        #expect(updated.contains(Constants.Hooks.extensionMarker))
    }

    @Test("Inject replaces existing section idempotently")
    func injectIdempotent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hookContent = """
            #!/bin/bash
            check_status() {
                # --- mcs:begin test-fragment v1.0.0 ---
                echo "old version"
                # --- mcs:end test-fragment ---

                \(Constants.Hooks.extensionMarker)
            }
            """
        let hookFile = try makeHookFile(in: tmpDir, content: hookContent)
        var backup = Backup()
        let output = CLIOutput(colorsEnabled: false)

        HookInjector.inject(
            fragment: "    echo \"new version\"",
            identifier: "test-fragment",
            version: "2.0.0",
            into: hookFile,
            backup: &backup,
            output: output
        )

        let updated = try String(contentsOf: hookFile, encoding: .utf8)
        #expect(updated.contains("mcs:begin test-fragment v2.0.0"))
        #expect(updated.contains("new version"))
        #expect(!updated.contains("old version"))
        // Only one occurrence of the markers
        let beginCount = updated.components(separatedBy: "mcs:begin test-fragment").count - 1
        #expect(beginCount == 1)
    }
}
