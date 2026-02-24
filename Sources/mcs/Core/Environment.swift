import Foundation

/// Paths, architecture detection, and system environment information.
struct Environment: Sendable {
    let homeDirectory: URL
    let claudeDirectory: URL
    let claudeJSON: URL
    let claudeSettings: URL
    let hooksDirectory: URL
    let skillsDirectory: URL
    let commandsDirectory: URL
    let memoriesDirectory: URL
    let binDirectory: URL

    /// mcs-internal state directory (`~/.mcs/`).
    /// Stores pack checkouts, registry, global state, and lock file.
    let mcsDirectory: URL

    let architecture: Architecture
    let brewPrefix: String
    let brewPath: String
    let shellRCFile: URL?

    enum Architecture: String, Sendable {
        case arm64
        case x86_64
    }

    init(home: URL? = nil) {
        let home = home ?? URL(fileURLWithPath: NSHomeDirectory())
        self.homeDirectory = home

        let claudeDir = home.appendingPathComponent(Constants.FileNames.claudeDirectory)
        self.claudeDirectory = claudeDir
        self.claudeJSON = home.appendingPathComponent(".claude.json")
        self.claudeSettings = claudeDir.appendingPathComponent("settings.json")
        self.hooksDirectory = claudeDir.appendingPathComponent("hooks")
        self.skillsDirectory = claudeDir.appendingPathComponent("skills")
        self.commandsDirectory = claudeDir.appendingPathComponent("commands")
        self.memoriesDirectory = claudeDir.appendingPathComponent("memories")
        self.binDirectory = claudeDir.appendingPathComponent("bin")

        self.mcsDirectory = home.appendingPathComponent(".mcs")

        #if arch(arm64)
        self.architecture = .arm64
        self.brewPrefix = "/opt/homebrew"
        #else
        self.architecture = .x86_64
        self.brewPrefix = "/usr/local"
        #endif
        self.brewPath = "\(self.brewPrefix)/bin/brew"

        self.shellRCFile = Environment.resolveShellRC(home: home)
    }

    private static func resolveShellRC(home: URL) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        switch shellName {
        case "zsh":
            return home.appendingPathComponent(".zshrc")
        case "bash":
            return home.appendingPathComponent(".bash_profile")
        default:
            return nil
        }
    }

    /// Directory where external tech pack checkouts live (`~/.mcs/packs/`).
    var packsDirectory: URL {
        mcsDirectory.appendingPathComponent(Constants.ExternalPacks.packsDirectory)
    }

    /// YAML registry of installed external packs (`~/.mcs/registry.yaml`).
    var packsRegistry: URL {
        mcsDirectory.appendingPathComponent(Constants.ExternalPacks.registryFilename)
    }

    /// Global state file tracking globally-installed packs and artifacts (`~/.mcs/global-state.json`).
    var globalStateFile: URL {
        mcsDirectory.appendingPathComponent("global-state.json")
    }

    /// POSIX lock file for preventing concurrent mcs execution (`~/.mcs/lock`).
    var lockFile: URL {
        mcsDirectory.appendingPathComponent(Constants.FileNames.mcsLock)
    }

    /// PATH string that includes the Homebrew bin directory.
    var pathWithBrew: String {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let brewBin = "\(brewPrefix)/bin"
        if currentPath.contains(brewBin) {
            return currentPath
        }
        return "\(brewBin):\(currentPath)"
    }
}
