import Foundation
import Yams

// MARK: - Manifest Root

/// Codable model for `techpack.yaml` — the declarative manifest for external tech packs.
struct ExternalPackManifest: Codable, Sendable {
    let schemaVersion: Int
    let identifier: String
    let displayName: String
    let description: String
    let version: String
    let minMCSVersion: String?
    let peerDependencies: [PeerDependency]?
    let components: [ExternalComponentDefinition]?
    let templates: [ExternalTemplateDefinition]?
    let hookContributions: [ExternalHookContribution]?
    let gitignoreEntries: [String]?
    let prompts: [ExternalPromptDefinition]?
    let configureProject: ExternalConfigureProject?
    let supplementaryDoctorChecks: [ExternalDoctorCheckDefinition]?

}

// MARK: - Loading

extension ExternalPackManifest {
    /// Load and decode a `techpack.yaml` file from disk.
    static func load(from url: URL) throws -> ExternalPackManifest {
        let data = try Data(contentsOf: url)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ManifestError.invalidEncoding
        }
        let decoder = YAMLDecoder()
        return try decoder.decode(ExternalPackManifest.self, from: yamlString)
    }
}

// MARK: - Validation

extension ExternalPackManifest {
    /// Validate the manifest for structural correctness.
    func validate() throws {
        // Schema version
        guard schemaVersion == 1 else {
            throw ManifestError.unsupportedSchemaVersion(schemaVersion)
        }

        // Identifier: non-empty, lowercase alphanumeric + hyphens only
        let identifierPattern = #"^[a-z0-9][a-z0-9-]*$"#
        guard !identifier.isEmpty,
              identifier.range(of: identifierPattern, options: .regularExpression) != nil
        else {
            throw ManifestError.invalidIdentifier(identifier)
        }

        // Component ID prefix
        if let components {
            var seenIDs = Set<String>()
            for component in components {
                let expectedPrefix = "\(identifier)."
                guard component.id.hasPrefix(expectedPrefix) else {
                    throw ManifestError.componentIDPrefixViolation(
                        componentID: component.id,
                        expectedPrefix: expectedPrefix
                    )
                }
                guard !seenIDs.contains(component.id) else {
                    throw ManifestError.duplicateComponentID(component.id)
                }
                seenIDs.insert(component.id)
            }
        }

        // Template section identifiers must match pack identifier
        if let templates {
            for template in templates {
                guard template.sectionIdentifier == identifier
                    || template.sectionIdentifier.hasPrefix("\(identifier).")
                else {
                    throw ManifestError.templateSectionMismatch(
                        sectionIdentifier: template.sectionIdentifier,
                        packIdentifier: identifier
                    )
                }
            }
        }

        // Prompt key uniqueness
        if let prompts {
            var seenKeys = Set<String>()
            for prompt in prompts {
                guard !seenKeys.contains(prompt.key) else {
                    throw ManifestError.duplicatePromptKey(prompt.key)
                }
                seenKeys.insert(prompt.key)
            }
        }

        // Doctor check field validation
        if let checks = supplementaryDoctorChecks {
            for check in checks {
                try validateDoctorCheck(check)
            }
        }
        if let components {
            for component in components {
                if let checks = component.doctorChecks {
                    for check in checks {
                        try validateDoctorCheck(check)
                    }
                }
            }
        }
    }

    private func validateDoctorCheck(_ check: ExternalDoctorCheckDefinition) throws {
        switch check.type {
        case .commandExists:
            guard let command = check.command, !command.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "commandExists requires non-empty 'command'")
            }
        case .fileExists, .directoryExists:
            guard let path = check.path, !path.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'path'")
            }
        case .fileContains, .fileNotContains:
            guard let path = check.path, !path.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'path'")
            }
            guard let pattern = check.pattern, !pattern.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'pattern'")
            }
        case .shellScript:
            guard let command = check.command, !command.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "shellScript requires non-empty 'command'")
            }
        case .hookEventExists:
            guard let event = check.event, !event.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "hookEventExists requires non-empty 'event'")
            }
        case .settingsKeyEquals:
            guard let keyPath = check.keyPath, !keyPath.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "settingsKeyEquals requires non-empty 'keyPath'")
            }
            guard let expectedValue = check.expectedValue, !expectedValue.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "settingsKeyEquals requires non-empty 'expectedValue'")
            }
        }
    }
}

// MARK: - Normalization

extension ExternalPackManifest {
    /// Returns a copy with short component IDs and intra-pack dependencies auto-prefixed
    /// with the pack identifier. IDs that already contain a dot are left as-is.
    func normalized() -> ExternalPackManifest {
        let prefix = "\(identifier)."
        let normalizedComponents = components?.map { component -> ExternalComponentDefinition in
            var c = component
            if !c.id.contains(".") {
                c.id = prefix + c.id
            }
            c.dependencies = c.dependencies?.map { dep in
                dep.contains(".") ? dep : prefix + dep
            }
            return c
        }
        let normalizedTemplates = templates?.map { template -> ExternalTemplateDefinition in
            var t = template
            if !t.sectionIdentifier.contains(".") {
                t.sectionIdentifier = prefix + t.sectionIdentifier
            }
            return t
        }
        return ExternalPackManifest(
            schemaVersion: schemaVersion,
            identifier: identifier,
            displayName: displayName,
            description: description,
            version: version,
            minMCSVersion: minMCSVersion,
            peerDependencies: peerDependencies,
            components: normalizedComponents,
            templates: normalizedTemplates,
            hookContributions: hookContributions,
            gitignoreEntries: gitignoreEntries,
            prompts: prompts,
            configureProject: configureProject,
            supplementaryDoctorChecks: supplementaryDoctorChecks
        )
    }
}

// MARK: - Errors

/// Errors that can occur during manifest loading or validation.
enum ManifestError: Error, Equatable, Sendable, LocalizedError {
    case invalidEncoding
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier(String)
    case componentIDPrefixViolation(componentID: String, expectedPrefix: String)
    case duplicateComponentID(String)
    case templateSectionMismatch(sectionIdentifier: String, packIdentifier: String)
    case duplicatePromptKey(String)
    case invalidDoctorCheck(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Manifest file is not valid UTF-8"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported schema version: \(version) (expected 1)"
        case .invalidIdentifier(let id):
            return "Invalid pack identifier '\(id)': must be non-empty, lowercase alphanumeric with hyphens"
        case .componentIDPrefixViolation(let componentID, let expectedPrefix):
            return "Component ID '\(componentID)' must start with '\(expectedPrefix)'"
        case .duplicateComponentID(let id):
            return "Duplicate component ID: '\(id)'"
        case .templateSectionMismatch(let section, let pack):
            return "Template section '\(section)' does not match pack identifier '\(pack)'"
        case .duplicatePromptKey(let key):
            return "Duplicate prompt key: '\(key)'"
        case .invalidDoctorCheck(let name, let reason):
            return "Invalid doctor check '\(name)': \(reason)"
        }
    }
}

// MARK: - Peer Dependencies

struct PeerDependency: Codable, Sendable, Equatable {
    let pack: String
    let minVersion: String
}

// MARK: - Components

/// Declarative definition of an installable component within an external pack.
struct ExternalComponentDefinition: Codable, Sendable {
    var id: String
    let displayName: String
    let description: String
    let type: ExternalComponentType
    var dependencies: [String]?
    let isRequired: Bool?
    /// Claude Code hook event name (e.g. "SessionStart", "PreToolUse") for `hookFile` components.
    /// When set, the engine auto-registers this hook in `settings.local.json`.
    let hookEvent: String?
    let installAction: ExternalInstallAction
    let doctorChecks: [ExternalDoctorCheckDefinition]?
}

/// String-backed component type that maps to the internal `ComponentType`.
enum ExternalComponentType: String, Codable, Sendable {
    case mcpServer
    case plugin
    case skill
    case hookFile
    case command
    case brewPackage
    case configuration

    /// Convert to the internal `ComponentType`.
    var componentType: ComponentType {
        switch self {
        case .mcpServer: return .mcpServer
        case .plugin: return .plugin
        case .skill: return .skill
        case .hookFile: return .hookFile
        case .command: return .command
        case .brewPackage: return .brewPackage
        case .configuration: return .configuration
        }
    }
}

// MARK: - Install Actions

/// String-backed install action type discriminator for YAML serialization.
enum ExternalInstallActionType: String, Codable, Sendable {
    case mcpServer
    case plugin
    case brewInstall
    case shellCommand
    case gitignoreEntries
    case settingsMerge
    case settingsFile
    case copyPackFile
}

/// Declarative install action types that can be expressed in YAML.
enum ExternalInstallAction: Codable, Sendable {
    case mcpServer(ExternalMCPServerConfig)
    case plugin(name: String)
    case brewInstall(package: String)
    case shellCommand(command: String)
    case gitignoreEntries(entries: [String])
    case settingsMerge
    case settingsFile(source: String)
    case copyPackFile(ExternalCopyPackFileConfig)

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case package
        case command
        case args
        case env
        case transport
        case url
        case scope
        case entries
        case source
        case destination
        case fileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actionType = try container.decode(ExternalInstallActionType.self, forKey: .type)

        switch actionType {
        case .mcpServer:
            let config = try ExternalMCPServerConfig(from: decoder)
            self = .mcpServer(config)
        case .plugin:
            let name = try container.decode(String.self, forKey: .name)
            self = .plugin(name: name)
        case .brewInstall:
            let package = try container.decode(String.self, forKey: .package)
            self = .brewInstall(package: package)
        case .shellCommand:
            let command = try container.decode(String.self, forKey: .command)
            self = .shellCommand(command: command)
        case .gitignoreEntries:
            let entries = try container.decode([String].self, forKey: .entries)
            self = .gitignoreEntries(entries: entries)
        case .settingsMerge:
            self = .settingsMerge
        case .settingsFile:
            let source = try container.decode(String.self, forKey: .source)
            self = .settingsFile(source: source)
        case .copyPackFile:
            let config = try ExternalCopyPackFileConfig(from: decoder)
            self = .copyPackFile(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .mcpServer(let config):
            try container.encode(ExternalInstallActionType.mcpServer, forKey: .type)
            try config.encode(to: encoder)
        case .plugin(let name):
            try container.encode(ExternalInstallActionType.plugin, forKey: .type)
            try container.encode(name, forKey: .name)
        case .brewInstall(let package):
            try container.encode(ExternalInstallActionType.brewInstall, forKey: .type)
            try container.encode(package, forKey: .package)
        case .shellCommand(let command):
            try container.encode(ExternalInstallActionType.shellCommand, forKey: .type)
            try container.encode(command, forKey: .command)
        case .gitignoreEntries(let entries):
            try container.encode(ExternalInstallActionType.gitignoreEntries, forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .settingsMerge:
            try container.encode(ExternalInstallActionType.settingsMerge, forKey: .type)
        case .settingsFile(let source):
            try container.encode(ExternalInstallActionType.settingsFile, forKey: .type)
            try container.encode(source, forKey: .source)
        case .copyPackFile(let config):
            try container.encode(ExternalInstallActionType.copyPackFile, forKey: .type)
            try config.encode(to: encoder)
        }
    }
}

// MARK: - MCP Server Config

/// Configuration for an MCP server declared in an external pack manifest.
struct ExternalMCPServerConfig: Codable, Sendable {
    let name: String
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let transport: ExternalTransport?
    let url: String?
    let scope: ExternalScope?

    /// Convert to the internal `MCPServerConfig`.
    func toMCPServerConfig() -> MCPServerConfig {
        if transport == .http, let url {
            return .http(name: name, url: url, scope: scope?.rawValue)
        }
        return MCPServerConfig(
            name: name,
            command: command ?? "",
            args: args ?? [],
            env: env ?? [:],
            scope: scope?.rawValue
        )
    }
}

enum ExternalTransport: String, Codable, Sendable {
    case stdio
    case http
}

enum ExternalScope: String, Codable, Sendable {
    case local
    case user
    case project
}

// MARK: - Copy Pack File Config

/// Configuration for copying a file from the pack into the Claude directory.
struct ExternalCopyPackFileConfig: Codable, Sendable {
    let source: String
    let destination: String
    let fileType: ExternalCopyFileType?
}

enum ExternalCopyFileType: String, Codable, Sendable {
    case skill
    case hook
    case command
    case generic
}

// MARK: - Templates

/// A template contribution declared in an external pack manifest.
struct ExternalTemplateDefinition: Codable, Sendable {
    var sectionIdentifier: String
    let placeholders: [String]?
    let contentFile: String
}

// MARK: - Hook Contributions

/// A hook contribution declared in an external pack manifest.
struct ExternalHookContribution: Codable, Sendable {
    let hookName: String
    let fragmentFile: String
    let position: ExternalHookPosition?
}

enum ExternalHookPosition: String, Codable, Sendable {
    case before
    case after

    /// Convert to the internal `HookContribution.HookPosition`.
    var hookPosition: HookContribution.HookPosition {
        switch self {
        case .before: return .before
        case .after: return .after
        }
    }
}

// MARK: - Prompts

/// A prompt definition for gathering user input during install/configure.
struct ExternalPromptDefinition: Codable, Sendable {
    let key: String
    let type: ExternalPromptType
    let label: String?
    let defaultValue: String?
    let options: [ExternalPromptOption]?
    /// File patterns to detect. Accepts a single string or an array in YAML.
    /// Results are returned in pattern order (first pattern's matches first).
    let detectPatterns: [String]?
    let scriptCommand: String?

    enum CodingKeys: String, CodingKey {
        case key
        case type
        case label
        case defaultValue = "default"
        case options
        case detectPatterns = "detectPattern"
        case scriptCommand
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(ExternalPromptType.self, forKey: .type)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        options = try container.decodeIfPresent([ExternalPromptOption].self, forKey: .options)
        scriptCommand = try container.decodeIfPresent(String.self, forKey: .scriptCommand)

        // detectPattern: accept String or [String]
        if container.contains(.detectPatterns) {
            if let array = try? container.decode([String].self, forKey: .detectPatterns) {
                detectPatterns = array
            } else if let single = try? container.decode(String.self, forKey: .detectPatterns) {
                detectPatterns = [single]
            } else {
                detectPatterns = nil
            }
        } else {
            detectPatterns = nil
        }
    }

    init(
        key: String,
        type: ExternalPromptType,
        label: String?,
        defaultValue: String?,
        options: [ExternalPromptOption]?,
        detectPatterns: [String]?,
        scriptCommand: String?
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.defaultValue = defaultValue
        self.options = options
        self.detectPatterns = detectPatterns
        self.scriptCommand = scriptCommand
    }
}

enum ExternalPromptType: String, Codable, Sendable {
    case fileDetect
    case input
    case select
    case script
}

struct ExternalPromptOption: Codable, Sendable, Equatable {
    let value: String
    let label: String
}

// MARK: - Configure Project

/// Script-based project configuration hook.
struct ExternalConfigureProject: Codable, Sendable {
    let script: String
}

// MARK: - Doctor Checks

/// A declarative doctor check definition for external packs.
struct ExternalDoctorCheckDefinition: Codable, Sendable {
    let type: ExternalDoctorCheckType
    let name: String
    let section: String?
    let command: String?
    let args: [String]?
    let path: String?
    let pattern: String?
    let scope: ExternalDoctorCheckScope?
    let fixCommand: String?
    let fixScript: String?
    let event: String?
    let keyPath: String?
    let expectedValue: String?
    let isOptional: Bool?
}

enum ExternalDoctorCheckType: String, Codable, Sendable {
    case commandExists
    case fileExists
    case directoryExists
    case fileContains
    case fileNotContains
    case shellScript
    case hookEventExists
    case settingsKeyEquals
}

enum ExternalDoctorCheckScope: String, Codable, Sendable {
    case global
    case project
}
