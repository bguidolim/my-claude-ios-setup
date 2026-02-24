import Foundation
import Testing

@testable import mcs

@Suite("CLAUDELocalFreshnessCheck")
struct CLAUDELocalFreshnessCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-freshness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a CLAUDE.local.md file with section markers and content.
    private func writeClaudeLocal(at projectRoot: URL, sections: [(id: String, version: String, content: String)]) throws {
        var lines: [String] = []
        for section in sections {
            lines.append("<!-- mcs:begin \(section.id) v\(section.version) -->")
            lines.append(section.content)
            lines.append("<!-- mcs:end \(section.id) -->")
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        try content.write(
            to: projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Create a ProjectState with configured packs and resolved values, then save it.
    private func writeProjectState(
        at projectRoot: URL,
        packs: [String],
        resolvedValues: [String: String]? = nil
    ) throws {
        var state = ProjectState(projectRoot: projectRoot)
        for pack in packs {
            state.recordPack(pack)
        }
        if let values = resolvedValues {
            state.setResolvedValues(values)
        }
        try state.save()
    }

    /// Build a fake registry with packs that have the given template contributions.
    private func makeRegistry(packs: [(id: String, templates: [TemplateContribution])]) -> TechPackRegistry {
        let fakePacks: [any TechPack] = packs.map { pack in
            StubTechPack(identifier: pack.id, templates: pack.templates)
        }
        return TechPackRegistry.withExternalPacks(fakePacks)
    }

    // MARK: - Content matches (pass)

    @Test("Content matches stored values — pass")
    func contentMatches() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateContent = "Hello __NAME__"
        let resolvedValues = ["NAME": "World"]
        let rendered = TemplateEngine.substitute(template: templateContent, values: resolvedValues)

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", version: MCSVersion.current, content: rendered),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__NAME__"]),
            ]),
        ])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let result = check.check()
        if case .pass(let msg) = result {
            #expect(msg.contains("content verified"))
        } else {
            Issue.record("Expected pass but got \(result)")
        }
    }

    // MARK: - Content drifted (fail)

    @Test("Content manually edited — fail with drift detection")
    func contentDrifted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateContent = "Hello __NAME__"
        let resolvedValues = ["NAME": "World"]

        // Write CLAUDE.local.md with manually-modified content
        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", version: MCSVersion.current, content: "Hello World — I edited this!"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__NAME__"]),
            ]),
        ])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let result = check.check()
        if case .fail(let msg) = result {
            #expect(msg.contains("outdated sections"))
        } else {
            Issue.record("Expected fail but got \(result)")
        }
    }

    // MARK: - Legacy fallback (no resolvedValues)

    @Test("Legacy state without resolvedValues — version-only check")
    func legacyFallback() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", version: MCSVersion.current, content: "Some content"),
        ])
        // Save state WITHOUT resolved values
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: nil)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: "Different template", placeholders: []),
            ]),
        ])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let result = check.check()
        if case .pass(let msg) = result {
            #expect(msg.contains("version-only"))
        } else {
            Issue.record("Expected pass (version-only) but got \(result)")
        }
    }

    // MARK: - No CLAUDE.local.md file (skip)

    @Test("No CLAUDE.local.md — skip")
    func noFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = makeRegistry(packs: [])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let result = check.check()
        if case .skip(let msg) = result {
            #expect(msg.contains("not found"))
        } else {
            Issue.record("Expected skip but got \(result)")
        }
    }

    // MARK: - Fix re-renders drifted content

    @Test("Fix re-renders drifted content from stored values")
    func fixReRenders() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateContent = "Hello __NAME__"
        let resolvedValues = ["NAME": "World"]

        // Write drifted content
        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", version: MCSVersion.current, content: "Hello World — tampered!"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__NAME__"]),
            ]),
        ])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let fixResult = check.fix()
        if case .fixed(let msg) = fixResult {
            #expect(msg.contains("re-rendered"))
        } else {
            Issue.record("Expected fixed but got \(fixResult)")
        }

        // Verify the file was restored
        let fileContent = try String(
            contentsOf: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            encoding: .utf8
        )
        #expect(fileContent.contains("Hello World"))
        #expect(!fileContent.contains("tampered"))
    }

    // MARK: - Missing pack in registry

    @Test("Pack removed from registry — section reported as unmanaged, still passes")
    func missingPack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolvedValues = ["NAME": "World"]

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "removed-pack", version: MCSVersion.current, content: "Hello World"),
        ])
        try writeProjectState(at: tmpDir, packs: ["removed-pack"], resolvedValues: resolvedValues)

        // Empty registry — pack no longer exists
        let registry = makeRegistry(packs: [])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let result = check.check()
        // With no expected sections, SectionValidator marks them as unmanaged (not outdated) → passes
        if case .pass(let msg) = result {
            #expect(msg.contains("content verified"))
        } else {
            Issue.record("Expected pass but got \(result)")
        }
    }

    // MARK: - resolvedValues round-trip

    @Test("ProjectState save/load preserves resolvedValues")
    func resolvedValuesRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let values = ["PROJECT": "MyApp", "REPO": "my-repo", "CUSTOM_KEY": "custom-value"]

        var state = ProjectState(projectRoot: tmpDir)
        state.recordPack("test-pack")
        state.setResolvedValues(values)
        try state.save()

        // Reload from disk
        let loaded = ProjectState(projectRoot: tmpDir)
        #expect(loaded.resolvedValues == values)
        #expect(loaded.configuredPacks.contains("test-pack"))
    }

    // MARK: - Legacy fallback with outdated version

    @Test("Legacy state with outdated version markers — warns with version-only hint")
    func legacyFallbackOutdatedVersion() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", version: "1.0.0", content: "Old content"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: nil)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: "New template", placeholders: []),
            ]),
        ])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let result = check.check()
        if case .warn(let msg) = result {
            #expect(msg.contains("version-only"))
            #expect(msg.contains("test-pack"))
        } else {
            Issue.record("Expected warn but got \(result)")
        }
    }

    // MARK: - Fix not fixable without stored values

    @Test("Fix without stored values — not fixable")
    func fixNotFixableWithoutValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", version: "1.0.0", content: "Old content"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: nil)

        let registry = makeRegistry(packs: [])
        let context = ProjectDoctorContext(projectRoot: tmpDir, registry: registry)
        let check = CLAUDELocalFreshnessCheck(context: context)

        let fixResult = check.fix()
        if case .notFixable(let msg) = fixResult {
            #expect(msg.contains("no stored values"))
        } else {
            Issue.record("Expected notFixable but got \(fixResult)")
        }
    }
}

// MARK: - Test doubles

private struct StubTechPack: TechPack {
    let identifier: String
    let displayName: String = "Stub Pack"
    let description: String = "A stub pack for testing"
    let components: [ComponentDefinition] = []
    let templates: [TemplateContribution]
    let hookContributions: [HookContribution] = []
    let gitignoreEntries: [String] = []
    let supplementaryDoctorChecks: [any DoctorCheck] = []

    func configureProject(at path: URL, context: ProjectConfigContext) throws {}
}
