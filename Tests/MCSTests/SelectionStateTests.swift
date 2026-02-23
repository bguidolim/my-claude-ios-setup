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

    @Test("selectPack selects non-brew pack components")
    func selectPack() {
        var state = SelectionState()
        let pack = [
            component(id: "ios.mcp"),
            component(id: "ios.brew", type: .brewPackage),
            component(id: "ios.skill", type: .skill),
        ]
        state.selectPack("ios", packComponents: pack)

        #expect(state.isSelected("ios.mcp"))
        #expect(!state.isSelected("ios.brew"))
        #expect(state.isSelected("ios.skill"))
    }

    @Test("Default branch prefix is feature")
    func defaultBranchPrefix() {
        let state = SelectionState()
        #expect(state.branchPrefix == "feature")
    }
}
