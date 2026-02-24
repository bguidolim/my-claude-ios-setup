import Foundation

// MARK: - Deriving doctor checks from ComponentDefinition

extension ComponentDefinition {
    /// Auto-generates doctor check(s) from installAction.
    /// Returns nil for actions that have no mechanical verification
    /// (e.g. .shellCommand, .settingsMerge, .gitignoreEntries).
    func deriveDoctorCheck() -> (any DoctorCheck)? {
        switch installAction {
        case .mcpServer(let config):
            return MCPServerCheck(name: displayName, serverName: config.name)

        case .plugin(let pluginName):
            return PluginCheck(pluginRef: PluginRef(pluginName))

        case .brewInstall(let package):
            return CommandCheck(
                name: displayName,
                section: type.doctorSection,
                command: package,
                isOptional: !isRequired
            )

        case .copyPackFile(_, let destination, let fileType):
            let destURL = fileType.destinationURL(in: Environment(), destination: destination)
            return FileExistsCheck(
                name: displayName,
                section: type.doctorSection,
                path: destURL
            )

        case .shellCommand, .settingsMerge, .gitignoreEntries:
            return nil
        }
    }

    /// All doctor checks for this component: auto-derived + supplementary.
    func allDoctorChecks() -> [any DoctorCheck] {
        var checks: [any DoctorCheck] = []
        if let derived = deriveDoctorCheck() {
            checks.append(derived)
        }
        checks.append(contentsOf: supplementaryChecks)
        return checks
    }
}
