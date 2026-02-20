import Foundation

/// Orchestrates the 5-phase install flow:
/// welcome -> selection -> summary -> install -> post-summary.
struct Installer {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var backup: Backup
    let dryRun: Bool

    private var installedItems: [String] = []
    private var skippedItems: [String] = []

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        backup: Backup = Backup(),
        dryRun: Bool
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.backup = backup
        self.dryRun = dryRun
    }

    // MARK: - Phase 1: Welcome

    mutating func phaseWelcome() throws {
        output.header("My Claude Setup")
        output.plain("")
        output.plain("  Configure Claude Code with MCP servers, plugins,")
        output.plain("  skills, and hooks for development.")
        output.plain("")

        // System checks
        #if !os(macOS)
        output.error("This tool requires macOS.")
        throw MCSError.invalidConfiguration("Unsupported platform")
        #endif

        if ProcessInfo.processInfo.environment["USER"] == "root" || getuid() == 0 {
            output.error("Do not run this tool as root.")
            throw MCSError.invalidConfiguration("Running as root")
        }

        output.info("Detected macOS on \(environment.architecture.rawValue)")

        // Check Xcode CLT
        let xcodeResult = shell.run("/usr/bin/xcode-select", arguments: ["-p"], quiet: true)
        if xcodeResult.succeeded {
            output.info("Xcode Command Line Tools: installed")
        } else {
            output.warn("Xcode Command Line Tools not found.")
            output.plain("  Install them with: xcode-select --install")
            output.plain("  Then re-run this tool.")
            throw MCSError.dependencyMissing("Xcode Command Line Tools")
        }

        // Check Homebrew (required for dependency installation)
        let brew = Homebrew(shell: shell, environment: environment)
        if brew.isInstalled {
            output.info("Homebrew: installed")
        } else {
            output.warn("Homebrew is required but not installed.")
            output.plain("")
            output.plain("  Install it with:")
            output.plain("    /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
            output.plain("")
            output.plain("  Then re-run: mcs install")
            throw MCSError.dependencyMissing("Homebrew")
        }

        // Migrate old manifest file name if present
        if environment.migrateManifestIfNeeded() {
            output.dimmed("Migrated .setup-manifest → .mcs-manifest")
        }

        output.plain("")
        output.info("Required dependencies are auto-resolved based on your choices.")
    }

    // MARK: - Phase 2: Selection

    mutating func phaseSelection(
        installAll: Bool,
        packName: String?
    ) -> SelectionState {
        var state = SelectionState()

        let coreComponents = CoreComponents.all
        let registry = TechPackRegistry.shared
        let allPacks = registry.availablePacks
        let allComponents = registry.allComponents(includingCore: coreComponents)

        if installAll {
            state.selectAll(from: allComponents)
            // Also select all pack components
            for pack in allPacks {
                for component in pack.components where component.type != .brewPackage {
                    state.select(component.id)
                }
            }
            askBranchPrefix(&state)
            return state
        }

        if let packName {
            if let pack = registry.pack(for: packName) {
                state.selectPack(
                    packName,
                    coreComponents: coreComponents,
                    packComponents: pack.components
                )
                output.info("Selected tech pack: \(pack.displayName)")
            } else {
                output.warn("Unknown tech pack: \(packName)")
                output.plain("  Available packs: \(allPacks.map(\.identifier).joined(separator: ", "))")
            }
            askBranchPrefix(&state)
            return state
        }

        // Interactive selection
        output.plain("")
        if output.askYesNo("Install everything? (skip individual prompts)", default: false) {
            state.selectAll(from: allComponents)
            for pack in allPacks {
                for component in pack.components where component.type != .brewPackage {
                    state.select(component.id)
                }
            }
            askBranchPrefix(&state)
            return state
        }

        // Select required core components
        state.selectRequiredCore(from: coreComponents)

        // Interactive category selection
        interactiveSelectByCategory(&state, coreComponents: coreComponents)

        // Available tech packs
        if !allPacks.isEmpty {
            output.header("Tech Packs")
            output.dimmed("Tech packs add platform-specific components.")
            output.plain("")

            for pack in allPacks {
                output.plain("  \(pack.displayName)")
                output.dimmed("  \(pack.description)")
                if output.askYesNo("Install \(pack.displayName) pack?") {
                    state.selectPack(
                        pack.identifier,
                        coreComponents: coreComponents,
                        packComponents: pack.components
                    )
                }
                output.plain("")
            }
        }

        askBranchPrefix(&state)
        return state
    }

    // MARK: - Phase 3: Summary

    func phaseSummary(
        plan: DependencyResolver.ResolvedPlan,
        state: SelectionState
    ) -> Bool {
        output.header("Installation Summary")

        let grouped = Dictionary(grouping: plan.orderedComponents) { $0.type }
        let displayOrder: [ComponentType] = [
            .brewPackage, .mcpServer, .plugin, .skill, .command, .hookFile, .configuration,
        ]

        var hasContent = false
        for type in displayOrder {
            guard let components = grouped[type], !components.isEmpty else { continue }
            hasContent = true
            output.plain("")
            output.plain("  \(type.rawValue)s:")
            for component in components {
                let autoAdded = plan.addedDependencies.contains(where: { $0.id == component.id })
                let suffix = autoAdded ? " (auto-resolved)" : ""
                output.plain("    + \(component.displayName)\(suffix)")
            }
        }

        if !hasContent {
            output.warn("Nothing selected to install.")
            return false
        }

        output.plain("")

        if dryRun {
            output.info("Dry run mode -- no changes will be made.")
            return false
        }

        return output.askYesNo("Proceed with installation?")
    }

    // MARK: - Phase 4: Install

    mutating func phaseInstall(plan: DependencyResolver.ResolvedPlan, state: SelectionState) {
        let components = plan.orderedComponents
        let total = components.count

        output.header("Installing...")

        // Initialize manifest
        var manifest = Manifest(path: environment.setupManifest)
        manifest.initialize(sourceDirectory: Bundle.module.bundlePath)

        // Ensure directories exist
        let fm = FileManager.default
        let dirs = [
            environment.claudeDirectory,
            environment.hooksDirectory,
            environment.skillsDirectory,
            environment.commandsDirectory,
        ]
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for (index, component) in components.enumerated() {
            let step = index + 1
            output.step(step, of: total, component.displayName)

            // Check if already installed
            if isAlreadyInstalled(component) {
                skippedItems.append("\(component.displayName) (already installed)")
                output.dimmed("Already installed, skipping")
                continue
            }

            let success = installComponent(
                component,
                state: state,
                manifest: &manifest
            )
            if success {
                installedItems.append(component.displayName)
                output.success("\(component.displayName) installed")
            } else {
                skippedItems.append("\(component.displayName) (failed)")
                output.warn("Failed to install \(component.displayName)")
            }
        }

        // Record which packs were installed
        let installedPackIDs = Set(
            plan.orderedComponents.compactMap(\.packIdentifier)
        )
        for packID in installedPackIDs {
            manifest.recordInstalledPack(packID)
        }

        // Save manifest
        try? manifest.save()

        // Post-processing: inject pack hook contributions into installed hooks
        for packID in installedPackIDs {
            if let pack = TechPackRegistry.shared.pack(for: packID) {
                injectHookContributions(from: pack)
            }
        }

        // Post-processing: add pack gitignore entries
        for packID in installedPackIDs {
            if let pack = TechPackRegistry.shared.pack(for: packID) {
                addPackGitignoreEntries(from: pack)
            }
        }
    }

    // MARK: - Phase 5: Post-Summary

    func phaseSummaryPost() {
        output.header("Setup Complete!")

        if !installedItems.isEmpty {
            output.plain("")
            output.plain("  Installed:")
            for item in installedItems {
                output.plain("    + \(item)")
            }
        }

        if !skippedItems.isEmpty {
            output.plain("")
            output.plain("  Skipped:")
            for item in skippedItems {
                output.dimmed("  o \(item)")
            }
        }

        output.plain("")
        output.plain("  Next Steps:")
        output.plain("")
        output.plain("    1. Restart your terminal to pick up PATH changes")
        output.plain("")
        output.plain("    2. Configure CLAUDE.local.md for your project(s):")
        output.plain("       cd /path/to/project && mcs configure --pack ios")
        output.dimmed("       Generates a CLAUDE.local.md with project-specific instructions.")
        output.plain("")
        output.plain("    3. Verify your setup:")
        output.plain("       mcs doctor")
        output.plain("")
    }

    // MARK: - Component Installation

    private mutating func installComponent(
        _ component: ComponentDefinition,
        state: SelectionState,
        manifest: inout Manifest
    ) -> Bool {
        switch component.installAction {
        case .brewInstall(let package):
            let success = installBrewPackage(package)
            if success {
                postInstall(component)
            }
            return success

        case .shellCommand(let command):
            let result = shell.shell(command)
            if !result.succeeded {
                output.dimmed(String(result.stderr.prefix(200)))
            }
            return result.succeeded

        case .mcpServer(let config):
            return installMCPServer(config)

        case .plugin(let name):
            return installPlugin(name)

        case .copySkill(let source, let destination):
            return copySkill(source: source, destination: destination, manifest: &manifest)

        case .copyHook(let source, let destination):
            return copyHook(source: source, destination: destination, manifest: &manifest)

        case .copyCommand(let source, let destination, var placeholders):
            placeholders["BRANCH_PREFIX"] = state.branchPrefix
            return copyCommand(
                source: source,
                destination: destination,
                placeholders: placeholders,
                manifest: &manifest
            )

        case .settingsMerge:
            return mergeSettings()

        case .gitignoreEntries(let entries):
            return addGitignoreEntries(entries)
        }
    }

    private func installBrewPackage(_ package: String) -> Bool {
        let brew = Homebrew(shell: shell, environment: environment)
        guard brew.isInstalled else {
            output.warn("Homebrew not found, cannot install \(package)")
            return false
        }
        if brew.isPackageInstalled(package) {
            return true
        }
        let result = brew.install(package)
        if !result.succeeded {
            output.dimmed(String(result.stderr.prefix(200)))
        }
        return result.succeeded
    }

    private func installMCPServer(_ config: MCPServerConfig) -> Bool {
        guard shell.commandExists("claude") else {
            output.warn("Claude Code CLI not found, skipping MCP server")
            return false
        }
        let claude = ClaudeIntegration(shell: shell)

        // Build arguments
        var args: [String] = []
        for (key, value) in config.env.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if config.command == "http" {
            args.append(contentsOf: ["--transport", "http"])
            args.append(contentsOf: config.args)
        } else {
            args.append("--")
            args.append(config.command)
            args.append(contentsOf: config.args)
        }

        let result = claude.mcpAdd(name: config.name, arguments: args)
        return result.succeeded
    }

    private func installPlugin(_ fullName: String) -> Bool {
        guard shell.commandExists("claude") else {
            output.warn("Claude Code CLI not found, skipping plugin")
            return false
        }
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.pluginInstall(fullName: fullName)
        return result.succeeded
    }

    private mutating func copySkill(
        source: String,
        destination: String,
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let resourceURL = Bundle.module.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL.appendingPathComponent(source)
        let destURL = environment.skillsDirectory.appendingPathComponent(destination)

        do {
            try? fm.createDirectory(
                at: destURL,
                withIntermediateDirectories: true
            )
            // Copy all files in the skill directory
            if fm.fileExists(atPath: sourceURL.path) {
                let contents = try fm.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: nil
                )
                for file in contents {
                    let destFile = destURL.appendingPathComponent(file.lastPathComponent)
                    _ = try? backup.backupFile(at: destFile)
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try fm.copyItem(at: file, to: destFile)

                    // Recurse into subdirectories
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
                        let subContents = try fm.contentsOfDirectory(
                            at: file,
                            includingPropertiesForKeys: nil
                        )
                        for subFile in subContents {
                            let subDest = destFile.appendingPathComponent(subFile.lastPathComponent)
                            if fm.fileExists(atPath: subDest.path) {
                                try fm.removeItem(at: subDest)
                            }
                            try fm.copyItem(at: subFile, to: subDest)
                        }
                    }
                }
                try? manifest.record(
                    relativePath: source,
                    sourceFile: sourceURL
                )
            }
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    private mutating func copyHook(
        source: String,
        destination: String,
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let resourceURL = Bundle.module.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL.appendingPathComponent(source)
        let destURL = environment.hooksDirectory.appendingPathComponent(destination)

        do {
            try? fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try? backup.backupFile(at: destURL)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)

            // Make executable
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destURL.path
            )

            try? manifest.record(relativePath: source, sourceFile: sourceURL)
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    private mutating func copyCommand(
        source: String,
        destination: String,
        placeholders: [String: String],
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let resourceURL = Bundle.module.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL.appendingPathComponent(source)
        let destURL = environment.commandsDirectory.appendingPathComponent(destination)

        do {
            try? fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var content = try String(contentsOf: sourceURL, encoding: .utf8)
            content = TemplateEngine.substitute(template: content, values: placeholders)

            _ = try? backup.backupFile(at: destURL)
            try content.write(to: destURL, atomically: true, encoding: .utf8)
            try? manifest.record(relativePath: source, sourceFile: sourceURL)
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    private mutating func mergeSettings() -> Bool {
        guard let resourceURL = Bundle.module.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL
            .appendingPathComponent("config")
            .appendingPathComponent("settings.json")
        let destURL = environment.claudeSettings

        do {
            let template = try Settings.load(from: sourceURL)
            var existing = try Settings.load(from: destURL)

            _ = try? backup.backupFile(at: destURL)

            // Bootstrap ownership from legacy bash manifest if no sidecar exists yet
            var ownership = SettingsOwnership(path: environment.settingsKeys)
            if ownership.managedKeys.isEmpty {
                if ownership.bootstrapFromLegacyManifest(at: environment.setupManifest) {
                    output.dimmed("Migrated ownership from legacy bash installer manifest")
                }
            }

            // Remove stale keys that mcs previously owned but are no longer in the template
            let stale = ownership.staleKeys(comparedTo: template)
            if !stale.isEmpty {
                existing.removeKeys(stale)
                for key in stale {
                    ownership.remove(keyPath: key)
                }
                output.dimmed("Removed \(stale.count) stale setting(s): \(stale.joined(separator: ", "))")
            }

            existing.merge(with: template)
            try existing.save(to: destURL)

            // Record ownership of all template keys
            ownership.recordAll(from: template, version: MCSVersion.current)
            try? ownership.save()

            return true
        } catch {
            // Fallback: just copy the template settings
            let fm = FileManager.default
            do {
                try? fm.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: sourceURL.path) {
                    _ = try? backup.backupFile(at: destURL)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }

                // Record ownership even in fallback
                if let template = try? Settings.load(from: sourceURL) {
                    var ownership = SettingsOwnership(path: environment.settingsKeys)
                    ownership.recordAll(from: template, version: MCSVersion.current)
                    try? ownership.save()
                }

                return true
            } catch {
                output.dimmed(error.localizedDescription)
                return false
            }
        }
    }

    /// Run post-install steps for specific components (e.g., start services, pull models).
    private func postInstall(_ component: ComponentDefinition) {
        switch component.id {
        case "core.ollama":
            let brew = Homebrew(shell: shell, environment: environment)
            // Start Ollama service
            output.dimmed("Starting Ollama service...")
            brew.startService("ollama")
            // Wait briefly for service to be ready
            for _ in 0..<10 {
                let r = shell.shell("curl -s --max-time 2 http://localhost:11434/api/tags")
                if r.succeeded { break }
                Thread.sleep(forTimeInterval: 1)
            }
            // Pull the embedding model
            output.dimmed("Pulling nomic-embed-text model...")
            let modelResult = shell.run("/usr/bin/env", arguments: ["ollama", "list"], quiet: true)
            if !modelResult.stdout.contains("nomic-embed-text") {
                shell.run("/usr/bin/env", arguments: ["ollama", "pull", "nomic-embed-text"])
            }
        default:
            break
        }
    }

    private func addGitignoreEntries(_ entries: [String]) -> Bool {
        let manager = GitignoreManager(shell: shell)
        do {
            for entry in entries {
                try manager.addEntry(entry)
            }
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Pack Post-Processing

    /// Inject a pack's hook contributions into installed hook files using section markers.
    private mutating func injectHookContributions(from pack: any TechPack) {
        let fm = FileManager.default

        for contribution in pack.hookContributions {
            let hookFile = environment.hooksDirectory
                .appendingPathComponent(contribution.hookName + ".sh")

            guard fm.fileExists(atPath: hookFile.path),
                  var content = try? String(contentsOf: hookFile, encoding: .utf8)
            else { continue }

            let version = MCSVersion.current
            let beginMarker = "# --- mcs:begin \(pack.identifier) v\(version) ---"
            let endMarker = "# --- mcs:end \(pack.identifier) ---"

            // Remove existing section for idempotency (matches both versioned and unversioned markers)
            if let beginRange = content.range(
                of: #"# --- mcs:begin \#(pack.identifier)( v[0-9]+\.[0-9]+\.[0-9]+)? ---"#,
                options: .regularExpression
            ),
               let endRange = content.range(of: endMarker) {
                // Include trailing newline if present
                var removeEnd = endRange.upperBound
                if removeEnd < content.endIndex && content[removeEnd] == "\n" {
                    removeEnd = content.index(after: removeEnd)
                }
                // Include leading newline if present
                var removeStart = beginRange.lowerBound
                if removeStart > content.startIndex {
                    let before = content.index(before: removeStart)
                    if content[before] == "\n" {
                        removeStart = before
                    }
                }
                content.removeSubrange(removeStart..<removeEnd)
            }

            // Build the marked section
            let section = "\(beginMarker)\n\(contribution.scriptFragment)\n\(endMarker)"

            // Insert at the specified position
            switch contribution.position {
            case .after:
                if !content.hasSuffix("\n") { content += "\n" }
                content += "\n\(section)\n"
            case .before:
                // Insert after the shebang and trap/setup lines (after first blank line)
                if let blankRange = content.range(of: "\n\n") {
                    let insertPoint = content.index(after: blankRange.lowerBound)
                    content.insert(contentsOf: "\n\(section)\n", at: insertPoint)
                } else if let firstNewline = content.firstIndex(of: "\n") {
                    content.insert(
                        contentsOf: "\n\(section)\n",
                        at: content.index(after: firstNewline)
                    )
                } else {
                    content = "\(section)\n\(content)"
                }
            }

            _ = try? backup.backupFile(at: hookFile)
            try? content.write(to: hookFile, atomically: true, encoding: .utf8)
            output.success("Injected \(pack.displayName) hook fragment into \(contribution.hookName)")
        }
    }

    /// Add a pack's gitignore entries to the global gitignore.
    private func addPackGitignoreEntries(from pack: any TechPack) {
        guard !pack.gitignoreEntries.isEmpty else { return }
        let manager = GitignoreManager(shell: shell)
        for entry in pack.gitignoreEntries {
            do {
                try manager.addEntry(entry)
            } catch {
                output.warn("Failed to add gitignore entry '\(entry)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Already-installed detection

    /// Check if a component is already installed.
    /// Uses the same detection logic as the doctor checks to stay consistent.
    private func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        let fm = FileManager.default

        switch component.installAction {
        case .brewInstall(let package):
            return Homebrew(shell: shell, environment: environment).isPackageInstalled(package)

        case .mcpServer(let config):
            // Same check as MCPServerCheck in doctor
            guard fm.fileExists(atPath: environment.claudeJSON.path),
                  let data = try? Data(contentsOf: environment.claudeJSON),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any]
            else { return false }
            return servers[config.name] != nil

        case .plugin(let name):
            // Same check as PluginCheck in doctor — look at settings.json
            guard let settings = try? Settings.load(from: environment.claudeSettings) else {
                return false
            }
            return settings.enabledPlugins?[name] == true

        case .copySkill(_, let destination):
            let dest = environment.skillsDirectory.appendingPathComponent(destination)
            return fm.fileExists(atPath: dest.path)

        case .copyHook(_, let destination):
            let dest = environment.hooksDirectory.appendingPathComponent(destination)
            return fm.fileExists(atPath: dest.path)

        case .copyCommand(_, let destination, _):
            let dest = environment.commandsDirectory.appendingPathComponent(destination)
            return fm.fileExists(atPath: dest.path)

        case .settingsMerge:
            return false // Always run merge to pick up new settings

        case .gitignoreEntries:
            return false // Idempotent, safe to re-run

        case .shellCommand:
            // Check known components by their expected command on PATH
            switch component.id {
            case "core.homebrew":
                return Homebrew(shell: shell, environment: environment).isInstalled
            case "core.claude-code":
                return shell.commandExists("claude")
            default:
                return false
            }
        }
    }

    // MARK: - Interactive Selection Helpers

    private func interactiveSelectByCategory(
        _ state: inout SelectionState,
        coreComponents: [ComponentDefinition]
    ) {
        let grouped = CoreComponents.grouped

        for (type, components) in grouped {
            output.header(type.rawValue + "s")
            output.dimmed(descriptionForType(type))
            output.plain("")

            for (index, component) in components.enumerated() {
                output.plain("  \(index + 1). \(component.displayName)")
                output.dimmed("   \(component.description)")
                if !component.isRequired {
                    if output.askYesNo("Install \(component.displayName)?") {
                        state.select(component.id)
                    }
                } else {
                    state.select(component.id)
                    output.dimmed("   (required, will be installed)")
                }
                output.plain("")
            }
        }
    }

    private func descriptionForType(_ type: ComponentType) -> String {
        switch type {
        case .mcpServer:
            return "MCP servers give Claude specialized capabilities."
        case .plugin:
            return "Plugins extend Claude Code with specialized features."
        case .skill:
            return "Skills provide specialized knowledge and workflows."
        case .command:
            return "Custom slash commands for Claude Code."
        case .hookFile:
            return "Hooks run automatically at key points in the session."
        case .configuration:
            return "Settings and configuration for Claude Code."
        case .brewPackage:
            return "System dependencies."
        }
    }

    private func askBranchPrefix(_ state: inout SelectionState) {
        if state.isSelected("core.command.pr") {
            output.plain("")
            output.plain("  Your name for branch naming (e.g. bruno -> bruno/ABC-123-fix-login)")
            output.plain("  Leave empty for feature/ABC-123-fix-login")
            output.plain("")
            if let answer = readLine()?.trimmingCharacters(in: .whitespaces), !answer.isEmpty {
                state.branchPrefix = answer
            } else {
                state.branchPrefix = "feature"
                output.info("Defaulting branch prefix to: feature")
            }
        }
    }
}
