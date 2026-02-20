import Foundation

/// Orchestrates all doctor checks grouped by section, with optional fix mode.
struct DoctorRunner {
    let fixMode: Bool

    private let output = CLIOutput()
    private var passCount = 0
    private var failCount = 0
    private var warnCount = 0
    private var fixedCount = 0

    init(fixMode: Bool) {
        self.fixMode = fixMode
    }

    mutating func run() throws {
        output.header("My Claude Setup — Doctor")

        // Collect all checks: core + pack checks
        var allChecks: [any DoctorCheck] = coreDoctorChecks()
        allChecks.append(contentsOf: TechPackRegistry.shared.allPackDoctorChecks)

        // Group by section
        let grouped = Dictionary(grouping: allChecks, by: \.section)
        let sectionOrder = [
            "Dependencies", "MCP Servers", "Plugins", "Skills", "Commands",
            "Hooks", "Settings", "Gitignore", "Templates", "Migration",
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
        output.plain(
            "\(passCount) passed  \(fixedCount) fixed  \(warnCount) warnings  \(failCount) issues"
        )
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
