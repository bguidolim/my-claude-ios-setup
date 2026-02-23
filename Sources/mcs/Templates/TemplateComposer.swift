import Foundation

enum TemplateComposer {
    /// A parsed section from a composed file.
    struct Section {
        let identifier: String  // e.g., "core", "ios"
        let version: String     // e.g., "2.0.0"
        let content: String     // Content between markers
    }

    // MARK: - Marker generation

    static func beginMarker(identifier: String, version: String) -> String {
        "<!-- mcs:begin \(identifier) v\(version) -->"
    }

    static func endMarker(identifier: String) -> String {
        "<!-- mcs:end \(identifier) -->"
    }

    // MARK: - Composition

    /// Compose a file from core content and tech pack contributions.
    /// Uses `MCSVersion.current` for all section markers.
    static func compose(
        coreContent: String,
        packContributions: [TemplateContribution] = [],
        values: [String: String] = [:]
    ) -> String {
        let version = MCSVersion.current
        var parts: [String] = []

        // Core section
        let processedCore = TemplateEngine.substitute(template: coreContent, values: values)
        parts.append(beginMarker(identifier: "core", version: version))
        parts.append(processedCore)
        parts.append(endMarker(identifier: "core"))

        // Pack contributions
        for contribution in packContributions {
            let processedContent = TemplateEngine.substitute(
                template: contribution.templateContent,
                values: values
            )
            parts.append("")
            parts.append(beginMarker(
                identifier: contribution.sectionIdentifier,
                version: version
            ))
            parts.append(processedContent)
            parts.append(endMarker(identifier: contribution.sectionIdentifier))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Parse sections from an existing composed file.
    static func parseSections(from content: String) -> [Section] {
        var sections: [Section] = []
        let lines = content.components(separatedBy: "\n")

        var currentSection: (identifier: String, version: String)?
        var currentContent: [String] = []

        for line in lines {
            if let parsed = parseBeginMarker(line) {
                currentSection = parsed
                currentContent = []
            } else if let identifier = parseEndMarker(line),
                      let section = currentSection,
                      section.identifier == identifier {
                sections.append(Section(
                    identifier: section.identifier,
                    version: section.version,
                    content: currentContent.joined(separator: "\n")
                ))
                currentSection = nil
                currentContent = []
            } else if currentSection != nil {
                currentContent.append(line)
            }
        }

        return sections
    }

    /// Extract content that is NOT inside any section markers (user content).
    static func extractUserContent(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var userLines: [String] = []
        var inSection = false

        for line in lines {
            if parseBeginMarker(line) != nil {
                inSection = true
            } else if parseEndMarker(line) != nil {
                inSection = false
            } else if !inSection {
                userLines.append(line)
            }
        }

        return userLines.joined(separator: "\n")
    }

    /// Validate that all section markers in the content are properly paired.
    /// Returns identifiers of sections that have a begin marker but no matching end marker.
    static func unpairedSections(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var openSections: [String] = []
        var unpaired: [String] = []

        for line in lines {
            if let parsed = parseBeginMarker(line) {
                // If there was already an open section, it's unpaired
                if let previous = openSections.last {
                    unpaired.append(previous)
                }
                openSections.append(parsed.identifier)
            } else if let identifier = parseEndMarker(line) {
                if openSections.last == identifier {
                    openSections.removeLast()
                }
            }
        }

        // Any remaining open sections are unpaired
        unpaired.append(contentsOf: openSections)
        return unpaired
    }

    /// Replace a specific section in an existing composed file.
    /// Preserves all content outside the target section markers.
    ///
    /// If the target section has a begin marker but no matching end marker,
    /// returns the original content unchanged to prevent data loss.
    /// Check `unpairedSections(in:)` to detect this condition beforehand.
    static func replaceSection(
        in existingContent: String,
        sectionIdentifier: String,
        newContent: String,
        newVersion: String
    ) -> String {
        // Safety check: refuse to modify if the target section has an unpaired marker.
        // Without this, a missing end marker would cause all subsequent content to be dropped.
        let unpaired = unpairedSections(in: existingContent)
        if unpaired.contains(sectionIdentifier) {
            return existingContent
        }

        let lines = existingContent.components(separatedBy: "\n")
        var result: [String] = []
        var skipUntilEnd = false
        var replaced = false

        for line in lines {
            if let parsed = parseBeginMarker(line),
               parsed.identifier == sectionIdentifier {
                // Replace this section
                result.append(beginMarker(
                    identifier: sectionIdentifier,
                    version: newVersion
                ))
                result.append(newContent)
                skipUntilEnd = true
                replaced = true
            } else if let identifier = parseEndMarker(line),
                      identifier == sectionIdentifier {
                result.append(endMarker(identifier: sectionIdentifier))
                skipUntilEnd = false
            } else if !skipUntilEnd {
                result.append(line)
            }
        }

        // If section wasn't found, append it
        if !replaced {
            result.append("")
            result.append(beginMarker(
                identifier: sectionIdentifier,
                version: newVersion
            ))
            result.append(newContent)
            result.append(endMarker(identifier: sectionIdentifier))
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func parseBeginMarker(
        _ line: String
    ) -> (identifier: String, version: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Match: <!-- mcs:begin identifier vX.Y.Z -->
        guard trimmed.hasPrefix("<!-- mcs:begin "),
              trimmed.hasSuffix(" -->") else { return nil }
        let inner = trimmed
            .dropFirst("<!-- mcs:begin ".count)
            .dropLast(" -->".count)
        let parts = inner.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[1].hasPrefix("v") else { return nil }
        let identifier = String(parts[0])
        let version = String(parts[1].dropFirst()) // drop "v"
        return (identifier, version)
    }

    private static func parseEndMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Match: <!-- mcs:end identifier -->
        guard trimmed.hasPrefix("<!-- mcs:end "),
              trimmed.hasSuffix(" -->") else { return nil }
        let identifier = trimmed
            .dropFirst("<!-- mcs:end ".count)
            .dropLast(" -->".count)
        return String(identifier)
    }
}
