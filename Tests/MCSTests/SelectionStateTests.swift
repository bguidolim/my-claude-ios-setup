import Foundation
import Testing

@testable import mcs

@Suite("SelectionState")
struct SelectionStateTests {
    private func component(
        id: String,
        type: ComponentType = .plugin,
        packIdentifier: String? = nil,
        isRequired: Bool = false
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: id,
            displayName: id,
            description: "Test",
            type: type,
            packIdentifier: packIdentifier,
            dependencies: [],
            isRequired: isRequired,
            installAction: .shellCommand(command: "echo")
        )
    }

    @Test("Select and deselect tracks correctly")
    func selectDeselect() {
        var state = SelectionState()
        state.select("a")
        state.select("b")
        #expect(state.isSelected("a"))
        #expect(state.isSelected("b"))
        #expect(!state.isSelected("c"))

        state.deselect("a")
        #expect(!state.isSelected("a"))
        #expect(state.isSelected("b"))
    }

    @Test("selectAllCore skips brewPackage and pack components")
    func selectAllCoreSkipsBrewAndPacks() {
        var state = SelectionState()
        let components = [
            component(id: "plugin.a", type: .plugin),
            component(id: "brew.b", type: .brewPackage),
            component(id: "hook.c", type: .hookFile),
            component(id: "ios.mcp", type: .mcpServer, packIdentifier: "ios"),
            component(id: "ios.skill", type: .skill, packIdentifier: "ios"),
        ]
        state.selectAllCore(from: components)

        #expect(state.isSelected("plugin.a"))
        #expect(!state.isSelected("brew.b"))
        #expect(state.isSelected("hook.c"))
        #expect(!state.isSelected("ios.mcp"))
        #expect(!state.isSelected("ios.skill"))
    }

    @Test("selectPack selects pack components and required core")
    func selectPack() {
        var state = SelectionState()
        let core = [
            component(id: "core.required", isRequired: true),
            component(id: "core.optional", isRequired: false),
        ]
        let pack = [
            component(id: "ios.mcp"),
            component(id: "ios.brew", type: .brewPackage),
        ]
        state.selectPack("ios", coreComponents: core, packComponents: pack)

        #expect(state.isSelected("core.required"))
        #expect(!state.isSelected("core.optional"))
        #expect(state.isSelected("ios.mcp"))
        #expect(!state.isSelected("ios.brew"))
    }

    @Test("selectRequiredCore only selects required components")
    func selectRequiredCore() {
        var state = SelectionState()
        let core = [
            component(id: "core.req", isRequired: true),
            component(id: "core.opt", isRequired: false),
        ]
        state.selectRequiredCore(from: core)

        #expect(state.isSelected("core.req"))
        #expect(!state.isSelected("core.opt"))
    }

    @Test("Default branch prefix is feature")
    func defaultBranchPrefix() {
        let state = SelectionState()
        #expect(state.branchPrefix == "feature")
    }
}
