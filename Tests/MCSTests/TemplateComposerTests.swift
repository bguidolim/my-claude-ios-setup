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
