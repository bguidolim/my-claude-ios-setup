import Foundation

/// Errors thrown by the mcs tool
enum MCSError: Error, LocalizedError {
    case invalidConfiguration(String)
    case installationFailed(component: String, reason: String)
    case fileOperationFailed(path: String, reason: String)
    case dependencyMissing(String)
    case templateError(String)
    case configurationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .installationFailed(let component, let reason):
            return "Failed to install \(component): \(reason)"
        case .fileOperationFailed(let path, let reason):
            return "File operation failed at \(path): \(reason)"
        case .dependencyMissing(let name):
            return "Missing dependency: \(name)"
        case .templateError(let message):
            return "Template error: \(message)"
        case .configurationFailed(let reason):
            return "Configuration failed: \(reason)"
        }
    }
}
