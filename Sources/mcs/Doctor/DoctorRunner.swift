import Foundation

/// Orchestrates all doctor checks grouped by section, with optional fix mode.
///
/// **Scope of `--fix`**: Cleanup, migration, and trivial repairs only.
/// Additive operations (install/register/copy) are deferred to `mcs sync`.
/// See CoreDoctorChecks.swift header for the full responsibility boundary.
struct DoctorRunner {
    let fixMode: Bool
    /// Explicit pack filter. If nil, uses packs from project state or pack registry.
    let packFilter: String?
    let registry: TechPackRegistry

    private let output = CLIOutput()
    private var passCount = 0
    private var failCount = 0
    private var warnCount = 0
    private var fixedCount = 0

    init(fixMode: Bool, packFilter: String? = nil, registry: TechPackRegistry = .shared) {
        self.fixMode = fixMode
        self.packFilter = packFilter
        self.registry = registry
    }

    mutating func run() throws {
        output.header("Managed Claude Stack — Doctor")

        let env = Environment()
        let registry = self.registry

        // Resolve registered pack IDs from the YAML registry
        let packRegistry = PackRegistryFile(path: env.packsRegistry)
        let registeredPackIDs = Set((try? packRegistry.load())?.packs.map(\.identifier) ?? [])

        // Detect project root
        let projectRoot = ProjectDetector.findProjectRoot()
        let projectName = projectRoot?.lastPathComponent

        // Determine which packs to check (priority: flag > project > section markers > global)
        let installedPackIDs: Set<String>
        let packSource: String

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
                }
            } catch {
                output.warn("Could not read .mcs-project: \(error.localizedDescription) — falling back to section markers")
            }

            if let state = resolvedState {
                // 2. Project .mcs-project file
                installedPackIDs = state.configuredPacks
                packSource = "project: \(projectName ?? "unknown")"
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
                    let inferred = Set(sections.map(\.identifier).filter { $0 != "core" })
                    if !inferred.isEmpty {
                        installedPackIDs = inferred
                        packSource = "project: \(projectName ?? "unknown") (inferred)"
                    } else {
                        installedPackIDs = registeredPackIDs
                        packSource = "global"
                    }
                } else {
                    installedPackIDs = registeredPackIDs
                    packSource = "global"
                }
            }
        } else {
            // 4. Not in a project — fall back to pack registry
            installedPackIDs = registeredPackIDs
            packSource = "global"
        }

        if !installedPackIDs.isEmpty {
            output.dimmed("Packs (\(packSource)): \(installedPackIDs.sorted().joined(separator: ", "))")
        } else {
            output.dimmed("No packs detected (\(packSource))")
        }

        // === Layered check collection ===

        // Layer 1+2: Derived + supplementary checks from installed components
        let allComponents = registry.availablePacks
            .filter { installedPackIDs.contains($0.identifier) }
            .flatMap { $0.components }

        var allChecks: [any DoctorCheck] = []
        for component in allComponents {
            allChecks.append(contentsOf: component.allDoctorChecks())
        }

        // Layer 3: Pack-level supplementary checks (non-component concerns)
        allChecks.append(contentsOf: registry.supplementaryDoctorChecks(installedPacks: installedPackIDs))

        // Layer 4: Standalone checks (not tied to any component)
        allChecks.append(contentsOf: standaloneDoctorChecks(installedPackIDs: installedPackIDs))

        // Layer 5: Project-scoped checks (only when inside a project)
        if let root = projectRoot {
            let context = ProjectDoctorContext(projectRoot: root, registry: registry)
            allChecks.append(contentsOf: ProjectDoctorChecks.checks(context: context))
        }

        // Group by section
        let grouped = Dictionary(grouping: allChecks, by: \.section)
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

        return checks
    }

    // MARK: - Check execution

    private mutating func runChecks(_ checks: [any DoctorCheck]) {
        for check in checks {
            let result = check.check()
            switch result {
            case .pass(let msg):
                docPass(check.name, msg)
            case .fail(let msg):
                docFail(check.name, msg)
                if fixMode {
                    let fixResult = check.fix()
                    switch fixResult {
                    case .fixed(let fixMsg):
                        docFixed(check.name, fixMsg)
                    case .failed(let fixMsg):
                        docFixFailed(check.name, fixMsg)
                    case .notFixable(let fixMsg):
                        output.warn("  ↳ \(fixMsg)")
                    }
                }
            case .warn(let msg):
                docWarn(check.name, msg)
            case .skip(let msg):
                docSkip(check.name, msg)
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
        output.success("  ↳ Fixed: \(msg)")
    }

    private mutating func docFixFailed(_ name: String, _ msg: String) {
        output.error("  ↳ Fix failed: \(msg)")
    }
}
