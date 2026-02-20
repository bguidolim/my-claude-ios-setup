import Foundation
import Testing

@testable import mcs

@Suite("Settings deep-merge")
struct SettingsMergeTests {
    // MARK: - Merge into empty / default settings

    @Test("Merging into empty settings copies all fields")
    func mergeIntoEmpty() {
        var base = Settings()
        let other = Settings(
            env: ["KEY": "value"],
            permissions: Settings.Permissions(defaultMode: "allowEdits"),
            hooks: [
                "PreToolUse": [
                    Settings.HookGroup(
                        matcher: "Edit",
                        hooks: [Settings.HookEntry(type: "command", command: "echo hi")]
                    ),
                ],
            ],
            enabledPlugins: ["my-plugin": true],
            alwaysThinkingEnabled: true
        )

        base.merge(with: other)

        #expect(base.env?["KEY"] == "value")
        #expect(base.permissions?.defaultMode == "allowEdits")
        #expect(base.hooks?["PreToolUse"]?.count == 1)
        #expect(base.enabledPlugins?["my-plugin"] == true)
        #expect(base.alwaysThinkingEnabled == true)
    }

    // MARK: - Preserve existing user settings

    @Test("Existing env vars are preserved during merge")
    func envPreserveExisting() {
        var base = Settings(env: ["EXISTING": "keep", "SHARED": "original"])
        let other = Settings(env: ["SHARED": "overwrite-attempt", "NEW": "added"])

        base.merge(with: other)

        #expect(base.env?["EXISTING"] == "keep")
        #expect(base.env?["SHARED"] == "original") // existing NOT overwritten
        #expect(base.env?["NEW"] == "added")
    }

    @Test("Existing plugins are preserved during merge")
    func pluginPreserveExisting() {
        var base = Settings(enabledPlugins: ["user-plugin": true])
        let other = Settings(enabledPlugins: ["user-plugin": false, "new-plugin": true])

        base.merge(with: other)

        #expect(base.enabledPlugins?["user-plugin"] == true) // not overwritten
        #expect(base.enabledPlugins?["new-plugin"] == true) // added
    }

    // MARK: - Hook deduplication by command

    @Test("Hooks are deduplicated by command field")
    func hookDeduplication() {
        let existingHook = Settings.HookGroup(
            matcher: "Edit",
            hooks: [Settings.HookEntry(type: "command", command: "echo existing")]
        )
        let duplicateHook = Settings.HookGroup(
            matcher: "Edit",
            hooks: [Settings.HookEntry(type: "command", command: "echo existing")]
        )
        let newHook = Settings.HookGroup(
            matcher: "Edit",
            hooks: [Settings.HookEntry(type: "command", command: "echo new")]
        )

        var base = Settings(hooks: ["PreToolUse": [existingHook]])
        let other = Settings(hooks: ["PreToolUse": [duplicateHook, newHook]])

        base.merge(with: other)

        let groups = base.hooks?["PreToolUse"] ?? []
        #expect(groups.count == 2) // existing + new, duplicate skipped
        let commands = groups.compactMap { $0.hooks?.first?.command }
        #expect(commands.contains("echo existing"))
        #expect(commands.contains("echo new"))
    }

    @Test("Hooks merge across different events")
    func hooksMergeDifferentEvents() {
        var base = Settings(hooks: [
            "PreToolUse": [
                Settings.HookGroup(
                    matcher: "Edit",
                    hooks: [Settings.HookEntry(type: "command", command: "echo pre")]
                ),
            ],
        ])
        let other = Settings(hooks: [
            "PostToolUse": [
                Settings.HookGroup(
                    matcher: "Edit",
                    hooks: [Settings.HookEntry(type: "command", command: "echo post")]
                ),
            ],
        ])

        base.merge(with: other)

        #expect(base.hooks?["PreToolUse"]?.count == 1)
        #expect(base.hooks?["PostToolUse"]?.count == 1)
    }

    // MARK: - Plugin merge is additive

    @Test("Plugin merge adds new entries without overwriting")
    func pluginMergeAdditive() {
        var base = Settings(enabledPlugins: ["a": true, "b": false])
        let other = Settings(enabledPlugins: ["b": true, "c": true])

        base.merge(with: other)

        #expect(base.enabledPlugins?["a"] == true)
        #expect(base.enabledPlugins?["b"] == false) // original kept
        #expect(base.enabledPlugins?["c"] == true)  // new added
    }

    // MARK: - alwaysThinkingEnabled merge

    @Test("alwaysThinkingEnabled only set if base is nil")
    func thinkingMerge() {
        var base = Settings(alwaysThinkingEnabled: false)
        let other = Settings(alwaysThinkingEnabled: true)

        base.merge(with: other)

        #expect(base.alwaysThinkingEnabled == false) // existing preserved
    }

    @Test("alwaysThinkingEnabled adopted from other when base is nil")
    func thinkingMergeFromNil() {
        var base = Settings()
        let other = Settings(alwaysThinkingEnabled: true)

        base.merge(with: other)

        #expect(base.alwaysThinkingEnabled == true)
    }

    // MARK: - File I/O round-trip

    @Test("Settings save and load round-trip")
    func saveAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        let original = Settings(
            env: ["FOO": "bar"],
            permissions: Settings.Permissions(defaultMode: "allowEdits"),
            enabledPlugins: ["p": true],
            alwaysThinkingEnabled: true
        )

        try original.save(to: file)
        let loaded = try Settings.load(from: file)

        #expect(loaded.env?["FOO"] == "bar")
        #expect(loaded.permissions?.defaultMode == "allowEdits")
        #expect(loaded.enabledPlugins?["p"] == true)
        #expect(loaded.alwaysThinkingEnabled == true)
    }

    @Test("Loading from nonexistent file returns empty settings")
    func loadMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let settings = try Settings.load(from: missing)

        #expect(settings.env == nil)
        #expect(settings.hooks == nil)
        #expect(settings.enabledPlugins == nil)
    }

    // MARK: - Unknown key preservation

    @Test("Save preserves unknown top-level JSON keys")
    func preserveUnknownKeys() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")

        // Write a file with an unknown top-level key
        let rawJSON: [String: Any] = [
            "env": ["MY_VAR": "value"],
            "unknownField": "important-data",
            "anotherUnknown": 42,
            "alwaysThinkingEnabled": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: rawJSON, options: .prettyPrinted)
        try data.write(to: file)

        // Load, modify, and save
        var settings = try Settings.load(from: file)
        settings.env?["NEW_VAR"] = "new"
        try settings.save(to: file)

        // Read raw JSON to verify unknown keys survived
        let savedData = try Data(contentsOf: file)
        let savedJSON = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]

        #expect(savedJSON["unknownField"] as? String == "important-data")
        #expect(savedJSON["anotherUnknown"] as? Int == 42)
        #expect((savedJSON["env"] as? [String: String])?["MY_VAR"] == "value")
        #expect((savedJSON["env"] as? [String: String])?["NEW_VAR"] == "new")
    }

    @Test("Save to new file works without existing unknown keys")
    func saveNewFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        let settings = Settings(env: ["KEY": "val"], alwaysThinkingEnabled: true)
        try settings.save(to: file)

        let loaded = try Settings.load(from: file)
        #expect(loaded.env?["KEY"] == "val")
        #expect(loaded.alwaysThinkingEnabled == true)
    }
}
