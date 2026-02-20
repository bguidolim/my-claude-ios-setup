import Foundation
import Testing

@testable import mcs

@Suite("SectionValidator")
struct SectionValidatorTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-section-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Parse section markers (via validate)

    @Test("Validate detects up-to-date section when content matches")
    func upToDateSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core instructions
            <!-- mcs:end core -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: ["core": (version: "1.0.0", content: "Core instructions")]
        )

        #expect(result.sections.count == 1)
        #expect(result.sections[0].identifier == "core")
        #expect(result.sections[0].isOutdated == false)
        #expect(!result.hasOutdated)
    }

    // MARK: - Detect outdated sections

    @Test("Validate detects outdated section when content differs")
    func outdatedSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Old content
            <!-- mcs:end core -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: ["core": (version: "2.0.0", content: "New content")]
        )

        #expect(result.sections.count == 1)
        #expect(result.sections[0].isOutdated == true)
        #expect(result.hasOutdated)
        #expect(result.outdatedSections.count == 1)
    }

    @Test("Validate detects missing expected section")
    func missingSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core only
            <!-- mcs:end core -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: [
                "core": (version: "1.0.0", content: "Core only"),
                "ios": (version: "1.0.0", content: "iOS stuff"),
            ]
        )

        let iosStatus = result.sections.first { $0.identifier == "ios" }
        #expect(iosStatus != nil)
        #expect(iosStatus?.isOutdated == true)
        #expect(iosStatus?.installedVersion == "(missing)")
    }

    // MARK: - Preserve user content outside markers

    @Test("Fix preserves user content outside section markers")
    func fixPreservesUserContent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            My custom notes
            <!-- mcs:begin core v1.0.0 -->
            Old core content
            <!-- mcs:end core -->
            More custom notes
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: ["core": (version: "2.0.0", content: "Updated core content")]
        )

        #expect(updated == true)

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result.contains("My custom notes"))
        #expect(result.contains("More custom notes"))
        #expect(result.contains("Updated core content"))
        #expect(!result.contains("Old core content"))
    }

    // MARK: - Re-render section preserving surrounding content

    @Test("Fix re-renders outdated section and updates version marker")
    func fixReRendersSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Stale content
            <!-- mcs:end core -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: ["core": (version: "2.0.0", content: "Fresh content")]
        )

        #expect(updated == true)

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result.contains("<!-- mcs:begin core v2.0.0 -->"))
        #expect(result.contains("Fresh content"))
        #expect(result.contains("<!-- mcs:end core -->"))
        #expect(!result.contains("Stale content"))
        #expect(!result.contains("v1.0.0"))
    }

    @Test("Fix returns false when nothing is outdated")
    func fixNoOpWhenUpToDate() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Current content
            <!-- mcs:end core -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: ["core": (version: "1.0.0", content: "Current content")]
        )

        #expect(updated == false)
    }

    // MARK: - File with no markers

    @Test("Validate file with no markers returns empty sections")
    func noMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("plain.md")
        try "Just plain text, no markers".write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: [:]
        )

        #expect(result.sections.isEmpty)
        #expect(!result.hasOutdated)
    }

    @Test("Validate nonexistent file returns empty sections")
    func nonexistentFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).md")

        let result = SectionValidator.validate(
            fileURL: missing,
            expectedSections: ["core": (version: "1.0.0", content: "stuff")]
        )

        #expect(result.sections.isEmpty)
    }

    // MARK: - Multiple sections (core + ios)

    @Test("Validate file with multiple sections (core + ios)")
    func multipleSections() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->

            <!-- mcs:begin ios v1.0.0 -->
            iOS content
            <!-- mcs:end ios -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: [
                "core": (version: "1.0.0", content: "Core content"),
                "ios": (version: "1.0.0", content: "iOS content"),
            ]
        )

        #expect(result.sections.count == 2)
        #expect(!result.hasOutdated)

        let coreStatus = result.sections.first { $0.identifier == "core" }
        let iosStatus = result.sections.first { $0.identifier == "ios" }
        #expect(coreStatus?.isOutdated == false)
        #expect(iosStatus?.isOutdated == false)
    }

    @Test("Fix updates only outdated section among multiple")
    func fixOnlyOutdatedAmongMultiple() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->

            <!-- mcs:begin ios v1.0.0 -->
            Old iOS
            <!-- mcs:end ios -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: [
                "core": (version: "1.0.0", content: "Core content"),
                "ios": (version: "2.0.0", content: "New iOS"),
            ]
        )

        #expect(updated == true)

        let result = try String(contentsOf: file, encoding: .utf8)
        // Core unchanged
        #expect(result.contains("<!-- mcs:begin core v1.0.0 -->"))
        #expect(result.contains("Core content"))
        // iOS updated
        #expect(result.contains("<!-- mcs:begin ios v2.0.0 -->"))
        #expect(result.contains("New iOS"))
        #expect(!result.contains("Old iOS"))
    }

    // MARK: - Unmanaged sections

    @Test("Unmanaged section in file is reported but not marked outdated")
    func unmanagedSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core
            <!-- mcs:end core -->

            <!-- mcs:begin custom-pack v0.1.0 -->
            Custom stuff
            <!-- mcs:end custom-pack -->
            """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: ["core": (version: "1.0.0", content: "Core")]
        )

        #expect(result.sections.count == 2)
        let customStatus = result.sections.first { $0.identifier == "custom-pack" }
        #expect(customStatus?.isOutdated == false)
        #expect(customStatus?.detail == "unmanaged section, skipped")
    }
}
