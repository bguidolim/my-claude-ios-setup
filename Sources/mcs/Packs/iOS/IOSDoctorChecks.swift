import Foundation

/// Doctor checks specific to the iOS tech pack.
/// See CoreDoctorChecks.swift header for fix() responsibility boundaries.
enum IOSDoctorChecks {
    /// Pack-level checks that cannot be auto-derived from components.
    /// XcodeBuildMCPServerCheck and SosumiServerCheck are now auto-derived
    /// from their component definitions. XcodeBuildMCPSkillCheck is a
    /// supplementaryCheck on the ios.skill.xcodebuildmcp component.
    static var supplementary: [any DoctorCheck] {
        [
            XcodeCLTCheck(),
            XcodeBuildMCPConfigCheck(),
            CLAUDELocalIOSSectionCheck(),
        ]
    }

    /// All iOS checks including auto-derived ones. Kept for testing.
    static var all: [any DoctorCheck] {
        [
            XcodeCLTCheck(),
            XcodeBuildMCPServerCheck(),
            SosumiServerCheck(),
            XcodeBuildMCPSkillCheck(),
            XcodeBuildMCPConfigCheck(),
            CLAUDELocalIOSSectionCheck(),
        ]
    }
}

// MARK: - Xcode Command Line Tools

struct XcodeCLTCheck: DoctorCheck, Sendable {
    let section = "iOS"
    let name = "Xcode Command Line Tools"

    func check() -> CheckResult {
        let result = ShellRunner(environment: Environment())
            .shell("xcode-select -p")
        if result.succeeded {
            return .pass("Installed at \(result.stdout)")
        }
        return .fail("Xcode Command Line Tools not installed")
    }

    func fix() -> FixResult {
        let result = ShellRunner(environment: Environment())
            .shell("xcode-select --install")
        if result.succeeded {
            return .fixed("Installation triggered — follow the system dialog")
        }
        return .failed("Could not trigger CLT install: \(result.stderr)")
    }
}

// MARK: - MCP Server Checks

struct XcodeBuildMCPServerCheck: DoctorCheck, Sendable {
    let section = "iOS"
    let name = "XcodeBuildMCP MCP server"

    func check() -> CheckResult {
        let settingsURL = Environment().claudeJSON
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json[Constants.JSONKeys.mcpServers] as? [String: Any],
              servers["XcodeBuildMCP"] != nil
        else {
            return .fail("XcodeBuildMCP not registered in ~/.claude.json")
        }
        return .pass("Registered")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to register MCP servers")
    }
}

struct SosumiServerCheck: DoctorCheck, Sendable {
    let section = "iOS"
    let name = "Sosumi MCP server"

    func check() -> CheckResult {
        let settingsURL = Environment().claudeJSON
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json[Constants.JSONKeys.mcpServers] as? [String: Any],
              servers["sosumi"] != nil
        else {
            return .fail("Sosumi not registered in ~/.claude.json")
        }
        return .pass("Registered")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to register MCP servers")
    }
}

// MARK: - Skill Check

struct XcodeBuildMCPSkillCheck: DoctorCheck, Sendable {
    let section = "iOS"
    let name = "xcodebuildmcp skill"

    func check() -> CheckResult {
        let skillsDir = Environment().skillsDirectory
        let skillPath = skillsDir.appendingPathComponent("xcodebuildmcp")
        if FileManager.default.fileExists(atPath: skillPath.path) {
            return .pass("Installed")
        }
        return .fail("xcodebuildmcp skill not installed")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install skills")
    }
}

// MARK: - Project-level Checks

struct XcodeBuildMCPConfigCheck: DoctorCheck, Sendable {
    let section = "iOS"
    let name = ".xcodebuildmcp/config.yaml"

    func check() -> CheckResult {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let configFile = cwd
            .appendingPathComponent(IOSConstants.FileNames.xcodeBuildMCPDirectory)
            .appendingPathComponent("config.yaml")

        if FileManager.default.fileExists(atPath: configFile.path) {
            // Check if placeholder still needs to be replaced
            if let content = try? String(contentsOf: configFile, encoding: .utf8),
               content.contains("__PROJECT__") {
                return .warn("Present but __PROJECT__ placeholder not filled in")
            }
            return .pass("Present")
        }
        return .fail("Missing — run 'mcs configure --pack ios' to generate")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs configure --pack ios' to generate project configuration")
    }
}

struct CLAUDELocalIOSSectionCheck: DoctorCheck, Sendable {
    let section = "iOS"
    let name = "CLAUDE.local.md iOS section"

    func check() -> CheckResult {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let claudeLocal = cwd.appendingPathComponent(Constants.FileNames.claudeLocalMD)

        guard let content = try? String(contentsOf: claudeLocal, encoding: .utf8) else {
            return .skip("CLAUDE.local.md not found — run 'mcs configure --pack ios'")
        }

        if content.contains("<!-- mcs:begin ios") {
            return .pass("iOS section present")
        }
        return .warn("CLAUDE.local.md exists but has no iOS section — run 'mcs configure --pack ios'")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs configure --pack ios' to generate CLAUDE.local.md with iOS section")
    }
}
