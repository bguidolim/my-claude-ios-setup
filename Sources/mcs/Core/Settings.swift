import Foundation

/// Codable model for ~/.claude/settings.json with deep-merge support.
struct Settings: Codable, Sendable {
    var env: [String: String]?
    var permissions: Permissions?
    var hooks: [String: [HookGroup]]?
    var enabledPlugins: [String: Bool]?
    var alwaysThinkingEnabled: Bool?

    struct Permissions: Codable, Sendable {
        var defaultMode: String?
    }

    struct HookGroup: Codable, Sendable {
        var matcher: String?
        var hooks: [HookEntry]?
    }

    struct HookEntry: Codable, Sendable {
        var type: String?
        var command: String?
    }

    // MARK: - Deep Merge

    /// Merge `other` into `self`, preserving existing user values.
    /// - Objects: keys from `other` are added; existing keys in `self` are kept.
    /// - Hook arrays: deduplicated by the first hook entry's `command` field.
    /// - Plugin dict: merged (doesn't replace).
    mutating func merge(with other: Settings) {
        // Env: merge dicts
        if let otherEnv = other.env {
            var merged = self.env ?? [:]
            for (key, value) in otherEnv {
                if merged[key] == nil {
                    merged[key] = value
                }
            }
            self.env = merged
        }

        // Permissions: use other if self is nil
        if self.permissions == nil {
            self.permissions = other.permissions
        }

        // Hooks: deduplicate by command
        if let otherHooks = other.hooks {
            var merged = self.hooks ?? [:]
            for (event, otherGroups) in otherHooks {
                var existing = merged[event] ?? []
                let existingCommands = Set(
                    existing.compactMap { $0.hooks?.first?.command }
                )
                for group in otherGroups {
                    if let command = group.hooks?.first?.command,
                       !existingCommands.contains(command) {
                        existing.append(group)
                    }
                }
                merged[event] = existing
            }
            self.hooks = merged
        }

        // Plugins: merge without replacing
        if let otherPlugins = other.enabledPlugins {
            var merged = self.enabledPlugins ?? [:]
            for (key, value) in otherPlugins {
                if merged[key] == nil {
                    merged[key] = value
                }
            }
            self.enabledPlugins = merged
        }

        // Thinking: use other if self is nil
        if self.alwaysThinkingEnabled == nil {
            self.alwaysThinkingEnabled = other.alwaysThinkingEnabled
        }
    }

    // MARK: - File I/O

    /// Load settings from a JSON file. Returns empty settings if file doesn't exist.
    static func load(from url: URL) throws -> Settings {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return Settings()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Settings.self, from: data)
    }

    /// Save settings to a JSON file, creating parent directories as needed.
    func save(to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
