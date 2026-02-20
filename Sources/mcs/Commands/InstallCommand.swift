import ArgumentParser
import Foundation

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install and configure Claude Code components"
    )

    @Flag(name: .long, help: "Install all components without prompts")
    var all: Bool = false

    @Flag(name: .long, help: "Preview what would be installed without making changes")
    var dryRun: Bool = false

    @Option(name: .long, help: "Tech pack to install (e.g. ios)")
    var pack: String?

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        var installer = Installer(
            environment: env,
            output: output,
            shell: shell,
            dryRun: dryRun
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
        let allComponents = TechPackRegistry.shared.allComponents(
            includingCore: CoreComponents.all
        )
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
        installer.phaseSummaryPost()
    }
}
