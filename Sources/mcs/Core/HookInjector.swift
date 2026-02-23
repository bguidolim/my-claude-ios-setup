import Foundation

/// Centralizes hook fragment injection using `# --- mcs:begin/end ---` section markers.
/// Used by both core (continuous learning) and tech pack hook contributions.
///
/// Fragments are always inserted at the `# --- mcs:hook-extensions ---` marker
/// inside the hook file. If the marker is missing, injection fails with a warning
/// rather than appending to the wrong place.
enum HookInjector {
    /// Inject a fragment into a hook file using versioned section markers.
    ///
    /// - Removes any existing section for the given identifier (idempotent).
    /// - Inserts at the `# --- mcs:hook-extensions ---` marker.
    /// - Fails with a warning if the marker is not found.
    /// - Creates a backup before modifying the file.
    static func inject(
        fragment: String,
        identifier: String,
        version: String = MCSVersion.current,
        into hookFile: URL,
        backup: inout Backup,
        output: CLIOutput
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hookFile.path) else { return }

        var content: String
        do {
            content = try String(contentsOf: hookFile, encoding: .utf8)
        } catch {
            output.warn("Could not read \(hookFile.lastPathComponent): \(error.localizedDescription)")
            return
        }

        // Remove existing section (patterns include optional leading whitespace)
        let beginPattern = #"[ \t]*# --- mcs:begin \#(identifier)( v[0-9]+\.[0-9]+\.[0-9]+)? ---"#
        let endPattern = #"[ \t]*# --- mcs:end \#(identifier) ---"#
        if let beginRange = content.range(of: beginPattern, options: .regularExpression),
           let endRange = content.range(of: endPattern, options: .regularExpression) {
            var removeEnd = endRange.upperBound
            // Consume trailing newline
            if removeEnd < content.endIndex && content[removeEnd] == "\n" {
                removeEnd = content.index(after: removeEnd)
            }
            // Consume extra blank line after end marker
            if removeEnd < content.endIndex && content[removeEnd] == "\n" {
                removeEnd = content.index(after: removeEnd)
            }
            var removeStart = beginRange.lowerBound
            // Consume preceding newline
            if removeStart > content.startIndex {
                let before = content.index(before: removeStart)
                if content[before] == "\n" {
                    removeStart = before
                }
            }
            content.removeSubrange(removeStart..<removeEnd)
        }

        // Build the marked section (indented to match function body)
        let beginMarker = "# --- mcs:begin \(identifier) v\(version) ---"
        let endMarker = "# --- mcs:end \(identifier) ---"
        let section = "    \(beginMarker)\n\(fragment)\n    \(endMarker)"

        // Insert at the hook-extensions marker
        let extensionMarker = "    \(Constants.Hooks.extensionMarker)"
        guard let markerRange = content.range(of: extensionMarker) else {
            output.error("Missing '\(Constants.Hooks.extensionMarker)' marker in \(hookFile.lastPathComponent) — cannot inject \(identifier) fragment")
            return
        }
        content.insert(contentsOf: "\(section)\n\n", at: markerRange.lowerBound)

        do {
            try backup.backupFile(at: hookFile)
        } catch {
            output.warn("Could not backup \(hookFile.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            try content.write(to: hookFile, atomically: true, encoding: .utf8)
            output.success("Injected \(identifier) hook fragment into \(hookFile.deletingPathExtension().lastPathComponent)")
        } catch {
            output.warn("Could not write \(hookFile.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
