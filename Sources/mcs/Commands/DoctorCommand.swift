import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check installation health and diagnose issues"
    )

    @Flag(name: .long, help: "Attempt to automatically fix issues")
    var fix = false

    @Option(name: .long, help: "Only check a specific tech pack (e.g. ios)")
    var pack: String?

    mutating func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )
        var runner = DoctorRunner(fixMode: fix, packFilter: pack, registry: registry)
        try runner.run()
    }
}
