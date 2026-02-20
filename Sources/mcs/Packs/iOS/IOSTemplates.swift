import Foundation

/// Template content contributed by the iOS tech pack.
enum IOSTemplates {
    /// iOS section for CLAUDE.local.md (inserted between mcs:begin/end ios markers).
    static let claudeLocalSection = """
        ## iOS Simulator
        - Always use the **booted simulator first**, referenced by **UUID** (not name)
        - If no simulator is booted, **ask the user** which one to use

        ## Build & Test (XcodeBuildMCP)

        All build, test, and run operations go through **XcodeBuildMCP**. When a task requires building, testing, running, debugging, or interacting with simulators, **invoke the `xcodebuildmcp` skill first** to load the tool catalog and workflow guidance.

        ### Rules
        - Before the first build/test in a session, call `session_show_defaults` to verify the active project, scheme, and simulator
        - **Never** run `xcrun` or `xcodebuild` directly via Bash — always use XcodeBuildMCP tools
        - **Never** build or test unless explicitly asked
        - Always use `__PROJECT__` with the appropriate scheme
        - **Never** suppress warnings — if any are related to the session, fix them
        - Prefer `snapshot_ui` over `screenshot` (screenshot only as fallback)
        """

    /// Generate .xcodebuildmcp/config.yaml content for a specific project file.
    static func xcodeBuildMCPConfig(projectFile: String) -> String {
        """
        schemaVersion: 1
        enabledWorkflows:
          - simulator
          - ui-automation
          - project-discovery
          - utilities
          - session-management
          - debugging
          - logging
          - doctor
          - workflow-discovery
        sessionDefaults:
          projectPath: ./\(projectFile)
          suppressWarnings: false
          platform: iOS
        """
    }
}
