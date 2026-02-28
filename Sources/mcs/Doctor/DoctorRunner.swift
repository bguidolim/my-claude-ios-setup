import Foundation

/// Orchestrates all doctor checks grouped by section, with optional fix mode.
///
/// **Scope of `--fix`**: Cleanup, migration, and trivial repairs only.
/// Additive operations (install/register/copy) are deferred to `mcs sync`.
/// See CoreDoctorChecks.swift header for the full responsibility boundary.
struct DoctorRunner {
    let fixMode: Bool
    /// Skip the confirmation prompt before executing fixes (e.g. `--yes` flag).
    let skipConfirmation: Bool
    /// Explicit pack filter. If nil, uses packs from project state or pack registry.
    let packFilter: String?
    let registry: TechPackRegistry

    private let output = CLIOutput()
    private var passCount = 0
    private var failCount = 0
    private var warnCount = 0
    private var fixedCount = 0
    /// Failed checks collected during diagnosis, to be fixed after confirmation.
    private var pendingFixes: [any DoctorCheck] = []

    init(
        fixMode: Bool,
        skipConfirmation: Bool = false,
        packFilter: String? = nil,
        registry: TechPackRegistry = .shared
    ) {
        self.fixMode = fixMode
        self.skipConfirmation = skipConfirmation
        self.packFilter = packFilter
        self.registry = registry
    }

    mutating func run() throws {
        output.header("Managed Claude Stack — Doctor")

        let env = Environment()
        let registry = self.registry

        // Resolve globally-configured pack IDs from global state.
        // This reflects packs actively synced to the global scope, not just
        // registered (available) packs. A pack in registry.yaml but not in
        // global-state.json's configuredPacks has been unsynced and shouldn't
        // trigger doctor checks.
        let globallyConfiguredPackIDs: Set<String>
        do {
            let globalState = try ProjectState(stateFile: env.globalStateFile)
            if globalState.exists {
                // Global state file exists — use its configured packs (may be empty)
                globallyConfiguredPackIDs = globalState.configuredPacks
            } else {
                // No global state file yet — fall back to registry for backward compat
                let packRegistry = PackRegistryFile(path: env.packsRegistry)
                do {
                    globallyConfiguredPackIDs = Set((try packRegistry.load()).packs.map(\.identifier))
                } catch {
                    output.warn("Could not read pack registry: \(error.localizedDescription) — no packs will be checked")
                    globallyConfiguredPackIDs = []
                }
            }
        } catch {
            // Corrupt state file — fall back to registry
            output.warn("Could not read global state: \(error.localizedDescription) — falling back to pack registry")
            let packRegistry = PackRegistryFile(path: env.packsRegistry)
            do {
                globallyConfiguredPackIDs = Set((try packRegistry.load()).packs.map(\.identifier))
            } catch {
                output.warn("Could not read pack registry: \(error.localizedDescription) — no packs will be checked")
                globallyConfiguredPackIDs = []
            }
        }

        // Detect project root
        let projectRoot = ProjectDetector.findProjectRoot()
        let projectName = projectRoot?.lastPathComponent

        // Determine which packs to check (priority: flag > project > section markers > global)
        let installedPackIDs: Set<String>
        let packSource: String
        var projectState: ProjectState?
        var resolvedFromProject = false

        if let filter = packFilter {
            // 1. Explicit --pack flag
            installedPackIDs = Set(filter.components(separatedBy: ","))
            packSource = "--pack flag"
        } else if let root = projectRoot {
            var resolvedState: ProjectState?
            do {
                let state = try ProjectState(projectRoot: root)
                if state.exists, !state.configuredPacks.isEmpty {
                    resolvedState = state
                    projectState = state
                }
            } catch {
                output.warn("Could not read .mcs-project: \(error.localizedDescription) — falling back to section markers")
            }

            if let state = resolvedState {
                // 2. Project .mcs-project file
                installedPackIDs = state.configuredPacks
                packSource = "project: \(projectName ?? "unknown")"
                resolvedFromProject = true
            } else {
                // 3. Fallback: infer from CLAUDE.local.md section markers
                let claudeLocal = root.appendingPathComponent(Constants.FileNames.claudeLocalMD)
                let claudeLocalContent: String?
                if FileManager.default.fileExists(atPath: claudeLocal.path) {
                    do {
                        claudeLocalContent = try String(contentsOf: claudeLocal, encoding: .utf8)
                    } catch {
                        output.warn("Could not read \(Constants.FileNames.claudeLocalMD): \(error.localizedDescription)")
                        claudeLocalContent = nil
                    }
                } else {
                    claudeLocalContent = nil
                }

                if let content = claudeLocalContent {
                    let sections = TemplateComposer.parseSections(from: content)
                    let inferred = Set(sections.map(\.identifier))
                    if !inferred.isEmpty {
                        installedPackIDs = inferred
                        packSource = "project: \(projectName ?? "unknown") (inferred)"
                        resolvedFromProject = true
                    } else {
                        installedPackIDs = globallyConfiguredPackIDs
                        packSource = "global"
                    }
                } else {
                    installedPackIDs = globallyConfiguredPackIDs
                    packSource = "global"
                }
            }
        } else {
            // 4. Not in a project — fall back to pack registry
            installedPackIDs = globallyConfiguredPackIDs
            packSource = "global"
        }

        if !installedPackIDs.isEmpty {
            output.dimmed("Packs (\(packSource)): \(installedPackIDs.sorted().joined(separator: ", "))")
        } else {
            output.dimmed("No packs detected (\(packSource))")
        }

        // === Layered check collection ===

        // Only pass project root to derived checks when packs were resolved from project scope
        let effectiveProjectRoot = resolvedFromProject ? projectRoot : nil

        // Excluded components that pass (e.g. globally installed) are still shown,
        // but failures for excluded components are shown as dimmed skips.
        let excludedComponentIDs: Set<String> = projectState
            .map { Set($0.allExcludedComponents.values.flatMap { $0 }) } ?? []

        // Layer 1+2: Derived + supplementary checks from installed components
        let allComponents = registry.availablePacks
            .filter { installedPackIDs.contains($0.identifier) }
            .flatMap { $0.components }

        var allChecks: [(check: any DoctorCheck, isExcluded: Bool)] = []
        for component in allComponents {
            let excluded = excludedComponentIDs.contains(component.id)
            let checks = component.allDoctorChecks(projectRoot: effectiveProjectRoot)
            allChecks += checks.map { (check: $0, isExcluded: excluded) }
        }

        // Layers 3-5: Pack supplementary, standalone, and project-scoped checks
        // (never excluded — exclusion only applies to per-component checks)
        var nonComponentChecks: [any DoctorCheck] = []
        nonComponentChecks += registry.supplementaryDoctorChecks(installedPacks: installedPackIDs)
        nonComponentChecks += standaloneDoctorChecks(installedPackIDs: installedPackIDs)
        if let root = projectRoot {
            let context = ProjectDoctorContext(projectRoot: root, registry: registry)
            nonComponentChecks += ProjectDoctorChecks.checks(context: context)
        }

        // Global-scoped template freshness check (always runs, self-skips if no global CLAUDE.md)
        nonComponentChecks.append(CLAUDEMDFreshnessCheck(
            fileURL: env.globalClaudeMD,
            stateLoader: { try ProjectState(stateFile: env.globalStateFile) },
            registry: registry,
            displayName: "CLAUDE.md freshness (global)",
            syncHint: "mcs sync --global"
        ))

        allChecks += nonComponentChecks.map { (check: $0, isExcluded: false) }

        // Group by section
        let grouped = Dictionary(grouping: allChecks, by: \.check.section)
        let sectionOrder = [
            "Dependencies", "MCP Servers", "Plugins", "Skills", "Commands",
            "Hooks", "Settings", "Gitignore", "Project", "Templates",
        ]

        for section in sectionOrder {
            guard let checks = grouped[section], !checks.isEmpty else { continue }
            output.header(section)
            runChecks(checks)
        }

        // Also run checks for any sections not in the predefined order
        for (section, checks) in grouped where !sectionOrder.contains(section) {
            output.header(section)
            runChecks(checks)
        }

        // Phase 2: Confirm and execute pending fixes
        if fixMode {
            executePendingFixes()
        }

        // Summary
        output.header("Summary")
        output.doctorSummary(
            passed: passCount,
            fixed: fixedCount,
            warnings: warnCount,
            issues: failCount
        )
    }

    // MARK: - Standalone checks (not tied to any component)

    /// Checks that cannot be derived from any ComponentDefinition.
    private func standaloneDoctorChecks(installedPackIDs: Set<String>) -> [any DoctorCheck] {
        var checks: [any DoctorCheck] = []

        // Gitignore (cross-component aggregation — engine-level)
        checks.append(GitignoreCheck(registry: registry, installedPackIDs: installedPackIDs))

        // Project index (cross-project tracking)
        checks.append(ProjectIndexCheck())

        return checks
    }

    // MARK: - Check execution

    /// Phase 1: Diagnose all checks. Failures are collected into `pendingFixes`
    /// for later confirmation instead of being fixed immediately.
    private mutating func runChecks(_ checks: [(check: any DoctorCheck, isExcluded: Bool)]) {
        for entry in checks {
            let result = entry.check.check()
            let name = entry.check.name

            // Show excluded component failures/warnings as skipped
            // (user explicitly deselected via --customize)
            if entry.isExcluded, result.isFailOrWarn {
                docSkip(name, "excluded via --customize")
                continue
            }

            switch result {
            case .pass(let msg):
                docPass(name, msg)
            case .fail(let msg):
                docFail(name, msg)
                if fixMode {
                    pendingFixes.append(entry.check)
                }
            case .warn(let msg):
                docWarn(name, msg)
            case .skip(let msg):
                docSkip(name, msg)
            }
        }
    }

    /// Phase 2: Show a summary of pending fixes with their actual commands,
    /// prompt for confirmation, then execute.
    private mutating func executePendingFixes() {
        // Separate fixable checks (have a preview command) from unfixable ones.
        // Unfixable checks are shown as hints after the prompt, not in the confirmation list.
        let fixable = pendingFixes.filter { $0.fixCommandPreview != nil }
        let unfixable = pendingFixes.filter { $0.fixCommandPreview == nil }

        // Show unfixable hints immediately (no confirmation needed)
        for check in unfixable {
            let result = check.fix()
            if case .notFixable(let msg) = result {
                output.warn("  ↳ \(check.name): \(msg)")
            }
        }

        guard !fixable.isEmpty else { return }

        output.sectionHeader("Available fixes")

        for check in fixable {
            output.plain("  • \(check.name): \(check.fixCommandPreview!)")
        }

        let fixLabel = fixable.count == 1 ? "fix" : "fixes"
        if !skipConfirmation {
            guard output.askYesNo("Apply \(fixable.count) \(fixLabel)?", default: false) else {
                output.dimmed("Skipped all fixes.")
                return
            }
        }

        for check in fixable {
            switch check.fix() {
            case .fixed(let msg):
                docFixed(check.name, msg)
            case .failed(let msg):
                docFixFailed(check.name, msg)
            case .notFixable(let msg):
                output.warn("  ↳ \(check.name): \(msg)")
            }
        }
    }

    // MARK: - Output helpers

    private mutating func docPass(_ name: String, _ msg: String) {
        passCount += 1
        output.success("✓ \(name): \(msg)")
    }

    private mutating func docFail(_ name: String, _ msg: String) {
        failCount += 1
        output.error("✗ \(name): \(msg)")
    }

    private mutating func docWarn(_ name: String, _ msg: String) {
        warnCount += 1
        output.warn("⚠ \(name): \(msg)")
    }

    private mutating func docSkip(_ name: String, _ msg: String) {
        output.dimmed("○ \(name): \(msg)")
    }

    private mutating func docFixed(_ name: String, _ msg: String) {
        fixedCount += 1
        failCount -= 1 // Convert fail to fixed
        output.success("  ✓ \(name): \(msg)")
    }

    private mutating func docFixFailed(_ name: String, _ msg: String) {
        output.error("  ✗ \(name): \(msg)")
    }
}
