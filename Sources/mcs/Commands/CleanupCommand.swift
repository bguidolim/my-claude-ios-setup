import ArgumentParser
import Foundation

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Find and delete backup files"
    )

    @Flag(name: .long, help: "Delete backups without confirmation")
    var force: Bool = false

    mutating func run() throws {
        let env = Environment()
        let output = CLIOutput()

        output.header("Backup Cleanup")

        // Scan directories for backups
        var allBackups: [URL] = []

        // ~/.claude/
        allBackups.append(contentsOf: Backup.findBackups(in: env.claudeDirectory))

        // Current directory (if different from home)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if cwd.path != env.homeDirectory.path {
            allBackups.append(contentsOf: Backup.findBackups(in: cwd))
        }

        // Deduplicate by path
        var seen = Set<String>()
        let unique = allBackups.filter { url in
            let path = url.standardizedFileURL.path
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }.sorted { $0.path < $1.path }

        guard !unique.isEmpty else {
            output.success("No backup files found.")
            return
        }

        output.info("Found \(unique.count) backup file(s):")
        let fm = FileManager.default
        for backup in unique {
            let attrs = try? fm.attributesOfItem(atPath: backup.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            output.plain("  \(backup.lastPathComponent) (\(sizeStr))")
        }

        output.plain("")

        if force || output.askYesNo("Delete all \(unique.count) backup file(s)?", default: false) {
            do {
                try Backup.deleteBackups(unique)
                output.success("Deleted \(unique.count) backup file(s).")
            } catch {
                output.error("Failed to delete some backups: \(error.localizedDescription)")
            }
        } else {
            output.info("No backups deleted.")
        }
    }
}
