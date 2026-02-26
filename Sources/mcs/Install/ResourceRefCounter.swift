import Foundation

/// Determines whether a global resource (brew package or plugin) can be safely
/// removed by checking all projects and the global scope for references.
///
/// Uses a two-tier check:
/// 1. Global-state artifact records (ownership) for other globally-configured packs
/// 2. Project index → `.mcs-project` → pack manifest (declarations) for project-scoped packs
///
/// MCP servers are project-independent (scoped via `-s local`) and never need ref counting.
struct ResourceRefCounter {
    let environment: Environment
    let output: CLIOutput
    let registry: TechPackRegistry

    enum Resource: Equatable {
        case brewPackage(String)
        case plugin(String)
    }

    /// Check if a resource is still needed by any scope OTHER than the one being removed.
    ///
    /// - Parameters:
    ///   - resource: The brew package or plugin to check.
    ///   - scopePath: The scope being removed (project path or `ProjectIndex.globalSentinel`).
    ///   - packID: The pack being unconfigured within that scope.
    /// - Returns: `true` if the resource is still needed (do NOT remove), `false` if safe to remove.
    func isStillNeeded(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        // 1. Check global-state artifact records for other packs
        if checkGlobalArtifacts(resource, excludingScope: scopePath, excludingPack: packID) {
            return true
        }

        // 2. Check project index for all other scopes via manifest declarations
        if checkProjectIndex(resource, excludingScope: scopePath, excludingPack: packID) {
            return true
        }

        return false
    }

    // MARK: - Private

    /// Check if any other pack in global-state.json owns the resource.
    private func checkGlobalArtifacts(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        guard let globalState = try? ProjectState(stateFile: environment.globalStateFile) else {
            // Can't read global state — be conservative
            return true
        }

        for otherPackID in globalState.configuredPacks {
            // Skip the pack being removed if we're in the global scope
            if scopePath == ProjectIndex.globalSentinel && otherPackID == packID {
                continue
            }

            guard let artifacts = globalState.artifacts(for: otherPackID) else { continue }

            switch resource {
            case .brewPackage(let name):
                if artifacts.brewPackages.contains(name) { return true }
            case .plugin(let name):
                if artifacts.plugins.contains(name) { return true }
                // Also check by bare name for matching different full-name formats
                let refBareName = PluginRef(name).bareName
                if artifacts.plugins.contains(where: { PluginRef($0).bareName == refBareName }) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if any project (via manifest declarations) still needs the resource.
    private func checkProjectIndex(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        let indexFile = ProjectIndex(path: environment.projectsIndexFile)
        guard var indexData = try? indexFile.load() else {
            // Can't read index — be conservative
            return true
        }

        let fm = FileManager.default
        var stalePaths: [String] = []

        for entry in indexData.projects {
            // Skip the scope being removed
            if entry.path == scopePath { continue }

            // Validate project still exists (skip __global__ — always valid)
            if entry.path != ProjectIndex.globalSentinel {
                guard fm.fileExists(atPath: entry.path) else {
                    stalePaths.append(entry.path)
                    continue
                }
            }

            // Check each pack in this scope
            for otherPackID in entry.packs {
                // Skip the same pack in the same scope (shouldn't happen, but be safe)
                if entry.path == scopePath && otherPackID == packID { continue }

                if packDeclaresResource(packID: otherPackID, resource: resource) {
                    // Clean up stale entries we found along the way before returning
                    pruneStaleEntries(stalePaths, in: &indexData, indexFile: indexFile)
                    return true
                }
            }
        }

        // Clean up any stale entries we found
        pruneStaleEntries(stalePaths, in: &indexData, indexFile: indexFile)

        return false
    }

    /// Check if a pack's manifest declares the given resource.
    /// Returns `true` (conservative) if the pack can't be loaded.
    private func packDeclaresResource(packID: String, resource: Resource) -> Bool {
        guard let pack = registry.pack(for: packID) else {
            // Pack not loadable (removed from registry?) — be conservative
            output.dimmed("  Pack '\(packID)' not found in registry — assuming resource still needed")
            return true
        }

        for component in pack.components {
            switch (resource, component.installAction) {
            case (.brewPackage(let name), .brewInstall(let pkg)):
                if pkg == name { return true }
            case (.plugin(let name), .plugin(let pluginName)):
                if PluginRef(pluginName).bareName == PluginRef(name).bareName { return true }
            default:
                break
            }
        }

        return false
    }

    /// Opportunistically prune stale project entries and warn the user.
    private func pruneStaleEntries(
        _ paths: [String],
        in data: inout ProjectIndex.IndexData,
        indexFile: ProjectIndex
    ) {
        guard !paths.isEmpty else { return }
        for path in paths {
            output.warn("Project not found: \(path) — removing from index")
            indexFile.remove(projectPath: path, from: &data)
        }
        try? indexFile.save(data)
    }
}
