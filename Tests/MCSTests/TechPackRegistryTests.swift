import Foundation
import Testing

@testable import mcs

@Suite("TechPackRegistry")
struct TechPackRegistryTests {
    // MARK: - Basic registry

    @Test("Shared registry contains iOS pack")
    func sharedHasIOSPack() {
        let packs = TechPackRegistry.shared.availablePacks
        let identifiers = packs.map(\.identifier)
        #expect(identifiers.contains("ios"))
    }

    @Test("Find pack by identifier")
    func findByIdentifier() {
        let ios = TechPackRegistry.shared.pack(for: "ios")
        #expect(ios != nil)
        #expect(ios?.displayName == "iOS Development")

        let nonexistent = TechPackRegistry.shared.pack(for: "android")
        #expect(nonexistent == nil)
    }

    // MARK: - Filtered by installed packs

    @Test("supplementaryDoctorChecks returns empty when no packs installed")
    func supplementaryDoctorChecksEmpty() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: [])
        #expect(checks.isEmpty)
    }

    @Test("supplementaryDoctorChecks returns iOS checks when iOS pack is installed")
    func supplementaryDoctorChecksWithIOS() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: ["ios"])
        #expect(!checks.isEmpty)
        // iOS pack should contribute checks like XcodeBuildMCP, Sosumi, etc.
        let names = checks.map(\.name)
        #expect(names.contains(where: { $0.lowercased().contains("xcode") || $0.lowercased().contains("sosumi") || $0.lowercased().contains("config") }))
    }

    @Test("supplementaryDoctorChecks ignores unrecognized pack identifiers")
    func supplementaryDoctorChecksUnknownPack() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: ["nonexistent"])
        #expect(checks.isEmpty)
    }

    @Test("hookContributions returns empty when no packs installed")
    func hookContributionsEmpty() {
        let contributions = TechPackRegistry.shared.hookContributions(installedPacks: [])
        #expect(contributions.isEmpty)
    }

    @Test("hookContributions returns iOS hooks when iOS pack is installed")
    func hookContributionsWithIOS() {
        let contributions = TechPackRegistry.shared.hookContributions(installedPacks: ["ios"])
        #expect(!contributions.isEmpty)
        #expect(contributions.first?.pack.identifier == "ios")
        #expect(contributions.first?.contribution.hookName == "session_start")
    }

    @Test("gitignoreEntries returns empty when no packs installed")
    func gitignoreEntriesEmpty() {
        let entries = TechPackRegistry.shared.gitignoreEntries(installedPacks: [])
        #expect(entries.isEmpty)
    }

    @Test("gitignoreEntries returns iOS entries when iOS pack is installed")
    func gitignoreEntriesWithIOS() {
        let entries = TechPackRegistry.shared.gitignoreEntries(installedPacks: ["ios"])
        #expect(entries.contains(".xcodebuildmcp"))
    }

    @Test("migrations returns empty when no packs installed")
    func migrationsEmpty() {
        let migrations = TechPackRegistry.shared.migrations(installedPacks: [])
        #expect(migrations.isEmpty)
    }

    // MARK: - installedPacks from manifest

    @Test("installedPacks returns matching packs from manifest")
    func installedPacksFromManifest() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-registry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/test")
        manifest.recordInstalledPack("ios")
        try manifest.save()

        let reloaded = Manifest(path: manifestFile)
        let packs = TechPackRegistry.shared.installedPacks(from: reloaded)
        #expect(packs.count == 1)
        #expect(packs.first?.identifier == "ios")
    }

    @Test("installedPacks returns empty when manifest has no packs")
    func installedPacksEmptyManifest() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-registry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("manifest")
        var manifest = Manifest(path: manifestFile)
        manifest.initialize(sourceDirectory: "/test")
        try manifest.save()

        let reloaded = Manifest(path: manifestFile)
        let packs = TechPackRegistry.shared.installedPacks(from: reloaded)
        #expect(packs.isEmpty)
    }

    // MARK: - Template contributions

    @Test("templateContributions returns iOS templates")
    func templateContributions() {
        let templates = TechPackRegistry.shared.templateContributions(for: "ios")
        #expect(!templates.isEmpty)
        #expect(templates.first?.sectionIdentifier == "ios")
        #expect(templates.first?.placeholders.contains("__PROJECT__") == true)
    }

    @Test("templateContributions returns empty for unknown pack")
    func templateContributionsUnknown() {
        let templates = TechPackRegistry.shared.templateContributions(for: "android")
        #expect(templates.isEmpty)
    }

    // MARK: - External packs

    @Test("External packs appear in availablePacks")
    func externalPacksAppear() {
        let fakePack = FakeTechPack(identifier: "android")
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        let ids = registry.availablePacks.map(\.identifier)
        #expect(ids.contains("android"))
        #expect(ids.contains("core")) // compiled-in still present
        #expect(ids.contains("ios"))  // compiled-in still present
    }

    @Test("External pack overrides compiled-in with same identifier")
    func externalPackOverridesCompiledIn() {
        let overridePack = FakeTechPack(identifier: "ios")
        let registry = TechPackRegistry.withExternalPacks([overridePack])
        let ios = registry.pack(for: "ios")
        #expect(ios?.displayName == "Fake Pack") // not "iOS Development"
    }

    @Test("isExternalPack returns true for external packs")
    func isExternalPackDetection() {
        let fakePack = FakeTechPack(identifier: "android")
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        #expect(registry.isExternalPack("android") == true)
        #expect(registry.isExternalPack("ios") == false)
    }

    @Test("externalPackIdentifiers returns correct set")
    func externalPackIdentifiersSet() {
        let pack1 = FakeTechPack(identifier: "android")
        let pack2 = FakeTechPack(identifier: "web")
        let registry = TechPackRegistry.withExternalPacks([pack1, pack2])
        #expect(registry.externalPackIdentifiers == Set(["android", "web"]))
    }

    @Test("External pack components included in allPackComponents")
    func externalPackComponents() {
        let component = ComponentDefinition(
            id: "ext.comp",
            displayName: "Ext Comp",
            description: "An external component",
            type: .configuration,
            packIdentifier: "ext",
            dependencies: [],
            isRequired: false,
            installAction: .shellCommand(command: "echo")
        )
        let fakePack = FakeTechPack(
            identifier: "ext",
            components: [component]
        )
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        let allIDs = registry.allPackComponents.map(\.id)
        #expect(allIDs.contains("ext.comp"))
    }

    @Test("Existing methods work unchanged with empty external packs")
    func emptyExternalPacks() {
        let registry = TechPackRegistry.withExternalPacks([])
        let ids = registry.availablePacks.map(\.identifier)
        #expect(ids.contains("core"))
        #expect(ids.contains("ios"))
    }
}

// MARK: - Test Helper

private struct FakeTechPack: TechPack {
    let identifier: String
    let displayName: String = "Fake Pack"
    let description: String = "A fake pack for testing"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution] = []
    let hookContributions: [HookContribution] = []
    let gitignoreEntries: [String] = []
    let supplementaryDoctorChecks: [any DoctorCheck] = []
    let migrations: [any PackMigration] = []

    init(identifier: String, components: [ComponentDefinition] = []) {
        self.identifier = identifier
        self.components = components
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {}
}
