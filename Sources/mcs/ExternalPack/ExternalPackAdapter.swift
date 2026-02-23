import Foundation

/// Bridges an `ExternalPackManifest` (loaded from `techpack.yaml`) to the
/// `TechPack` protocol, allowing external packs to participate in the same install,
/// doctor, and configure flows as compiled-in packs.
/// Note: migrations and settingsFile actions are not yet supported.
struct ExternalPackAdapter: TechPack {
    let manifest: ExternalPackManifest
    let packPath: URL
    let shell: ShellRunner
    let output: CLIOutput
    let scriptRunner: ScriptRunner

    init(
        manifest: ExternalPackManifest,
        packPath: URL,
        shell: ShellRunner = ShellRunner(environment: Environment()),
        output: CLIOutput = CLIOutput(),
        scriptRunner: ScriptRunner? = nil
    ) {
        self.manifest = manifest
        self.packPath = packPath
        self.shell = shell
        self.output = output
        self.scriptRunner = scriptRunner ?? ScriptRunner(shell: shell, output: output)
    }

    // MARK: - TechPack Identity

    var identifier: String { manifest.identifier }
    var displayName: String { manifest.displayName }
    var description: String { manifest.description }

    // MARK: - Components

    var components: [ComponentDefinition] {
        guard let externalComponents = manifest.components else { return [] }
        return externalComponents.compactMap { ext in
            convertComponent(ext)
        }
    }

    // MARK: - Templates

    var templates: [TemplateContribution] {
        guard let externalTemplates = manifest.templates else { return [] }
        var result: [TemplateContribution] = []
        for ext in externalTemplates {
            do {
                let content = try readPackFile(ext.contentFile)
                result.append(TemplateContribution(
                    sectionIdentifier: ext.sectionIdentifier,
                    templateContent: content,
                    placeholders: ext.placeholders ?? []
                ))
            } catch {
                output.error("Template '\(ext.sectionIdentifier)' could not be loaded: \(error.localizedDescription)")
                output.plain("  The generated CLAUDE.local.md will be missing the '\(ext.sectionIdentifier)' section.")
            }
        }
        return result
    }

    // MARK: - Hook Contributions

    var hookContributions: [HookContribution] {
        guard let externalHooks = manifest.hookContributions else { return [] }
        var result: [HookContribution] = []
        for ext in externalHooks {
            do {
                let fragment = try readPackFile(ext.fragmentFile)
                result.append(HookContribution(
                    hookName: ext.hookName,
                    scriptFragment: fragment,
                    position: ext.position?.hookPosition ?? .after
                ))
            } catch {
                output.error("Hook fragment '\(ext.hookName)' could not be loaded: \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Gitignore Entries

    var gitignoreEntries: [String] {
        manifest.gitignoreEntries ?? []
    }

    // MARK: - Doctor Checks

    var supplementaryDoctorChecks: [any DoctorCheck] {
        guard let externalChecks = manifest.supplementaryDoctorChecks else { return [] }
        let projectRoot = ProjectDetector.findProjectRoot()

        return externalChecks.compactMap { ext in
            convertDoctorCheck(ext, scriptRunner: scriptRunner, projectRoot: projectRoot)
        }
    }

    // MARK: - Migrations

    var migrations: [any PackMigration] { [] }

    // MARK: - Template Values (Prompt Execution)

    func templateValues(context: ProjectConfigContext) -> [String: String] {
        guard let prompts = manifest.prompts, !prompts.isEmpty else { return [:] }
        let executor = PromptExecutor(output: context.output, scriptRunner: scriptRunner)

        do {
            return try executor.executeAll(
                prompts: prompts,
                packPath: packPath,
                projectPath: context.projectPath
            )
        } catch {
            context.output.error("Failed to resolve template values for pack '\(manifest.identifier)': \(error.localizedDescription)")
            context.output.plain("  Template placeholders will not be substituted. Re-run 'mcs configure' after fixing the issue.")
            return [:]
        }
    }

    // MARK: - Project Configuration

    func configureProject(at path: URL, context: ProjectConfigContext) throws {
        guard let configure = manifest.configureProject else { return }

        let scriptURL = packPath.appendingPathComponent(configure.script)

        // Build env vars from resolved template values
        var env: [String: String] = [:]
        env["MCS_PROJECT_PATH"] = path.path
        for (key, value) in context.resolvedValues {
            env["MCS_RESOLVED_\(key.uppercased())"] = value
        }

        let result = try scriptRunner.run(
            script: scriptURL,
            packPath: packPath,
            environmentVars: env,
            workingDirectory: path.path,
            timeout: 60
        )

        if !result.succeeded {
            throw PackAdapterError.configureScriptFailed(result.stderr)
        }
    }

    // MARK: - File Reading

    /// Read a file from the pack checkout directory. Validates path containment
    /// by resolving symlinks before comparing paths.
    private func readPackFile(_ relativePath: String) throws -> String {
        let fileURL = packPath.appendingPathComponent(relativePath)
        let resolved = fileURL.resolvingSymlinksInPath().path
        let packBase = packPath.resolvingSymlinksInPath().path
        let packPrefix = packBase.hasSuffix("/") ? packBase : packBase + "/"

        guard resolved.hasPrefix(packPrefix) || resolved == packBase else {
            throw PackAdapterError.pathTraversal(relativePath)
        }

        return try String(contentsOf: URL(fileURLWithPath: resolved), encoding: .utf8)
    }

    // MARK: - Component Conversion

    private func convertComponent(_ ext: ExternalComponentDefinition) -> ComponentDefinition? {
        guard let action = convertInstallAction(ext.installAction) else { return nil }

        let supplementary: [any DoctorCheck]
        if let checks = ext.doctorChecks {
            let projectRoot = ProjectDetector.findProjectRoot()
            supplementary = checks.compactMap { convertDoctorCheck($0, scriptRunner: scriptRunner, projectRoot: projectRoot) }
        } else {
            supplementary = []
        }

        return ComponentDefinition(
            id: ext.id,
            displayName: ext.displayName,
            description: ext.description,
            type: ext.type.componentType,
            packIdentifier: manifest.identifier,
            dependencies: ext.dependencies ?? [],
            isRequired: ext.isRequired ?? false,
            installAction: action,
            supplementaryChecks: supplementary
        )
    }

    private func convertInstallAction(_ ext: ExternalInstallAction) -> ComponentInstallAction? {
        switch ext {
        case .mcpServer(let config):
            return .mcpServer(config.toMCPServerConfig())

        case .plugin(let name):
            return .plugin(name: name)

        case .brewInstall(let package):
            return .brewInstall(package: package)

        case .shellCommand(let command):
            return .shellCommand(command: command)

        case .gitignoreEntries(let entries):
            return .gitignoreEntries(entries: entries)

        case .settingsMerge:
            return .settingsMerge

        case .settingsFile:
            output.warn("settingsFile is not yet supported; treating as settingsMerge. Use settingsMerge instead.")
            return .settingsMerge

        case .copyPackFile(let config):
            let sourceURL = packPath.appendingPathComponent(config.source)
            let fileType: CopyFileType
            if let extType = config.fileType {
                fileType = CopyFileType(rawValue: extType.rawValue) ?? .generic
            } else {
                fileType = .generic
            }
            return .copyPackFile(
                source: sourceURL,
                destination: config.destination,
                fileType: fileType
            )
        }
    }

    // MARK: - Doctor Check Conversion

    private func convertDoctorCheck(
        _ ext: ExternalDoctorCheckDefinition,
        scriptRunner: ScriptRunner,
        projectRoot: URL?
    ) -> (any DoctorCheck)? {
        ExternalDoctorCheckFactory.makeCheck(
            from: ext,
            packPath: packPath,
            projectRoot: projectRoot,
            scriptRunner: scriptRunner
        )
    }
}

// MARK: - Errors

enum PackAdapterError: Error, Equatable, Sendable, LocalizedError {
    case pathTraversal(String)
    case configureScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .pathTraversal(let path):
            return "Path traversal attempt: '\(path)' escapes pack directory"
        case .configureScriptFailed(let message):
            return "Configure script failed: \(message)"
        }
    }
}
