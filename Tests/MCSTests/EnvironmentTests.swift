import Foundation
import Testing

@testable import mcs

@Suite("Environment")
struct EnvironmentTests {
    /// Create a unique temp directory simulating a home directory.
    private func makeTmpHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-env-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Path construction

    @Test("Environment paths are relative to home directory")
    func pathsRelativeToHome() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        #expect(env.claudeDirectory.path == home.appendingPathComponent(".claude").path)
        #expect(env.claudeJSON.path == home.appendingPathComponent(".claude.json").path)
        #expect(env.claudeSettings.path ==
            home.appendingPathComponent(".claude/settings.json").path)
        #expect(env.setupManifest.path ==
            home.appendingPathComponent(".claude/.mcs-manifest").path)
        #expect(env.memoriesDirectory.path ==
            home.appendingPathComponent(".claude/memories").path)
        #expect(env.binDirectory.path ==
            home.appendingPathComponent(".claude/bin").path)
    }

    @Test("Legacy manifest path points to .setup-manifest")
    func legacyManifestPath() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        #expect(env.legacyManifest.path ==
            home.appendingPathComponent(".claude/.setup-manifest").path)
    }

    // MARK: - migrateManifestIfNeeded

    @Test("Migrate moves .setup-manifest to .mcs-manifest")
    func migrateManifest() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.claudeDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let content = "SCRIPT_DIR=/test\nhooks/session_start.sh=abc123\n"
        try content.write(to: env.legacyManifest, atomically: true, encoding: .utf8)

        let migrated = env.migrateManifestIfNeeded()

        #expect(migrated == true)
        #expect(FileManager.default.fileExists(atPath: env.setupManifest.path))
        #expect(!FileManager.default.fileExists(atPath: env.legacyManifest.path))

        let migratedContent = try String(contentsOf: env.setupManifest, encoding: .utf8)
        #expect(migratedContent == content)
    }

    @Test("Migration skipped when new manifest already exists")
    func migrateSkipsWhenNewExists() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.claudeDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        try "old".write(to: env.legacyManifest, atomically: true, encoding: .utf8)
        try "new".write(to: env.setupManifest, atomically: true, encoding: .utf8)

        let migrated = env.migrateManifestIfNeeded()

        #expect(migrated == false)
        // Both files should still exist
        #expect(FileManager.default.fileExists(atPath: env.legacyManifest.path))
        let newContent = try String(contentsOf: env.setupManifest, encoding: .utf8)
        #expect(newContent == "new")
    }

    @Test("Migration skipped when no legacy manifest exists")
    func migrateSkipsWhenNoLegacy() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        let migrated = env.migrateManifestIfNeeded()

        #expect(migrated == false)
        #expect(!FileManager.default.fileExists(atPath: env.setupManifest.path))
    }

    @Test("Migration is idempotent — second call returns false")
    func migrateIdempotent() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.claudeDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "data".write(to: env.legacyManifest, atomically: true, encoding: .utf8)

        let first = env.migrateManifestIfNeeded()
        let second = env.migrateManifestIfNeeded()

        #expect(first == true)
        #expect(second == false) // Already migrated
    }
}
