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
    var backup: Backup

    /// Summary of what was removed and any errors encountered.
    struct RemovalSummary {
        var mcpServers: [String] = []
        var plugins: [String] = []
        var files: [String] = []
        var hookFragments: [String] = []
        var templateSections: [String] = []
        var gitignoreEntries: [String] = []
        var manifestEntries: [String] = []
        var errors: [String] = []

        var totalRemoved: Int {
            mcpServers.count + plugins.count + files.count
                + hookFragments.count + templateSections.count
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

        // 2. Remove hook contributions
        if let hookContributions = manifest.hookContributions {
            for contribution in hookContributions {
                removeHookContribution(contribution, identifier: manifest.identifier, summary: &summary)
            }
        }

        // 3. Remove gitignore entries
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

        // 4. Clean manifest entries
        var manifestTracker = Manifest(path: environment.setupManifest)
        if let components = manifest.components {
            for component in components {
                if manifestTracker.removeInstalledComponent(component.id) {
                    summary.manifestEntries.append(component.id)
                }
            }
        }
        manifestTracker.removeInstalledPack(manifest.identifier)
        let hashCount = manifestTracker.removeHashesWithPrefix("packs/\(manifest.identifier)/")
        if hashCount > 0 {
            summary.manifestEntries.append("\(hashCount) file hash(es)")
        }
        do {
            try manifestTracker.save()
        } catch {
            summary.errors.append("Manifest save: \(error.localizedDescription)")
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
            let scope = config.scope == .project ? "project" : "user"
            let claude = ClaudeIntegration(shell: shell)
            let result = claude.mcpRemove(name: config.name, scope: scope)
            if result.succeeded {
                summary.mcpServers.append(config.name)
            } else {
                summary.errors.append("MCP server '\(config.name)': \(result.stderr)")
            }

        case .plugin(let name):
            let claude = ClaudeIntegration(shell: shell)
            let result = claude.pluginRemove(fullName: name)
            if result.succeeded {
                summary.plugins.append(name)
            } else {
                summary.errors.append("Plugin '\(name)': \(result.stderr)")
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
            // For now, settings are not reversed — user runs `mcs install` to rebuild.
            break

        case .brewInstall, .shellCommand:
            // Not reversed by design
            break
        }
    }

    private mutating func removeHookContribution(
        _ contribution: ExternalHookContribution,
        identifier: String,
        summary: inout RemovalSummary
    ) {
        let hookFile = environment.hooksDirectory
            .appendingPathComponent("\(contribution.hookName).sh")

        // The fragment identifier follows the pattern used during injection
        let fragmentID = contribution.fragmentFile
            .replacingOccurrences(of: ".sh", with: "")

        let removed = HookInjector.remove(
            identifier: fragmentID,
            from: hookFile,
            backup: &backup,
            output: output
        )
        if removed {
            summary.hookFragments.append(fragmentID)
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
