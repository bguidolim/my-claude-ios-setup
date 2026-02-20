import CryptoKit
import Foundation

/// Validates managed sections in composed template files.
///
/// Parses `<!-- mcs:begin/end -->` section markers, compares each section's
/// content hash against the expected template, and can re-render outdated
/// sections while preserving user content outside markers.
struct SectionValidator: Sendable {
    /// Describes a single section that was checked.
    struct SectionStatus: Sendable {
        let identifier: String
        let installedVersion: String
        let currentVersion: String?
        let isOutdated: Bool
        let detail: String
    }

    /// Result of validating all sections in a file.
    struct ValidationResult: Sendable {
        let filePath: URL
        let sections: [SectionStatus]

        var hasOutdated: Bool {
            sections.contains { $0.isOutdated }
        }

        var outdatedSections: [SectionStatus] {
            sections.filter { $0.isOutdated }
        }
    }

    // MARK: - Validation

    /// Validate sections in a composed file against expected templates.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the composed file on disk.
    ///   - expectedSections: Dictionary of section identifier to (version, rendered content).
    /// - Returns: Validation result with per-section status.
    static func validate(
        fileURL: URL,
        expectedSections: [String: (version: String, content: String)]
    ) -> ValidationResult {
        guard let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ValidationResult(filePath: fileURL, sections: [])
        }

        let installedSections = TemplateComposer.parseSections(from: fileContent)
        var statuses: [SectionStatus] = []

        for installed in installedSections {
            if let expected = expectedSections[installed.identifier] {
                let installedHash = contentHash(installed.content)
                let expectedHash = contentHash(expected.content)
                let isOutdated = installedHash != expectedHash

                statuses.append(SectionStatus(
                    identifier: installed.identifier,
                    installedVersion: installed.version,
                    currentVersion: expected.version,
                    isOutdated: isOutdated,
                    detail: isOutdated
                        ? "v\(installed.version) -> v\(expected.version)"
                        : "v\(installed.version) up to date"
                ))
            } else {
                // Section exists in file but has no expected template --
                // could be from an unregistered pack; skip it.
                statuses.append(SectionStatus(
                    identifier: installed.identifier,
                    installedVersion: installed.version,
                    currentVersion: nil,
                    isOutdated: false,
                    detail: "unmanaged section, skipped"
                ))
            }
        }

        // Check for expected sections that are missing from the file
        for (identifier, expected) in expectedSections {
            if !installedSections.contains(where: { $0.identifier == identifier }) {
                statuses.append(SectionStatus(
                    identifier: identifier,
                    installedVersion: "(missing)",
                    currentVersion: expected.version,
                    isOutdated: true,
                    detail: "section not found in file"
                ))
            }
        }

        return ValidationResult(filePath: fileURL, sections: statuses)
    }

    // MARK: - Fix

    /// Re-render outdated managed sections in a composed file.
    ///
    /// Replaces only sections that have a matching expected template.
    /// User content (anything outside section markers) is preserved.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the composed file.
    ///   - expectedSections: Dictionary of section identifier to (version, rendered content).
    /// - Returns: `true` if the file was updated, `false` if no changes were needed or the file could not be read.
    @discardableResult
    static func fix(
        fileURL: URL,
        expectedSections: [String: (version: String, content: String)]
    ) throws -> Bool {
        guard let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }

        let result = validate(fileURL: fileURL, expectedSections: expectedSections)
        guard result.hasOutdated else { return false }

        var updatedContent = fileContent

        for section in result.outdatedSections {
            guard let expected = expectedSections[section.identifier] else { continue }

            updatedContent = TemplateComposer.replaceSection(
                in: updatedContent,
                sectionIdentifier: section.identifier,
                newContent: expected.content,
                newVersion: expected.version
            )
        }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Helpers

    /// Compute a SHA-256 hash of a string's content (trimmed of leading/trailing whitespace).
    private static func contentHash(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DoctorCheck conformance

/// A doctor check that validates a single composed file's sections.
struct SectionFreshnessCheck: DoctorCheck, Sendable {
    let section: String = "Templates"
    let name: String
    let fileURL: URL
    let expectedSections: [String: (version: String, content: String)]

    func check() -> CheckResult {
        let result = SectionValidator.validate(
            fileURL: fileURL,
            expectedSections: expectedSections
        )

        guard !result.sections.isEmpty else {
            return .skip("File not found: \(fileURL.lastPathComponent)")
        }

        if result.hasOutdated {
            let outdated = result.outdatedSections
                .map { "\($0.identifier) (\($0.detail))" }
                .joined(separator: ", ")
            return .fail("Outdated sections: \(outdated)")
        }

        let summary = result.sections
            .map { "\($0.identifier) \($0.detail)" }
            .joined(separator: ", ")
        return .pass(summary)
    }

    func fix() -> FixResult {
        do {
            let updated = try SectionValidator.fix(
                fileURL: fileURL,
                expectedSections: expectedSections
            )
            if updated {
                return .fixed("Updated outdated sections in \(fileURL.lastPathComponent)")
            }
            return .fixed("No changes needed")
        } catch {
            return .failed("Could not update \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
