import Foundation

/// Reverses artifacts installed by an external tech pack.
///
/// Given the pack's manifest, removes MCP servers, plugins, copied files,
/// hook fragments, template sections, and gitignore entries. Errors are
/// collected rather than thrown — partial cleanup is better than none.
///
/// **Not reversed by design:**
/// - `brewInstall` — shared system resource, may be used by other tools
/// - `shellCommand` — arbitrary side effects, no generic undo
struct PackUninstaller {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner

    /// Summary of what was removed and any errors encountered.
    struct RemovalSummary {
        var mcpServers: [String] = []
        var plugins: [String] = []
        var files: [String] = []
        var templateSections: [String] = []
        var gitignoreEntries: [String] = []
        var manifestEntries: [String] = []
        var errors: [String] = []

        var totalRemoved: Int {
            mcpServers.count + plugins.count + files.count
                + templateSections.count
                + gitignoreEntries.count + manifestEntries.count
        }
    }

    /// Uninstall all reversible artifacts declared in the manifest.
    mutating func uninstall(
        manifest: ExternalPackManifest,
        packPath: URL
    ) -> RemovalSummary {
        var summary = RemovalSummary()

        // 1. Remove components by install action type
        if let components = manifest.components {
            for component in components {
                removeComponent(component, packPath: packPath, summary: &summary)
            }
        }

        // 2. Remove gitignore entries
        if let entries = manifest.gitignoreEntries {
            let gitignore = GitignoreManager(shell: shell)
            for entry in entries {
                do {
                    if try gitignore.removeEntry(entry) {
                        summary.gitignoreEntries.append(entry)
                    }
                } catch {
                    summary.errors.append("Gitignore entry '\(entry)': \(error.localizedDescription)")
                }
            }
        }

        return summary
    }

    // MARK: - Private

    private mutating func removeComponent(
        _ component: ExternalComponentDefinition,
        packPath: URL,
        summary: inout RemovalSummary
    ) {
        switch component.installAction {
        case .mcpServer(let config):
            let scope = config.scope?.rawValue ?? "local"
            let claude = ClaudeIntegration(shell: shell)
            let result = claude.mcpRemove(name: config.name, scope: scope)
            if result.succeeded {
                summary.mcpServers.append(config.name)
            } else {
                summary.errors.append("MCP server '\(config.name)': \(result.stderr)")
            }

        case .plugin(let name):
            let claude = ClaudeIntegration(shell: shell)
            let ref = PluginRef(name)
            let result = claude.pluginRemove(ref: ref)
            if result.succeeded {
                summary.plugins.append(ref.bareName)
            } else {
                summary.errors.append("Plugin '\(ref.bareName)': \(result.stderr)")
            }

        case .copyPackFile(let config):
            let destURL = resolveDestination(config.destination)
            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) {
                do {
                    try fm.removeItem(at: destURL)
                    summary.files.append(config.destination)
                } catch {
                    summary.errors.append("File '\(config.destination)': \(error.localizedDescription)")
                }
            }

        case .gitignoreEntries(let entries):
            let gitignore = GitignoreManager(shell: shell)
            for entry in entries {
                do {
                    if try gitignore.removeEntry(entry) {
                        summary.gitignoreEntries.append(entry)
                    }
                } catch {
                    summary.errors.append("Gitignore entry '\(entry)': \(error.localizedDescription)")
                }
            }

        case .settingsFile, .settingsMerge:
            // Settings are deep-merged; removing individual keys requires ownership tracking.
            // For now, settings are not reversed — user runs `mcs sync` to rebuild.
            break

        case .brewInstall, .shellCommand:
            // Not reversed by design
            break
        }
    }

    /// Resolve a destination path, expanding `~/.claude/` to the actual claude directory.
    private func resolveDestination(_ destination: String) -> URL {
        if destination.hasPrefix("~/.claude/") {
            let relative = String(destination.dropFirst("~/.claude/".count))
            return environment.claudeDirectory.appendingPathComponent(relative)
        }
        // Expand ~ for other home-relative paths
        if destination.hasPrefix("~/") {
            let relative = String(destination.dropFirst("~/".count))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relative)
        }
        return URL(fileURLWithPath: destination)
    }
}
