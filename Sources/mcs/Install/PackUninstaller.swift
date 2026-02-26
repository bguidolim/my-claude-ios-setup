import Foundation

/// Reverses artifacts installed by an external tech pack.
///
/// Given the pack's manifest, removes MCP servers, plugins, copied files,
/// hook fragments, template sections, and gitignore entries. Errors are
/// collected rather than thrown — partial cleanup is better than none.
///
/// **Not reversed by design:**
/// - `shellCommand` — arbitrary side effects, no generic undo
///
/// **Reference-counted removal:**
/// - `brewInstall` — removed only if MCS installed it and no other scope still needs it
/// - `plugin` — removed only if no other scope still needs it; gated by ref counter
struct PackUninstaller {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var registry: TechPackRegistry = .shared

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
                removeComponent(component, packIdentifier: manifest.identifier, packPath: packPath, summary: &summary)
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
        packIdentifier: String,
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
            let refCounter = ResourceRefCounter(
                environment: environment,
                output: output,
                registry: registry
            )
            let ref = PluginRef(name)
            if refCounter.isStillNeeded(
                .plugin(name),
                excludingScope: "__pack_remove__",
                excludingPack: packIdentifier
            ) {
                output.dimmed("  Keeping plugin '\(ref.bareName)' — still needed by another scope")
            } else {
                let claude = ClaudeIntegration(shell: shell)
                let result = claude.pluginRemove(ref: ref)
                if result.succeeded {
                    summary.plugins.append(ref.bareName)
                } else {
                    summary.errors.append("Plugin '\(ref.bareName)': \(result.stderr)")
                }
            }

        case .copyPackFile(let config):
            guard let destURL = resolveDestination(config.destination) else {
                summary.errors.append("File '\(config.destination)': destination escapes expected directory")
                return
            }
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

        case .brewInstall(let package):
            // Check if MCS owns this package (it's in global-state artifacts)
            let globalState = try? ProjectState(stateFile: environment.globalStateFile)
            let mcsOwns = globalState?.configuredPacks.contains(where: { packID in
                globalState?.artifacts(for: packID)?.brewPackages.contains(package) ?? false
            }) ?? false

            if mcsOwns {
                let refCounter = ResourceRefCounter(
                    environment: environment,
                    output: output,
                    registry: registry
                )
                if refCounter.isStillNeeded(
                    .brewPackage(package),
                    excludingScope: "__pack_remove__",
                    excludingPack: packIdentifier
                ) {
                    output.dimmed("  Keeping brew package '\(package)' — still needed by another scope")
                } else {
                    let exec = ComponentExecutor(environment: environment, output: output, shell: shell)
                    if exec.uninstallBrewPackage(package) {
                        summary.manifestEntries.append("brew:\(package)")
                    }
                }
            }
            // If MCS doesn't own it, skip silently (pre-existing resource)

        case .shellCommand:
            // Not reversed by design
            break
        }
    }

    /// Resolve a destination path, expanding `~/.claude/` to the actual claude directory.
    /// Returns `nil` if the resolved path escapes the expected directory (via traversal or symlinks).
    private func resolveDestination(_ destination: String) -> URL? {
        if destination.hasPrefix("~/.claude/") {
            let relative = String(destination.dropFirst("~/.claude/".count))
            return PathContainment.safePath(relativePath: relative, within: environment.claudeDirectory)
        } else if destination.hasPrefix("~/") {
            let relative = String(destination.dropFirst("~/".count))
            let home = FileManager.default.homeDirectoryForCurrentUser
            return PathContainment.safePath(relativePath: relative, within: home)
        } else {
            let destURL = URL(fileURLWithPath: destination)
            guard PathContainment.isContained(url: destURL, within: environment.claudeDirectory) else {
                return nil
            }
            return destURL
        }
    }
}
