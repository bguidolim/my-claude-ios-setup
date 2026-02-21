import Foundation

/// Paths, architecture detection, and system environment information.
struct Environment: Sendable {
    let homeDirectory: URL
    let claudeDirectory: URL
    let claudeJSON: URL
    let claudeSettings: URL
    let settingsKeys: URL
    let hooksDirectory: URL
    let skillsDirectory: URL
    let commandsDirectory: URL
    let memoriesDirectory: URL
    let setupManifest: URL
    let binDirectory: URL

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
        self.settingsKeys = claudeDir.appendingPathComponent(".mcs-settings-keys")
        self.hooksDirectory = claudeDir.appendingPathComponent("hooks")
        self.skillsDirectory = claudeDir.appendingPathComponent("skills")
        self.commandsDirectory = claudeDir.appendingPathComponent("commands")
        self.memoriesDirectory = claudeDir.appendingPathComponent("memories")
        self.setupManifest = claudeDir.appendingPathComponent(".mcs-manifest")
        self.binDirectory = claudeDir.appendingPathComponent("bin")

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

    /// The path where the old bash installer stored its manifest.
    var legacyManifest: URL {
        claudeDirectory.appendingPathComponent(".setup-manifest")
    }

    /// Migrate the old `.setup-manifest` to `.mcs-manifest` if needed.
    /// Returns true if a migration was performed.
    @discardableResult
    func migrateManifestIfNeeded() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyManifest.path),
              !fm.fileExists(atPath: setupManifest.path)
        else { return false }

        do {
            try fm.moveItem(at: legacyManifest, to: setupManifest)
            return true
        } catch {
            // Fall back to copy if move fails (e.g., cross-volume)
            do {
                try fm.copyItem(at: legacyManifest, to: setupManifest)
                return true
            } catch {
                return false
            }
        }
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
