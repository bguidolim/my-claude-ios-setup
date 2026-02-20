import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check installation health and diagnose issues"
    )

    @Flag(name: .long, help: "Attempt to automatically fix issues")
    var fix = false

    mutating func run() throws {
        var runner = DoctorRunner(fixMode: fix)
        try runner.run()
    }
}
