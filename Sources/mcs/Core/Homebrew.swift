import Foundation

/// Manages Homebrew package installation and service management.
struct Homebrew: Sendable {
    let shell: ShellRunner
    let environment: Environment

    /// Whether Homebrew is installed and accessible.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: environment.brewPath)
    }

    /// Check if a Homebrew package is installed.
    func isPackageInstalled(_ name: String) -> Bool {
        let result = shell.run(
            environment.brewPath,
            arguments: ["list", name]
        )
        return result.succeeded
    }

    /// Install a Homebrew package.
    @discardableResult
    func install(_ name: String) -> ShellResult {
        shell.run(environment.brewPath, arguments: ["install", name])
    }

    /// Uninstall a Homebrew package. May fail if other formulas depend on it.
    @discardableResult
    func uninstall(_ name: String) -> ShellResult {
        shell.run(environment.brewPath, arguments: ["uninstall", name])
    }

    /// Start a Homebrew service.
    @discardableResult
    func startService(_ name: String) -> ShellResult {
        shell.run(environment.brewPath, arguments: ["services", "start", name])
    }

    /// Stop a Homebrew service.
    @discardableResult
    func stopService(_ name: String) -> ShellResult {
        shell.run(environment.brewPath, arguments: ["services", "stop", name])
    }

    /// Check if a Homebrew service is running.
    func isServiceRunning(_ name: String) -> Bool {
        let result = shell.run(
            environment.brewPath,
            arguments: ["services", "list"]
        )
        guard result.succeeded else { return false }
        return result.stdout.contains("\(name)") &&
               result.stdout.split(separator: "\n")
                   .contains { line in
                       line.contains(name) && line.contains("started")
                   }
    }
}
