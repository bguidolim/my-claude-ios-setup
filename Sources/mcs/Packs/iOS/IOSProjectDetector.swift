import Foundation

/// Detects iOS/macOS projects by looking for Xcode project files.
enum IOSProjectDetector {
    /// Detect an iOS project at the given path.
    ///
    /// Searches for `.xcworkspace` and `.xcodeproj` files at the root level
    /// (depth 1). Workspaces are preferred over standalone projects since they
    /// typically wrap a project with CocoaPods or SPM integration.
    ///
    /// Files inside `.xcodeproj` bundles (e.g. `project.xcworkspace`) are
    /// excluded.
    static func detect(at path: URL) -> ProjectDetectionResult? {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Look for .xcworkspace first (higher confidence)
        let workspaces = contents.filter { url in
            url.pathExtension == "xcworkspace"
                && !url.path.contains(".xcodeproj/")
        }

        if let workspace = workspaces.first {
            let name = workspace.deletingPathExtension().lastPathComponent
            return ProjectDetectionResult(
                packIdentifier: "ios",
                projectName: name,
                projectFile: workspace,
                confidence: 0.9
            )
        }

        // Fall back to .xcodeproj
        let projects = contents.filter { url in
            url.pathExtension == "xcodeproj"
        }

        if let project = projects.first {
            let name = project.deletingPathExtension().lastPathComponent
            return ProjectDetectionResult(
                packIdentifier: "ios",
                projectName: name,
                projectFile: project,
                confidence: 0.8
            )
        }

        return nil
    }
}
