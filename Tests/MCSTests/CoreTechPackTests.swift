import Foundation
import Testing

@testable import mcs

@Suite("CoreTechPack")
struct CoreTechPackTests {
    @Test("Core pack has correct identifier")
    func packIdentifier() {
        let pack = CoreTechPack()
        #expect(pack.identifier == "core")
    }

    @Test("Core pack has correct display name")
    func packDisplayName() {
        let pack = CoreTechPack()
        #expect(pack.displayName == "Core")
    }

    @Test("Core pack has no components")
    func noComponents() {
        let pack = CoreTechPack()
        #expect(pack.components.isEmpty)
    }

    @Test("Core pack has no hook contributions")
    func noHooks() {
        let pack = CoreTechPack()
        #expect(pack.hookContributions.isEmpty)
    }

    @Test("Core pack has no gitignore entries")
    func noGitignore() {
        let pack = CoreTechPack()
        #expect(pack.gitignoreEntries.isEmpty)
    }

    @Test("Core pack has no supplementary doctor checks")
    func noDoctorChecks() {
        let pack = CoreTechPack()
        #expect(pack.supplementaryDoctorChecks.isEmpty)
    }

    @Test("configureProject is a no-op")
    func configureNoOp() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-core-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = CoreTechPack()
        let context = ProjectConfigContext(projectPath: tmpDir, repoName: "test")
        try pack.configureProject(at: tmpDir, context: context)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        #expect(contents.isEmpty)
    }

    @Test("Registry contains core pack")
    func registryContainsCore() {
        let registry = TechPackRegistry.shared
        let core = registry.pack(for: "core")
        #expect(core != nil)
        #expect(core?.displayName == "Core")
    }

    @Test("Registry lists core before iOS")
    func registryOrder() {
        let packs = TechPackRegistry.shared.availablePacks
        let identifiers = packs.map(\.identifier)
        #expect(identifiers.count >= 2)
        #expect(identifiers.first == "core")
        #expect(identifiers.contains("ios"))
    }
}

@Suite("CoreTemplates")
struct CoreTemplatesTests {
    @Test("Symlink note contains relevant content")
    func symlinkNote() {
        #expect(CoreTemplates.symlinkNote.contains("symlink"))
        #expect(CoreTemplates.symlinkNote.contains("CLAUDE.md"))
    }

    @Test("Continuous learning section contains REPO_NAME placeholder")
    func continuousLearningPlaceholder() {
        #expect(CoreTemplates.continuousLearningSection.contains("__REPO_NAME__"))
    }

    @Test("Continuous learning section mentions search_docs")
    func continuousLearningContent() {
        #expect(CoreTemplates.continuousLearningSection.contains("search_docs"))
    }
}
