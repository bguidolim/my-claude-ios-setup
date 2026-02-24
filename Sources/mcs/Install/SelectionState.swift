import Foundation

/// Tracks which components the user has selected for installation.
struct SelectionState {
    /// Component IDs that have been selected.
    private(set) var selectedIDs: Set<String> = []

    /// Branch prefix for PR command placeholder substitution.
    var branchPrefix: String = "feature"

    // MARK: - Mutation

    mutating func select(_ id: String) {
        selectedIDs.insert(id)
    }

    mutating func deselect(_ id: String) {
        selectedIDs.remove(id)
    }

    func isSelected(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    // MARK: - Bulk Selection

    /// Select all non-brew components from a pack.
    mutating func selectPack(
        _ packIdentifier: String,
        packComponents: [ComponentDefinition]
    ) {
        for component in packComponents {
            if component.type != .brewPackage {
                selectedIDs.insert(component.id)
            }
        }
    }
}
