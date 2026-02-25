import Foundation
import Testing

@testable import mcs

@Suite("TemplateComposer")
struct TemplateComposerTests {
    // MARK: - Composition

    @Test("Compose core-only content with no pack contributions")
    func composeCoreOnly() {
        let result = TemplateComposer.compose(
            coreContent: "Core instructions here"
        )

        let version = MCSVersion.current
        #expect(result.contains("<!-- mcs:begin core v\(version) -->"))
        #expect(result.contains("Core instructions here"))
        #expect(result.contains("<!-- mcs:end core -->"))
    }

    @Test("Compose core + one pack contribution")
    func composeCoreAndPack() {
        let contribution = TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: "iOS-specific content for __PROJECT__",
            placeholders: ["__PROJECT__"]
        )

        let result = TemplateComposer.compose(
            coreContent: "Core content",
            packContributions: [contribution],
            values: ["PROJECT": "MyApp"]
        )

        let version = MCSVersion.current
        #expect(result.contains("<!-- mcs:begin core v\(version) -->"))
        #expect(result.contains("Core content"))
        #expect(result.contains("<!-- mcs:end core -->"))
        #expect(result.contains("<!-- mcs:begin ios v\(version) -->"))
        #expect(result.contains("iOS-specific content for MyApp"))
        #expect(result.contains("<!-- mcs:end ios -->"))
    }

    @Test("Compose applies template substitution to core content")
    func composeSubstitutesCore() {
        let result = TemplateComposer.compose(
            coreContent: "Repo: __REPO_NAME__",
            values: ["REPO_NAME": "my-repo"]
        )

        #expect(result.contains("Repo: my-repo"))
    }

    // MARK: - Parsing

    @Test("Parse sections from composed file")
    func parseSections() {
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core stuff
            <!-- mcs:end core -->

            <!-- mcs:begin ios v2.0.0 -->
            iOS stuff
            <!-- mcs:end ios -->
            """

        let sections = TemplateComposer.parseSections(from: content)

        #expect(sections.count == 2)
        #expect(sections[0].identifier == "core")
        #expect(sections[0].version == "1.0.0")
        #expect(sections[0].content == "Core stuff")
        #expect(sections[1].identifier == "ios")
        #expect(sections[1].version == "2.0.0")
        #expect(sections[1].content == "iOS stuff")
    }

    @Test("Section version parsing extracts version without v prefix")
    func sectionVersionParsing() {
        let content = """
            <!-- mcs:begin core v3.2.1 -->
            Content
            <!-- mcs:end core -->
            """
        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.first?.version == "3.2.1")
    }

    // MARK: - User content extraction

    @Test("Extract user content outside markers")
    func extractUserContent() {
        let content = """
            User notes at top
            <!-- mcs:begin core v1.0.0 -->
            Managed content
            <!-- mcs:end core -->
            User notes at bottom
            """

        let userContent = TemplateComposer.extractUserContent(from: content)

        #expect(userContent.contains("User notes at top"))
        #expect(userContent.contains("User notes at bottom"))
        #expect(!userContent.contains("Managed content"))
    }

    @Test("File with no markers returns all content as user content")
    func noMarkersAllUserContent() {
        let content = "Just some user text\nSecond line"
        let userContent = TemplateComposer.extractUserContent(from: content)
        #expect(userContent == content)
    }

    @Test("File with no markers returns empty sections")
    func noMarkersSections() {
        let content = "No markers here"
        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.isEmpty)
    }

    // MARK: - Section replacement

    @Test("Replace specific section preserving others")
    func replaceSection() {
        let original = """
            <!-- mcs:begin core v1.0.0 -->
            Old core
            <!-- mcs:end core -->

            <!-- mcs:begin ios v1.0.0 -->
            Old iOS
            <!-- mcs:end ios -->
            """

        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "core",
            newContent: "New core",
            newVersion: "2.0.0"
        )

        #expect(result.contains("<!-- mcs:begin core v2.0.0 -->"))
        #expect(result.contains("New core"))
        #expect(result.contains("<!-- mcs:end core -->"))
        // iOS section preserved
        #expect(result.contains("<!-- mcs:begin ios v1.0.0 -->"))
        #expect(result.contains("Old iOS"))
        #expect(result.contains("<!-- mcs:end ios -->"))
        // Old core replaced
        #expect(!result.contains("Old core"))
    }

    @Test("Replace appends section if not found")
    func replaceSectionAppends() {
        let original = """
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->
            """

        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "android",
            newContent: "Android content",
            newVersion: "1.0.0"
        )

        #expect(result.contains("<!-- mcs:begin android v1.0.0 -->"))
        #expect(result.contains("Android content"))
        #expect(result.contains("<!-- mcs:end android -->"))
        // Original preserved
        #expect(result.contains("Core content"))
    }

    // MARK: - Unpaired marker detection

    @Test("Detect unpaired begin marker with missing end marker")
    func unpairedBeginMarker() {
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core stuff
            """
        let unpaired = TemplateComposer.unpairedSections(in: content)
        #expect(unpaired == ["core"])
    }

    @Test("No unpaired markers in well-formed content")
    func noPairedMarkers() {
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core stuff
            <!-- mcs:end core -->
            """
        let unpaired = TemplateComposer.unpairedSections(in: content)
        #expect(unpaired.isEmpty)
    }

    @Test("replaceSection preserves content when target section has unpaired marker")
    func replaceSectionUnpairedSafety() {
        let original = """
            <!-- mcs:begin core v1.0.0 -->
            Core stuff
            User content below
            """
        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "core",
            newContent: "New core",
            newVersion: "2.0.0"
        )
        // Should return original unchanged to prevent data loss
        #expect(result == original)
    }

    @Test("replaceSection works normally when a different section is unpaired")
    func replaceSectionOtherUnpaired() {
        let original = """
            <!-- mcs:begin core v1.0.0 -->
            Core stuff
            <!-- mcs:end core -->
            <!-- mcs:begin ios v1.0.0 -->
            iOS stuff without end marker
            """
        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "core",
            newContent: "New core",
            newVersion: "2.0.0"
        )
        // Core section should be replaced (it's well-formed)
        #expect(result.contains("New core"))
        #expect(!result.contains("Core stuff"))
        // iOS section preserved as-is (not the target)
        #expect(result.contains("iOS stuff without end marker"))
    }

    // MARK: - Section removal

    @Test("Remove a section from composed content")
    func removeSection() {
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->

            <!-- mcs:begin ios v1.0.0 -->
            iOS content
            <!-- mcs:end ios -->

            <!-- mcs:begin web v1.0.0 -->
            Web content
            <!-- mcs:end web -->
            """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "ios"
        )

        #expect(!result.contains("iOS content"))
        #expect(!result.contains("mcs:begin ios"))
        #expect(!result.contains("mcs:end ios"))
        // Others preserved
        #expect(result.contains("Core content"))
        #expect(result.contains("Web content"))
    }

    @Test("Remove nonexistent section returns original")
    func removeSectionNotFound() {
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->
            """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "nonexistent"
        )

        #expect(result == content)
    }

    @Test("Remove last section returns clean content")
    func removeLastSection() {
        let content = """
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->
            """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "core"
        )

        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Remove section preserves user content outside markers")
    func removeSectionPreservesUserContent() {
        let content = """
            User notes at top
            <!-- mcs:begin core v1.0.0 -->
            Core content
            <!-- mcs:end core -->

            <!-- mcs:begin ios v1.0.0 -->
            iOS content
            <!-- mcs:end ios -->
            User notes at bottom
            """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "ios"
        )

        #expect(result.contains("User notes at top"))
        #expect(result.contains("Core content"))
        #expect(result.contains("User notes at bottom"))
        #expect(!result.contains("iOS content"))
    }

    // MARK: - Round-trip

    @Test("Compose then parse round-trip preserves content")
    func composeParseRoundTrip() {
        let contribution = TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: "iOS rules",
            placeholders: []
        )

        let composed = TemplateComposer.compose(
            coreContent: "Core rules",
            packContributions: [contribution]
        )

        let sections = TemplateComposer.parseSections(from: composed)
        #expect(sections.count == 2)
        #expect(sections[0].identifier == "core")
        #expect(sections[0].content == "Core rules")
        #expect(sections[1].identifier == "ios")
        #expect(sections[1].content == "iOS rules")
    }
}

// MARK: - composeOrUpdate

@Suite("TemplateComposer — composeOrUpdate")
struct ComposeOrUpdateTests {
    private func coreContribution(_ content: String = "Core rules") -> TemplateContribution {
        TemplateContribution(
            sectionIdentifier: "core",
            templateContent: content,
            placeholders: []
        )
    }

    private func packContribution(
        _ id: String,
        _ content: String,
        placeholders: [String] = []
    ) -> TemplateContribution {
        TemplateContribution(
            sectionIdentifier: id,
            templateContent: content,
            placeholders: placeholders
        )
    }

    @Test("Fresh compose when no existing content")
    func freshCompose() {
        let result = TemplateComposer.composeOrUpdate(
            existingContent: nil,
            contributions: [coreContribution()],
            values: [:]
        )

        let sections = TemplateComposer.parseSections(from: result.content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "core")
        #expect(sections[0].content == "Core rules")
        #expect(result.warnings.isEmpty)
    }

    @Test("v1 content without markers produces fresh compose")
    func v1MigrationCompose() {
        let result = TemplateComposer.composeOrUpdate(
            existingContent: "Old v1 content without any markers",
            contributions: [coreContribution("New core")],
            values: [:]
        )

        let sections = TemplateComposer.parseSections(from: result.content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "core")
        #expect(sections[0].content == "New core")
        #expect(!result.content.contains("Old v1 content"))
        #expect(result.warnings.isEmpty)
    }

    @Test("v2 content with markers is updated in place")
    func v2Update() {
        let existing = TemplateComposer.compose(coreContent: "Old core")

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existing,
            contributions: [coreContribution("Updated core")],
            values: [:]
        )

        let sections = TemplateComposer.parseSections(from: result.content)
        #expect(sections.count == 1)
        #expect(sections[0].content == "Updated core")
        #expect(!result.content.contains("Old core"))
        #expect(result.warnings.isEmpty)
    }

    @Test("v2 update preserves user content outside markers")
    func v2UpdatePreservesUserContent() {
        let existing = TemplateComposer.compose(coreContent: "Core")
            + "\n\nMy custom notes\n"

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existing,
            contributions: [coreContribution("New core")],
            values: [:]
        )

        #expect(result.content.contains("New core"))
        #expect(result.content.contains("My custom notes"))
        #expect(result.warnings.isEmpty)
    }

    @Test("Template values are substituted during compose")
    func valuesSubstituted() {
        let ios = packContribution("ios", "iOS rules for __PROJECT__", placeholders: ["__PROJECT__"])

        let result = TemplateComposer.composeOrUpdate(
            existingContent: nil,
            contributions: [coreContribution(), ios],
            values: ["PROJECT": "MyApp.xcodeproj"]
        )

        #expect(result.content.contains("MyApp.xcodeproj"))
        #expect(!result.content.contains("__PROJECT__"))
    }

    @Test("Unpaired markers produce warnings and leave damaged section unchanged")
    func unpairedMarkersWarn() {
        let existing = """
        <!-- mcs:begin core v1.0.0 -->
        Core rules
        <!-- mcs:end core -->

        <!-- mcs:begin ios v1.0.0 -->
        iOS rules without end marker
        """

        let ios = packContribution("ios", "Updated iOS")
        let result = TemplateComposer.composeOrUpdate(
            existingContent: existing,
            contributions: [coreContribution("New core"), ios],
            values: [:]
        )

        #expect(result.warnings.count == 3)
        #expect(result.warnings[0].contains("Unpaired section markers"))
        // The unpaired "ios" section is left unchanged by replaceSection's safety check
        #expect(result.content.contains("iOS rules without end marker"))
    }
}
