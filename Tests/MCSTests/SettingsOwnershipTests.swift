import Foundation
import Testing

@testable import mcs

@Suite("SettingsOwnership")
struct SettingsOwnershipTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-ownership-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Key path extraction

    @Test("Extract key paths from Settings template")
    func keyPathExtraction() {
        let settings = Settings(
            env: [
                "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                "ENABLE_TOOL_SEARCH": "1",
            ],
            permissions: Settings.Permissions(defaultMode: "plan"),
            hooks: nil,
            enabledPlugins: ["my-plugin@org": true],
            alwaysThinkingEnabled: true
        )

        let paths = SettingsOwnership.keyPaths(from: settings)

        #expect(paths.contains("env.CLAUDE_CODE_DISABLE_AUTO_MEMORY"))
        #expect(paths.contains("env.ENABLE_TOOL_SEARCH"))
        #expect(paths.contains("permissions.defaultMode"))
        #expect(paths.contains("enabledPlugins.my-plugin@org"))
        #expect(paths.contains("alwaysThinkingEnabled"))
    }

    @Test("Empty settings produce no key paths")
    func emptySettings() {
        let settings = Settings()
        let paths = SettingsOwnership.keyPaths(from: settings)
        #expect(paths.isEmpty)
    }

    // MARK: - Record and query

    @Test("Record and query ownership")
    func recordAndQuery() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var ownership = SettingsOwnership(path: tmpDir.appendingPathComponent("keys"))
        ownership.record(keyPath: "env.FOO", version: "2.0.0")
        ownership.record(keyPath: "permissions.defaultMode", version: "2.0.0")

        #expect(ownership.owns(keyPath: "env.FOO"))
        #expect(ownership.owns(keyPath: "permissions.defaultMode"))
        #expect(!ownership.owns(keyPath: "env.BAR"))
        #expect(ownership.version(for: "env.FOO") == "2.0.0")
    }

    // MARK: - Stale key detection

    @Test("Detect stale keys no longer in template")
    func staleKeys() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var ownership = SettingsOwnership(path: tmpDir.appendingPathComponent("keys"))
        ownership.record(keyPath: "env.OLD_KEY", version: "1.0.0")
        ownership.record(keyPath: "env.STILL_USED", version: "1.0.0")
        ownership.record(keyPath: "alwaysThinkingEnabled", version: "1.0.0")

        // New template only has STILL_USED and alwaysThinkingEnabled
        let newTemplate = Settings(
            env: ["STILL_USED": "1"],
            alwaysThinkingEnabled: true
        )

        let stale = ownership.staleKeys(comparedTo: newTemplate)
        #expect(stale == ["env.OLD_KEY"])
    }

    @Test("No stale keys when template matches ownership")
    func noStaleKeys() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settings = Settings(
            env: ["KEY1": "1"],
            alwaysThinkingEnabled: true
        )

        var ownership = SettingsOwnership(path: tmpDir.appendingPathComponent("keys"))
        ownership.recordAll(from: settings, version: "2.0.0")

        let stale = ownership.staleKeys(comparedTo: settings)
        #expect(stale.isEmpty)
    }

    // MARK: - Persistence

    @Test("Save and reload preserves entries")
    func saveAndReload() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("keys")

        var original = SettingsOwnership(path: filePath)
        original.record(keyPath: "env.FOO", version: "2.0.0")
        original.record(keyPath: "permissions.defaultMode", version: "2.0.0")
        try original.save()

        let reloaded = SettingsOwnership(path: filePath)
        #expect(reloaded.owns(keyPath: "env.FOO"))
        #expect(reloaded.owns(keyPath: "permissions.defaultMode"))
        #expect(reloaded.version(for: "env.FOO") == "2.0.0")
        #expect(reloaded.managedKeys.count == 2)
    }

    @Test("Comments in file are ignored during load")
    func commentsIgnored() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("keys")
        let content = """
            # mcs settings ownership — do not edit manually
            # version=2.0.0
            env.FOO=2.0.0
            """
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let ownership = SettingsOwnership(path: filePath)
        #expect(ownership.managedKeys == ["env.FOO"])
    }

    // MARK: - Settings.removeKeys

    @Test("Remove stale env key from settings")
    func removeEnvKey() {
        var settings = Settings(
            env: ["KEEP": "1", "REMOVE": "1"]
        )
        settings.removeKeys(["env.REMOVE"])
        #expect(settings.env?["KEEP"] == "1")
        #expect(settings.env?["REMOVE"] == nil)
    }

    @Test("Remove alwaysThinkingEnabled from settings")
    func removeTopLevelKey() {
        var settings = Settings(alwaysThinkingEnabled: true)
        settings.removeKeys(["alwaysThinkingEnabled"])
        #expect(settings.alwaysThinkingEnabled == nil)
    }

    @Test("Remove hook event from settings")
    func removeHookEvent() {
        var settings = Settings(
            hooks: [
                "SessionStart": [],
                "OldEvent": [],
            ]
        )
        settings.removeKeys(["hooks.OldEvent"])
        #expect(settings.hooks?["SessionStart"] != nil)
        #expect(settings.hooks?["OldEvent"] == nil)
    }

    @Test("Remove plugin from settings")
    func removePlugin() {
        var settings = Settings(
            enabledPlugins: ["keep@org": true, "remove@org": true]
        )
        settings.removeKeys(["enabledPlugins.remove@org"])
        #expect(settings.enabledPlugins?["keep@org"] == true)
        #expect(settings.enabledPlugins?["remove@org"] == nil)
    }

    // MARK: - recordAll

    // MARK: - Legacy manifest bootstrap

    @Test("Bootstrap from legacy bash manifest seeds ownership")
    func legacyBootstrap() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a fake legacy manifest with SCRIPT_DIR pointing to a dir that has setup.sh
        let manifestPath = tmpDir.appendingPathComponent(".setup-manifest")
        let fakeRepoDir = tmpDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: fakeRepoDir, withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(
            to: fakeRepoDir.appendingPathComponent("setup.sh"),
            atomically: true,
            encoding: .utf8
        )
        let manifestContent = "SCRIPT_DIR=\(fakeRepoDir.path)\nhooks/session_start.sh=abc123\n"
        try manifestContent.write(to: manifestPath, atomically: true, encoding: .utf8)

        // Bootstrap from it
        let sidecarPath = tmpDir.appendingPathComponent("keys")
        var ownership = SettingsOwnership(path: sidecarPath)
        let migrated = ownership.bootstrapFromLegacyManifest(at: manifestPath)

        #expect(migrated == true)
        // Should own the known legacy settings
        #expect(ownership.owns(keyPath: "env.CLAUDE_CODE_DISABLE_AUTO_MEMORY"))
        #expect(ownership.owns(keyPath: "permissions.defaultMode"))
        #expect(ownership.owns(keyPath: "alwaysThinkingEnabled"))
        // Should own legacy deprecated items
        #expect(ownership.owns(keyPath: "enabledPlugins.claude-hud@claude-hud"))
        #expect(ownership.owns(keyPath: "mcpServers.serena"))
        #expect(ownership.owns(keyPath: "mcpServers.mcp-omnisearch"))
        // Version should be 1.0.0 (legacy era)
        #expect(ownership.version(for: "env.CLAUDE_CODE_DISABLE_AUTO_MEMORY") == "1.0.0")
    }

    @Test("Bootstrap does not overwrite existing sidecar")
    func legacyBootstrapNoOverwrite() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a fake legacy manifest
        let manifestPath = tmpDir.appendingPathComponent(".setup-manifest")
        let fakeRepoDir = tmpDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: fakeRepoDir, withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(
            to: fakeRepoDir.appendingPathComponent("setup.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "SCRIPT_DIR=\(fakeRepoDir.path)\n".write(
            to: manifestPath, atomically: true, encoding: .utf8
        )

        // Existing sidecar with one entry
        let sidecarPath = tmpDir.appendingPathComponent("keys")
        var ownership = SettingsOwnership(path: sidecarPath)
        ownership.record(keyPath: "env.MY_KEY", version: "2.0.0")

        // Bootstrap should NOT overwrite
        let migrated = ownership.bootstrapFromLegacyManifest(at: manifestPath)
        #expect(migrated == false)
        #expect(ownership.managedKeys == ["env.MY_KEY"])
    }

    @Test("Bootstrap skips when no legacy manifest exists")
    func legacyBootstrapNoManifest() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let missingManifest = tmpDir.appendingPathComponent("does-not-exist")
        let sidecarPath = tmpDir.appendingPathComponent("keys")
        var ownership = SettingsOwnership(path: sidecarPath)
        let migrated = ownership.bootstrapFromLegacyManifest(at: missingManifest)

        #expect(migrated == false)
        #expect(ownership.managedKeys.isEmpty)
    }

    // MARK: - recordAll

    @Test("recordAll captures all key paths from a settings template")
    func recordAll() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settings = Settings(
            env: ["A": "1", "B": "2"],
            permissions: Settings.Permissions(defaultMode: "plan"),
            alwaysThinkingEnabled: true
        )

        var ownership = SettingsOwnership(path: tmpDir.appendingPathComponent("keys"))
        ownership.recordAll(from: settings, version: "2.0.0")

        #expect(ownership.managedKeys.count == 4)
        #expect(ownership.version(for: "env.A") == "2.0.0")
        #expect(ownership.version(for: "env.B") == "2.0.0")
        #expect(ownership.version(for: "permissions.defaultMode") == "2.0.0")
        #expect(ownership.version(for: "alwaysThinkingEnabled") == "2.0.0")
    }
}
