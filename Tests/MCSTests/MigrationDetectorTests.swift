import Foundation
import Testing

@testable import mcs

@Suite("Migration checks")
struct MigrationDetectorTests {
    /// Create a unique temp directory simulating a home directory.
    private func makeTmpHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-migration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - LegacyBashInstallerCheck

    @Test("Pass when no legacy installer directory exists")
    func bashInstallerPass() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let check = LegacyBashInstallerCheck(environment: env)
        let result = check.check()

        if case .pass = result {
            // Expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Warn when legacy installer directory exists")
    func bashInstallerWarn() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let legacyDir = home.appendingPathComponent(".claude-ios-setup")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let env = Environment(home: home)
        let check = LegacyBashInstallerCheck(environment: env)
        let result = check.check()

        if case .warn(let msg) = result {
            #expect(msg.contains(".claude-ios-setup"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("Fix removes legacy installer directory")
    func bashInstallerFix() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let legacyDir = home.appendingPathComponent(".claude-ios-setup")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try "placeholder".write(
            to: legacyDir.appendingPathComponent("setup.sh"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = LegacyBashInstallerCheck(environment: env)
        let result = check.fix()

        if case .fixed = result {
            #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    // MARK: - LegacyManifestCheck

    @Test("Pass when no legacy manifest exists")
    func legacyManifestPass() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let check = LegacyManifestCheck(environment: env)
        let result = check.check()

        if case .pass = result {
            // Expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Warn when legacy .setup-manifest exists")
    func legacyManifestWarn() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.claudeDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "SCRIPT_DIR=/test\n".write(
            to: env.legacyManifest, atomically: true, encoding: .utf8
        )

        let check = LegacyManifestCheck(environment: env)
        let result = check.check()

        if case .warn(let msg) = result {
            #expect(msg.contains(".setup-manifest"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("Fix removes legacy manifest when new manifest already exists")
    func legacyManifestFixRemove() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.claudeDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "old\n".write(to: env.legacyManifest, atomically: true, encoding: .utf8)
        try "new\n".write(to: env.setupManifest, atomically: true, encoding: .utf8)

        let check = LegacyManifestCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains("already migrated"))
            #expect(!FileManager.default.fileExists(atPath: env.legacyManifest.path))
            #expect(FileManager.default.fileExists(atPath: env.setupManifest.path))
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    @Test("Fix migrates legacy manifest when new manifest does not exist")
    func legacyManifestFixMigrate() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.claudeDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "SCRIPT_DIR=/test\n".write(
            to: env.legacyManifest, atomically: true, encoding: .utf8
        )

        let check = LegacyManifestCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains("migrated"))
            #expect(FileManager.default.fileExists(atPath: env.setupManifest.path))
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    // MARK: - LegacyCLIWrapperCheck

    @Test("No warn for bin directory when legacy wrapper not in fake home")
    func cliWrapperBinDirClean() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        // The wrapper is not in the fake home's bin directory
        let binWrapper = env.binDirectory.appendingPathComponent("claude-ios-setup")
        #expect(!FileManager.default.fileExists(atPath: binWrapper.path))
        // Note: `which` may still find the real wrapper on PATH — that's
        // a system-level check and not controllable in unit tests.
    }

    @Test("Warn when legacy CLI wrapper exists at known location")
    func cliWrapperWarn() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let binDir = env.binDirectory
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/bash\necho legacy".write(
            to: binDir.appendingPathComponent("claude-ios-setup"),
            atomically: true, encoding: .utf8
        )

        let check = LegacyCLIWrapperCheck(environment: env)
        let result = check.check()

        if case .warn(let msg) = result {
            #expect(msg.contains("claude-ios-setup"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("Fix removes legacy CLI wrapper")
    func cliWrapperFix() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let binDir = env.binDirectory
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let wrapperPath = binDir.appendingPathComponent("claude-ios-setup")
        try "#!/bin/bash\necho legacy".write(
            to: wrapperPath, atomically: true, encoding: .utf8
        )

        let check = LegacyCLIWrapperCheck(environment: env)
        let result = check.fix()

        if case .fixed = result {
            #expect(!FileManager.default.fileExists(atPath: wrapperPath.path))
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    // MARK: - LegacyShellRCPathCheck

    @Test("Pass when no RC files contain legacy marker")
    func shellRCPass() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Create .zshrc without the marker
        try "export PATH=\"/usr/bin:$PATH\"\n".write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = LegacyShellRCPathCheck(environment: env)
        let result = check.check()

        if case .pass = result {
            // Expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Warn when .zshrc contains legacy marker")
    func shellRCWarnZshrc() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let content = """
            export FOO=bar
            # Added by Claude Code iOS Setup
            export PATH="$HOME/.claude/bin:$PATH"
            export BAR=baz
            """
        try content.write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = LegacyShellRCPathCheck(environment: env)
        let result = check.check()

        if case .warn(let msg) = result {
            #expect(msg.contains(".zshrc"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("Warn when both .zshrc and .bash_profile contain legacy marker")
    func shellRCWarnBothFiles() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let content = """
            # Added by Claude Code iOS Setup
            export PATH="$HOME/.claude/bin:$PATH"
            """
        try content.write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )
        try content.write(
            to: home.appendingPathComponent(".bash_profile"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = LegacyShellRCPathCheck(environment: env)
        let result = check.check()

        if case .warn(let msg) = result {
            #expect(msg.contains(".zshrc"))
            #expect(msg.contains(".bash_profile"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("Fix removes marker and PATH line from affected RC files")
    func shellRCFix() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let zshrcPath = home.appendingPathComponent(".zshrc")
        let content = """
            export FOO=bar

            # Added by Claude Code iOS Setup
            export PATH="$HOME/.claude/bin:$PATH"

            export BAZ=qux
            """
        try content.write(to: zshrcPath, atomically: true, encoding: .utf8)

        let env = Environment(home: home)
        let check = LegacyShellRCPathCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains(".zshrc"))
            let cleaned = try String(contentsOf: zshrcPath, encoding: .utf8)
            #expect(!cleaned.contains("# Added by Claude Code iOS Setup"))
            #expect(!cleaned.contains("$HOME/.claude/bin"))
            #expect(cleaned.contains("export FOO=bar"))
            #expect(cleaned.contains("export BAZ=qux"))
            // Should not have triple blank lines
            #expect(!cleaned.contains("\n\n\n"))
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    @Test("Fix cleans both files when both are affected")
    func shellRCFixBothFiles() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let marker = """
            # Added by Claude Code iOS Setup
            export PATH="$HOME/.claude/bin:$PATH"
            """
        try "before\n\(marker)\nafter".write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )
        try "bash stuff\n\(marker)\nmore bash".write(
            to: home.appendingPathComponent(".bash_profile"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = LegacyShellRCPathCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains(".zshrc"))
            #expect(msg.contains(".bash_profile"))
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    @Test("allRCFiles returns all three shell RC paths")
    func allRCFiles() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let files = LegacyShellRCPathCheck.allRCFiles(home: home)
        let names = files.map(\.lastPathComponent)

        #expect(names.contains(".zshrc"))
        #expect(names.contains(".bash_profile"))
        #expect(names.contains(".bashrc"))
        #expect(files.count == 3)
    }

    @Test("affectedFiles only returns files with the marker")
    func affectedFilesFiltering() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // .zshrc has marker, .bash_profile does not
        try "# Added by Claude Code iOS Setup\nexport PATH=\"$HOME/.claude/bin:$PATH\"\n".write(
            to: home.appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )
        try "clean file\n".write(
            to: home.appendingPathComponent(".bash_profile"),
            atomically: true, encoding: .utf8
        )

        let affected = LegacyShellRCPathCheck.affectedFiles(home: home)
        #expect(affected.count == 1)
        #expect(affected.first?.lastPathComponent == ".zshrc")
    }

    // MARK: - SerenaMemoryMigrationCheck

    @Test("Pass when no .serena/memories/ exists")
    func serenaMemoriesPass() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.check()

        if case .pass = result {
            // Expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Pass when .serena/memories/ is already a symlink")
    func serenaMemoriesPassWhenSymlink() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)
        let claudeDir = env.memoriesDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let serenaDir = home.appendingPathComponent(".serena")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)
        let serenaMemories = serenaDir.appendingPathComponent("memories")
        try FileManager.default.createSymbolicLink(at: serenaMemories, withDestinationURL: claudeDir)

        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.check()

        if case .pass(let msg) = result {
            #expect(msg.contains("symlink"))
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Fail when .serena/memories/ has files")
    func serenaMemoriesFail() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let serenaDir = home.appendingPathComponent(".serena/memories")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)
        try "learning".write(
            to: serenaDir.appendingPathComponent("learning_swift.md"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.check()

        if case .fail(let msg) = result {
            #expect(msg.contains("1 file(s)"))
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("Fail when .serena/memories/ exists as empty directory (should be symlink)")
    func serenaMemoriesEmptyDirFail() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let serenaDir = home.appendingPathComponent(".serena/memories")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)

        let env = Environment(home: home)
        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.check()

        if case .fail(let msg) = result {
            #expect(msg.contains("should be a symlink"))
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("Fix creates symlink for empty .serena/memories/ directory")
    func serenaMemoriesEmptyDirFix() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let serenaDir = home.appendingPathComponent(".serena/memories")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)

        let env = Environment(home: home)
        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains("0 file(s)"))
            // Verify symlink was created
            let attrs = try FileManager.default.attributesOfItem(atPath: serenaDir.path)
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    @Test("Fix copies files and creates symlink")
    func serenaMemoriesFix() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let serenaDir = home.appendingPathComponent(".serena/memories")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)
        try "learning about Swift".write(
            to: serenaDir.appendingPathComponent("learning_swift.md"),
            atomically: true, encoding: .utf8
        )
        try "decision about architecture".write(
            to: serenaDir.appendingPathComponent("decision_arch.md"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains("2 file(s)"))
            let claudeDir = env.memoriesDirectory
            #expect(FileManager.default.fileExists(
                atPath: claudeDir.appendingPathComponent("learning_swift.md").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: claudeDir.appendingPathComponent("decision_arch.md").path
            ))
            // Verify symlink was created
            let attrs = try FileManager.default.attributesOfItem(atPath: serenaDir.path)
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }

    @Test("Fix does not overwrite existing files and creates symlink")
    func serenaMemoriesFixNoOverwrite() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let serenaDir = home.appendingPathComponent(".serena/memories")
        try FileManager.default.createDirectory(at: serenaDir, withIntermediateDirectories: true)
        try "old content".write(
            to: serenaDir.appendingPathComponent("existing.md"),
            atomically: true, encoding: .utf8
        )

        let env = Environment(home: home)
        let claudeDir = env.memoriesDirectory
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "new content already here".write(
            to: claudeDir.appendingPathComponent("existing.md"),
            atomically: true, encoding: .utf8
        )

        let check = SerenaMemoryMigrationCheck(environment: env)
        let result = check.fix()

        if case .fixed(let msg) = result {
            #expect(msg.contains("0 file(s)"))
            // Existing content should NOT be overwritten
            let existing = try String(
                contentsOf: claudeDir.appendingPathComponent("existing.md"),
                encoding: .utf8
            )
            #expect(existing == "new content already here")
            // Verify symlink was created
            let attrs = try FileManager.default.attributesOfItem(atPath: serenaDir.path)
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }
}
