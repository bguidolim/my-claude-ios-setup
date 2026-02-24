import ArgumentParser
import Foundation

struct InstallCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install and configure Claude Code components",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Install all components without prompts")
    var all: Bool = false

    @Flag(name: .long, help: "Preview what would be installed without making changes")
    var dryRun: Bool = false

    @Option(name: .long, help: "Tech pack to install (e.g. ios)")
    var pack: String?

    var skipLock: Bool { dryRun }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()

        output.warn("'mcs install' is deprecated. Use 'mcs sync' instead.")
        let shell = ShellRunner(environment: env)

        guard ensureClaudeCLI(shell: shell, environment: env, output: output) else {
            throw ExitCode.failure
        }

        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )

        var installer = Installer(
            environment: env,
            output: output,
            shell: shell,
            dryRun: dryRun,
            registry: registry
        )

        // Phase 1: Welcome
        try installer.phaseWelcome()

        // Phase 2: Selection
        let state = installer.phaseSelection(installAll: all, packName: pack)

        if state.selectedIDs.isEmpty {
            output.warn("Nothing selected to install.")
            return
        }

        // Resolve dependencies
        let allComponents = registry.allPackComponents
        let plan: DependencyResolver.ResolvedPlan
        do {
            plan = try DependencyResolver.resolve(
                selectedIDs: state.selectedIDs,
                allComponents: allComponents
            )
        } catch {
            output.error("Failed to resolve dependencies: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // Phase 3: Summary
        let proceed = installer.phaseSummary(plan: plan, state: state)
        guard proceed else { return }

        // Phase 4: Install
        installer.phaseInstall(plan: plan, state: state)

        // Phase 5: Post-summary
        installer.phaseSummaryPost(installAll: all)
    }
}
