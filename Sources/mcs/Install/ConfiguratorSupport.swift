import Foundation

/// Shared utilities for `ProjectConfigurator` and `GlobalConfigurator`.
///
/// Eliminates duplication of common methods that both configurators need.
enum ConfiguratorSupport {
    /// Build a `ComponentExecutor` from the common dependencies.
    static func makeExecutor(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner
    ) -> ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell
        )
    }

    /// Ensure global gitignore core entries are present.
    static func ensureGitignoreEntries(shell: ShellRunner) throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }

    /// Validate peer dependencies for all selected packs.
    /// Surfaces registry load errors as warnings instead of silently swallowing them.
    static func validatePeerDependencies(
        packs: [any TechPack],
        environment: Environment,
        output: CLIOutput
    ) -> [PeerDependencyResult] {
        let packRegistryFile = PackRegistryFile(path: environment.packsRegistry)
        let registeredPacks: [PackRegistryFile.PackEntry]
        do {
            registeredPacks = try packRegistryFile.load().packs
        } catch {
            output.warn("Could not read pack registry: \(error.localizedDescription)")
            output.warn("Peer dependency checks may be inaccurate.")
            registeredPacks = []
        }

        return PeerDependencyValidator.validateSelection(
            packs: packs,
            registeredPacks: registeredPacks
        )
    }

    /// Severity level for peer dependency issue reporting.
    enum PeerIssueSeverity: Sendable {
        case error
        case warning
    }

    /// Report peer dependency issues to the console.
    ///
    /// - Parameters:
    ///   - issues: The results to report (`.satisfied` entries are skipped).
    ///   - output: CLIOutput for printing.
    ///   - severity: Whether to use `.error()` or `.warn()` for the main message.
    ///   - missingVerb: Verb describing the missing state ("selected" or "registered").
    ///   - missingSuggestion: Closure returning the suggestion string for `.missing` peers.
    /// - Returns: `true` if any non-satisfied issues were reported.
    @discardableResult
    static func reportPeerDependencyIssues(
        _ issues: [PeerDependencyResult],
        output: CLIOutput,
        severity: PeerIssueSeverity,
        missingVerb: String = "selected",
        missingSuggestion: (_ packIdentifier: String, _ peerPack: String) -> String
    ) -> Bool {
        let unsatisfied = issues.filter { $0.status != .satisfied }
        guard !unsatisfied.isEmpty else { return false }

        for issue in unsatisfied {
            let header: String
            let suggestion: String

            switch issue.status {
            case .missing:
                header = "Pack '\(issue.packIdentifier)' requires peer pack '\(issue.peerPack)' (>= \(issue.minVersion)) which is not \(missingVerb)."
                suggestion = missingSuggestion(issue.packIdentifier, issue.peerPack)
            case .versionTooLow(let actual):
                header = "Pack '\(issue.packIdentifier)' requires peer pack '\(issue.peerPack)' >= \(issue.minVersion), but v\(actual) is registered."
                suggestion = "Update it with: mcs pack update \(issue.peerPack)"
            case .satisfied:
                continue
            }

            switch severity {
            case .error:   output.error(header)
            case .warning: output.warn(header)
            }
            output.dimmed("  \(suggestion)")
        }

        return true
    }

    /// Present per-pack component multi-select and return excluded component IDs.
    ///
    /// - Parameter componentsProvider: Extracts the relevant components from a pack.
    ///   Defaults to all components. Callers can supply a custom filter if needed.
    static func selectComponentExclusions(
        packs: [any TechPack],
        previousState: ProjectState,
        output: CLIOutput,
        componentsProvider: (any TechPack) -> [ComponentDefinition] = { $0.components }
    ) -> [String: Set<String>] {
        var exclusions: [String: Set<String>] = [:]

        for pack in packs {
            let components = componentsProvider(pack)
            guard components.count > 1 else { continue }

            output.plain("")
            output.info("Components for \(pack.displayName):")

            let previousExcluded = previousState.excludedComponents(for: pack.identifier)

            var number = 1
            var items: [SelectableItem] = []
            for component in components {
                items.append(SelectableItem(
                    number: number,
                    name: component.displayName,
                    description: component.description,
                    isSelected: !previousExcluded.contains(component.id)
                ))
                number += 1
            }

            let requiredItems = components
                .filter(\.isRequired)
                .map { RequiredItem(name: $0.displayName) }

            var groups = [SelectableGroup(
                title: pack.displayName,
                items: items,
                requiredItems: requiredItems
            )]

            let selectedNumbers = output.multiSelect(groups: &groups)

            var excluded = Set<String>()
            for (index, component) in components.enumerated() {
                if !selectedNumbers.contains(index + 1) && !component.isRequired {
                    excluded.insert(component.id)
                }
            }

            if !excluded.isEmpty {
                exclusions[pack.identifier] = excluded
            }
        }

        return exclusions
    }

    /// Map hook file names to Claude Code hook event names.
    static func hookEventName(for hookName: String) -> String {
        switch hookName {
        case "session_start": return "SessionStart"
        case "pre_tool_use": return "PreToolUse"
        case "post_tool_use": return "PostToolUse"
        case "notification": return "Notification"
        case "stop": return "Stop"
        default: return hookName
        }
    }

    // MARK: - Placeholder Scanning

    /// Find all `__PLACEHOLDER__` tokens in a file or directory of files.
    /// Recurses into subdirectories. Reads as Data first to distinguish
    /// I/O errors from binary files (which are legitimately skipped).
    static func findPlaceholdersInSource(_ source: URL) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return [] }

        guard isDir.boolValue else {
            guard let data = try? Data(contentsOf: source),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return TemplateEngine.findUnreplacedPlaceholders(in: text)
        }

        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }
            results.append(contentsOf: TemplateEngine.findUnreplacedPlaceholders(in: text))
        }
        return results
    }

    /// Strip `__` delimiters from a placeholder token (e.g. `__FOO__` → `FOO`).
    static func stripPlaceholderDelimiters(_ token: String) -> String {
        String(token.dropFirst(2).dropLast(2))
    }

    /// Scan all `copyPackFile` sources (and optionally template content) for
    /// `__PLACEHOLDER__` tokens not covered by resolved values.
    /// Returns bare keys (without `__` delimiters) sorted alphabetically.
    static func scanForUndeclaredPlaceholders(
        packs: [any TechPack],
        resolvedValues: [String: String],
        includeTemplates: Bool = false,
        onWarning: ((String) -> Void)? = nil
    ) -> [String] {
        var undeclared = Set<String>()
        let resolvedKeys = Set(resolvedValues.keys)

        for pack in packs {
            for component in pack.components {
                if case .copyPackFile(let source, _, _) = component.installAction {
                    for placeholder in findPlaceholdersInSource(source) {
                        let key = stripPlaceholderDelimiters(placeholder)
                        if !resolvedKeys.contains(key) {
                            undeclared.insert(key)
                        }
                    }
                }
            }

            if includeTemplates {
                do {
                    for template in try pack.templates {
                        for placeholder in TemplateEngine.findUnreplacedPlaceholders(in: template.templateContent) {
                            let key = stripPlaceholderDelimiters(placeholder)
                            if !resolvedKeys.contains(key) {
                                undeclared.insert(key)
                            }
                        }
                    }
                } catch {
                    onWarning?("Could not scan templates for \(pack.displayName): \(error.localizedDescription)")
                }
            }
        }

        return undeclared.sorted()
    }
}
