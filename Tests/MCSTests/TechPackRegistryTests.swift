import Foundation
import Testing

@testable import mcs

@Suite("TechPackRegistry")
struct TechPackRegistryTests {
    // MARK: - Basic registry

    @Test("Shared registry has no compiled-in packs")
    func sharedIsEmpty() {
        let packs = TechPackRegistry.shared.availablePacks
        #expect(packs.isEmpty)
    }

    @Test("Find pack by identifier returns nil for unknown")
    func findByIdentifierUnknown() {
        let result = TechPackRegistry.shared.pack(for: "nonexistent")
        #expect(result == nil)
    }

    // MARK: - Filtered by installed packs

    @Test("supplementaryDoctorChecks returns empty when no packs installed")
    func supplementaryDoctorChecksEmpty() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: [])
        #expect(checks.isEmpty)
    }

    @Test("supplementaryDoctorChecks ignores unrecognized pack identifiers")
    func supplementaryDoctorChecksUnknownPack() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: ["nonexistent"])
        #expect(checks.isEmpty)
    }

    @Test("gitignoreEntries returns empty when no packs installed")
    func gitignoreEntriesEmpty() {
        let entries = TechPackRegistry.shared.gitignoreEntries(installedPacks: [])
        #expect(entries.isEmpty)
    }

    // MARK: - Template contributions

    @Test("templateContributions returns templates for registered pack")
    func templateContributions() {
        let template = TemplateContribution(
            sectionIdentifier: "test",
            templateContent: "Test content __NAME__",
            placeholders: ["__NAME__"]
        )
        let fakePack = FakeTechPack(identifier: "test-pack", templates: [template])
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        let templates = registry.templateContributions(for: "test-pack")
        #expect(!templates.isEmpty)
        #expect(templates.first?.sectionIdentifier == "test")
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
    }

    @Test("Find external pack by identifier")
    func findExternalByIdentifier() {
        let fakePack = FakeTechPack(identifier: "android")
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        let found = registry.pack(for: "android")
        #expect(found != nil)
        #expect(found?.displayName == "Fake Pack")
    }

    @Test("isExternalPack returns true for external packs")
    func isExternalPackDetection() {
        let fakePack = FakeTechPack(identifier: "android")
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        #expect(registry.isExternalPack("android") == true)
        #expect(registry.isExternalPack("nonexistent") == false)
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

    @Test("Registry with empty external packs has no available packs")
    func emptyExternalPacks() {
        let registry = TechPackRegistry.withExternalPacks([])
        #expect(registry.availablePacks.isEmpty)
    }

    @Test("supplementaryDoctorChecks returns checks for registered external pack")
    func supplementaryDoctorChecksWithExternalPack() {
        let check = CommandCheck(name: "test-check", section: "Dependencies", command: "test")
        let fakePack = FakeTechPack(
            identifier: "test-pack",
            supplementaryDoctorChecks: [check]
        )
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        let checks = registry.supplementaryDoctorChecks(installedPacks: ["test-pack"])
        #expect(!checks.isEmpty)
        #expect(checks.first?.name == "test-check")
    }

    @Test("gitignoreEntries returns entries for registered external pack")
    func gitignoreEntriesWithExternalPack() {
        let fakePack = FakeTechPack(
            identifier: "test-pack",
            gitignoreEntries: [".testdir"]
        )
        let registry = TechPackRegistry.withExternalPacks([fakePack])
        let entries = registry.gitignoreEntries(installedPacks: ["test-pack"])
        #expect(entries.contains(".testdir"))
    }
}

// MARK: - Test Helper

private struct FakeTechPack: TechPack {
    let identifier: String
    let displayName: String = "Fake Pack"
    let description: String = "A fake pack for testing"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    let hookContributions: [HookContribution]
    let gitignoreEntries: [String]
    let supplementaryDoctorChecks: [any DoctorCheck]

    init(
        identifier: String,
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = [],
        hookContributions: [HookContribution] = [],
        gitignoreEntries: [String] = [],
        supplementaryDoctorChecks: [any DoctorCheck] = []
    ) {
        self.identifier = identifier
        self.components = components
        self.templates = templates
        self.hookContributions = hookContributions
        self.gitignoreEntries = gitignoreEntries
        self.supplementaryDoctorChecks = supplementaryDoctorChecks
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {}
}
