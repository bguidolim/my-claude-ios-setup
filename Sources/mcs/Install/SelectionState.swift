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

    /// Select all core components (excludes pack components).
    /// Pack components must be selected explicitly via selectPack.
    mutating func selectAllCore(from components: [ComponentDefinition]) {
        for component in components {
            // Skip dependency-only components — they get auto-resolved
            // Skip pack components — they require explicit pack selection
            if component.type != .brewPackage && component.packIdentifier == nil {
                selectedIDs.insert(component.id)
            }
        }
    }

    /// Select components from a specific pack plus required core deps.
    mutating func selectPack(
        _ packIdentifier: String,
        coreComponents: [ComponentDefinition],
        packComponents: [ComponentDefinition]
    ) {
        // Select all pack components
        for component in packComponents {
            if component.type != .brewPackage {
                selectedIDs.insert(component.id)
            }
        }
        // Select required core components
        for component in coreComponents where component.isRequired {
            selectedIDs.insert(component.id)
        }
    }

    /// Select required core components.
    mutating func selectRequiredCore(from components: [ComponentDefinition]) {
        for component in components where component.isRequired {
            selectedIDs.insert(component.id)
        }
    }
}
