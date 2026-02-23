# Creating Tech Packs

This guide walks through creating a new tech pack for `mcs`. Tech packs add platform-specific MCP servers, templates, hooks, doctor checks, and project configuration to the core setup.

## Overview

A tech pack is a Swift type conforming to the `TechPack` protocol. Packs are compiled into the `mcs` binary -- there is no plugin system or runtime discovery. To add a pack, you add Swift files to the repository, register the pack in the registry, and rebuild.

## Step 1: Create the Pack Directory

Create a new directory under `Sources/mcs/Packs/`:

```
Sources/mcs/Packs/YourPack/
    YourPackTechPack.swift       # TechPack conformance
    YourPackComponents.swift     # Component definitions
    YourPackDoctorChecks.swift   # Supplementary doctor checks
    YourPackConstants.swift      # String constants
    YourPackTemplates.swift      # CLAUDE.local.md section template
    YourPackHookFragments.swift  # Hook script fragments (optional)
```

## Step 2: Define Components

Components are the installable units of your pack. Each component has an install action and metadata.

```swift
import Foundation

enum YourPackComponents {
    static let someMCPServer = ComponentDefinition(
        id: "yourpack.some-server",            // Unique ID: "<pack>.<name>"
        displayName: "Some MCP Server",
        description: "What it does",
        type: .mcpServer,
        packIdentifier: "yourpack",            // Must match pack identifier
        dependencies: ["core.node"],           // IDs of required components
        isRequired: false,                     // true = always installed with pack
        installAction: .mcpServer(MCPServerConfig(
            name: "some-server",
            command: "npx",
            args: ["-y", "some-server@latest"],
            env: [:]
        ))
    )

    static let someSkill = ComponentDefinition(
        id: "yourpack.skill.something",
        displayName: "Something skill",
        description: "Skill description",
        type: .skill,
        packIdentifier: "yourpack",
        dependencies: ["yourpack.some-server"],
        isRequired: false,
        installAction: .shellCommand(
            command: "npx -y skills add some-org/some-skill -g -a claude-code -y"
        ),
        supplementaryChecks: [SomeSkillCheck()]  // Custom doctor check
    )

    static let gitignore = ComponentDefinition(
        id: "yourpack.gitignore",
        displayName: "YourPack gitignore entries",
        description: "Add .yourpack to global gitignore",
        type: .configuration,
        packIdentifier: "yourpack",
        dependencies: [],
        isRequired: true,
        installAction: .gitignoreEntries(entries: [".yourpack"])
    )

    static let all: [ComponentDefinition] = [
        someMCPServer,
        someSkill,
        gitignore,
    ]
}
```

### Install Action Types

| Action | Use Case |
|--------|----------|
| `.mcpServer(MCPServerConfig)` | Register an MCP server via `claude mcp add` |
| `.mcpServer(.http(name:url:))` | Register an HTTP transport MCP server |
| `.plugin(name:)` | Install a Claude Code plugin |
| `.copySkill(source:destination:)` | Copy a bundled skill directory from Resources |
| `.copyHook(source:destination:)` | Copy a bundled hook script from Resources |
| `.copyCommand(source:destination:placeholders:)` | Copy a command file with placeholder substitution |
| `.brewInstall(package:)` | Install a Homebrew package |
| `.shellCommand(command:)` | Run an arbitrary shell command |
| `.gitignoreEntries(entries:)` | Add patterns to the global gitignore |

### Dependency IDs

Core components you can depend on:
- `core.homebrew` -- Homebrew package manager
- `core.node` -- Node.js (for npx-based tools)
- `core.gh` -- GitHub CLI
- `core.jq` -- JSON processor
- `core.ollama` -- Ollama LLM runtime
- `core.uv` -- Python package runner

## Step 3: Create the Template

Templates contribute sections to `CLAUDE.local.md`. Define your template content:

```swift
enum YourPackTemplates {
    static let claudeLocalSection = """
    ## YourPack-Specific Instructions

    When working on this project, follow these guidelines:

    - Guideline 1
    - Guideline 2

    Project: __PROJECT__
    """
}
```

Placeholders use the `__NAME__` format and are substituted by the template engine during `mcs configure`. Common placeholders:
- `__PROJECT__` -- project directory name
- `__REPO_NAME__` -- git repository name

## Step 4: Add Hook Contributions (Optional)

If your pack needs to inject script fragments into existing hooks:

```swift
enum YourPackHookFragments {
    static let statusCheck = """
        # === YOUR PACK STATUS CHECK ===
        if some_command_exists; then
            context+="\\nYourPack: ready"
        fi
    """
}
```

Hook contributions are injected using section markers, making them idempotent and version-tracked.

## Step 5: Implement Supplementary Doctor Checks

Doctor checks that cannot be auto-derived from component install actions go here. Auto-derived checks handle the common cases:
- `.mcpServer` -> checks registration in `~/.claude.json`
- `.plugin` -> checks enablement in `settings.json`
- `.brewInstall` -> checks command availability
- `.copyHook` -> checks file existence and executability
- `.copySkill` -> checks directory existence
- `.copyCommand` -> checks file existence

Supplementary checks cover everything else:

```swift
struct YourToolCheck: DoctorCheck, Sendable {
    let section = "YourPack"          // Grouping header in doctor output
    let name = "your tool name"

    func check() -> CheckResult {
        // Return .pass, .fail, .warn, or .skip
        if toolIsConfigured() {
            return .pass("configured correctly")
        }
        return .fail("not configured -- run 'mcs configure --pack yourpack'")
    }

    func fix() -> FixResult {
        // Return .fixed, .failed, or .notFixable
        // Remember: doctor --fix only does cleanup/migration/trivial repairs
        // Additive operations should return .notFixable with install guidance
        return .notFixable("Run 'mcs install' to configure")
    }
}
```

## Step 6: Implement the TechPack Protocol

```swift
import Foundation

struct YourPackTechPack: TechPack {
    let identifier = "yourpack"
    let displayName = "Your Pack"
    let description = "Description of what this pack provides"

    let components: [ComponentDefinition] = YourPackComponents.all

    let templates: [TemplateContribution] = [
        TemplateContribution(
            sectionIdentifier: "yourpack",
            templateContent: YourPackTemplates.claudeLocalSection,
            placeholders: ["__PROJECT__"]
        ),
    ]

    let hookContributions: [HookContribution] = [
        HookContribution(
            hookName: "session_start",
            scriptFragment: YourPackHookFragments.statusCheck,
            position: .after          // .before or .after core content
        ),
    ]

    let gitignoreEntries: [String] = [".yourpack"]

    var supplementaryDoctorChecks: [any DoctorCheck] {
        [YourToolCheck()]
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {
        // Create pack-specific project files
        let configDir = path.appendingPathComponent(".yourpack")
        let configFile = configDir.appendingPathComponent("config.yaml")

        let content = "project: \(context.repoName)\n"

        try FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true
        )
        try content.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
```

## Step 7: Register the Pack

Add your pack to the registry in `Sources/mcs/TechPack/TechPackRegistry.swift`:

```swift
struct TechPackRegistry: Sendable {
    static let shared = TechPackRegistry(packs: [
        CoreTechPack(),
        IOSTechPack(),
        YourPackTechPack(),  // Add here
    ])
    // ...
}
```

## Step 8: Add Bundled Resources (If Needed)

If your pack includes bundled files (templates, configs), add them to `Sources/mcs/Resources/templates/packs/yourpack/`.

Resources are included in the binary via the `.copy("Resources")` directive in `Package.swift`.

## Step 9: Add Tests

Create tests in `Tests/MCSTests/` that verify:
- Component definitions have valid IDs and dependencies
- Doctor checks return expected results
- Templates contain required placeholders
- `configureProject` creates expected files

## Step 10: Build and Verify

```bash
swift build                          # Verify compilation
swift test                           # Run tests
mcs install --pack yourpack          # Test installation
mcs doctor --pack yourpack           # Test diagnostics
mcs configure --pack yourpack        # Test project configuration
```

## Design Guidelines

### Component IDs
Use the format `<pack>.<name>` or `<pack>.<type>.<name>`:
- `yourpack.some-server`
- `yourpack.skill.something`

### Doctor Check Sections
Use your pack name as the section header for supplementary checks. Auto-derived checks use the component type (MCP Servers, Plugins, etc.).

### fix() Boundaries
Doctor `--fix` should only handle:
- Cleanup of deprecated items
- One-time data migrations
- Permission fixes

Additive operations (installing, registering, copying) should return `.notFixable("Run 'mcs install' to ...")`.

### Sendable Conformance
All types must conform to `Sendable` (Swift 6 strict concurrency). Use `struct` for checks and pack types. Avoid mutable shared state.

### Idempotency
Install actions should be safe to re-run. The installer checks `isAlreadyInstalled()` using auto-derived and supplementary doctor checks before executing install actions. Components that pass any check are skipped.

## Reference: iOS Pack

The iOS tech pack (`Sources/mcs/Packs/iOS/`) is the reference implementation:

- `IOSTechPack.swift` -- protocol conformance, Xcode project auto-detection
- `IOSComponents.swift` -- XcodeBuildMCP, Sosumi, skill, gitignore
- `IOSDoctorChecks.swift` -- Xcode CLT, config.yaml, CLAUDE.local.md section
- `IOSConstants.swift` -- string constants
- `IOSTemplates.swift` -- CLAUDE.local.md section, XcodeBuildMCP config
- `IOSHookFragments.swift` -- simulator check for session_start hook
