import ArgumentParser
import Foundation

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update My Claude Setup to the latest version"
    )

    mutating func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        let currentVersion = MCS.configuration.version

        output.header("Update")
        output.info("Current version: \(currentVersion)")

        // Check if installed via Homebrew
        let brewListResult = shell.shell("brew list my-claude-setup 2>/dev/null")
        if brewListResult.succeeded {
            output.info("Installed via Homebrew -- running upgrade...")
            let upgradeResult = shell.shell("brew upgrade bguidolim/tap/my-claude-setup 2>&1")
            if upgradeResult.succeeded {
                if upgradeResult.stdout.contains("already installed") {
                    output.info("Already at latest version.")
                } else {
                    output.success("Updated successfully!")
                }
            } else {
                // brew upgrade exits non-zero if already up-to-date in some versions
                if upgradeResult.stderr.contains("already installed")
                    || upgradeResult.stdout.contains("already installed")
                {
                    output.info("Already at latest version.")
                } else {
                    output.warn("Upgrade failed: \(upgradeResult.stderr)")
                }
            }
        } else {
            output.info("Not installed via Homebrew.")
            output.info("To install via Homebrew: brew install bguidolim/tap/my-claude-setup")
            output.info("To update manually: download the latest release from GitHub")
        }
    }
}
