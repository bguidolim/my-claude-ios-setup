import Foundation

/// Result of running a shell command.
struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Runs shell commands and captures output.
struct ShellRunner: Sendable {
    let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// Check if a command exists on PATH.
    func commandExists(_ command: String) -> Bool {
        let result = run("/usr/bin/which", arguments: [command], quiet: true)
        return result.succeeded
    }

    /// Run an executable with arguments, capturing stdout and stderr.
    @discardableResult
    func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:],
        quiet: Bool = false
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = environment.pathWithBrew
        for (key, value) in additionalEnvironment {
            env[key] = value
        }
        process.environment = env

        if let cwd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ShellResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Run a shell command string via /bin/bash -c.
    @discardableResult
    func shell(
        _ command: String,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) -> ShellResult {
        run(
            "/bin/bash",
            arguments: ["-c", command],
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment
        )
    }
}
