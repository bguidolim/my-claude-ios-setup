import Foundation

/// Discovers and loads external tech packs from `~/.mcs/packs/`.
/// Reads the pack registry to find registered packs, then loads each one
/// by parsing its `techpack.yaml` manifest and wrapping it in an `ExternalPackAdapter`.
struct ExternalPackLoader: Sendable {
    let environment: Environment
    let registry: PackRegistryFile

    /// Errors specific to pack loading.
    enum LoadError: Error, Equatable, Sendable, LocalizedError {
        case manifestNotFound(String)
        case invalidManifest(identifier: String, reason: String)
        case incompatibleVersion(pack: String, required: String, current: String)
        case localCheckoutMissing(identifier: String, path: String)
        case referencedFilesMissing(identifier: String, files: [String])

        var errorDescription: String? {
            switch self {
            case .manifestNotFound(let path):
                return "techpack.yaml not found at '\(path)'"
            case .invalidManifest(let id, let reason):
                return "Invalid manifest for pack '\(id)': \(reason)"
            case .incompatibleVersion(let pack, let required, let current):
                return "Pack '\(pack)' requires mcs >= \(required), current is \(current)"
            case .localCheckoutMissing(let id, let path):
                return "Pack '\(id)' checkout missing at '\(path)'"
            case .referencedFilesMissing(let id, let files):
                return "Pack '\(id)' references missing files: \(files.joined(separator: ", "))"
            }
        }
    }

    // MARK: - Loading

    /// Load all registered external packs from disk.
    /// Returns adapters for packs that exist and are valid.
    /// Logs warnings for packs that are registered but missing or invalid.
    func loadAll(output: CLIOutput) -> [ExternalPackAdapter] {
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            output.error("Could not read pack registry at '\(registry.path.path)': \(error.localizedDescription)\n  Fix: rm '\(registry.path.path)' and re-add packs")
            return []
        }

        var adapters: [ExternalPackAdapter] = []

        for entry in registryData.packs {
            do {
                let adapter = try loadEntry(entry)
                adapters.append(adapter)
            } catch let error as LoadError where isTrustFailure(error) {
                output.error("SECURITY: Pack '\(entry.identifier)' failed trust verification!")
                output.error("  \(error.localizedDescription)")
                output.error("  This pack will NOT be loaded. Run 'mcs pack update \(entry.identifier)' to re-verify.")
            } catch {
                output.warn("Skipping pack '\(entry.identifier)': \(error.localizedDescription)")
            }
        }

        return adapters
    }

    /// Load a single pack by identifier.
    func load(identifier: String, output: CLIOutput) throws -> ExternalPackAdapter {
        let registryData = try registry.load()

        guard let entry = registry.pack(identifier: identifier, in: registryData) else {
            throw LoadError.localCheckoutMissing(
                identifier: identifier,
                path: environment.packsDirectory.appendingPathComponent(identifier).path
            )
        }

        return try loadEntry(entry)
    }

    /// Validate a pack directory contains a valid techpack.yaml.
    /// Returns the parsed and validated manifest.
    func validate(at path: URL) throws -> ExternalPackManifest {
        let manifestURL = path.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        let fm = FileManager.default

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw LoadError.manifestNotFound(manifestURL.path)
        }

        let manifest: ExternalPackManifest
        do {
            let raw = try ExternalPackManifest.load(from: manifestURL)
            manifest = raw.normalized()
        } catch {
            throw LoadError.invalidManifest(
                identifier: "unknown",
                reason: error.localizedDescription
            )
        }

        // Validate manifest structure
        do {
            try manifest.validate()
        } catch {
            throw LoadError.invalidManifest(
                identifier: manifest.identifier,
                reason: error.localizedDescription
            )
        }

        // Check minMCSVersion compatibility
        if let minVersion = manifest.minMCSVersion {
            let current = MCSVersion.current
            if !SemVer.isCompatible(current: current, required: minVersion) {
                throw LoadError.incompatibleVersion(
                    pack: manifest.identifier,
                    required: minVersion,
                    current: current
                )
            }
        }

        // Verify referenced files exist
        let missingFiles = findMissingReferencedFiles(in: manifest, packPath: path)
        if !missingFiles.isEmpty {
            throw LoadError.referencedFilesMissing(
                identifier: manifest.identifier,
                files: missingFiles
            )
        }

        return manifest
    }

    /// Check if a load error is a trust verification failure.
    private func isTrustFailure(_ error: LoadError) -> Bool {
        if case .invalidManifest(_, let reason) = error {
            return reason.contains("Trusted scripts modified")
        }
        return false
    }

    // MARK: - Internal

    /// Load a pack from a registry entry.
    private func loadEntry(_ entry: PackRegistryFile.PackEntry) throws -> ExternalPackAdapter {
        let packPath = environment.packsDirectory.appendingPathComponent(entry.localPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: packPath.path) else {
            throw LoadError.localCheckoutMissing(
                identifier: entry.identifier,
                path: packPath.path
            )
        }

        let manifest = try validate(at: packPath)

        // Verify trusted scripts haven't been tampered with
        let trustManager = PackTrustManager(output: CLIOutput())
        let modified = trustManager.verifyTrust(
            trustedHashes: entry.trustedScriptHashes,
            packPath: packPath
        )
        if !modified.isEmpty {
            throw LoadError.invalidManifest(
                identifier: entry.identifier,
                reason: "Trusted scripts modified: \(modified.joined(separator: ", ")). Run 'mcs pack update \(entry.identifier)' to re-trust."
            )
        }

        let shell = ShellRunner(environment: environment)
        let output = CLIOutput()
        return ExternalPackAdapter(
            manifest: manifest,
            packPath: packPath,
            shell: shell,
            output: output
        )
    }

    /// Find files referenced in the manifest that don't exist on disk.
    /// Note: Does not check doctor check script files (shellScript command, fixScript).
    /// Those are validated at runtime when the check executes.
    private func findMissingReferencedFiles(
        in manifest: ExternalPackManifest,
        packPath: URL
    ) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []

        // Template content files
        if let templates = manifest.templates {
            for template in templates {
                let file = packPath.appendingPathComponent(template.contentFile)
                if !fm.fileExists(atPath: file.path) {
                    missing.append(template.contentFile)
                }
            }
        }

        // Hook fragment files
        if let hooks = manifest.hookContributions {
            for hook in hooks {
                let file = packPath.appendingPathComponent(hook.fragmentFile)
                if !fm.fileExists(atPath: file.path) {
                    missing.append(hook.fragmentFile)
                }
            }
        }

        // Configure project script
        if let configure = manifest.configureProject {
            let file = packPath.appendingPathComponent(configure.script)
            if !fm.fileExists(atPath: file.path) {
                missing.append(configure.script)
            }
        }

        // Copy pack file sources
        if let components = manifest.components {
            for component in components {
                if case .copyPackFile(let config) = component.installAction {
                    let file = packPath.appendingPathComponent(config.source)
                    if !fm.fileExists(atPath: file.path) {
                        missing.append(config.source)
                    }
                }
            }
        }

        return missing
    }
}

// MARK: - Peer Dependency Validation

/// Result of a peer dependency check.
struct PeerDependencyResult: Equatable, Sendable {
    let packIdentifier: String
    let peerPack: String
    let minVersion: String
    let status: Status

    enum Status: Equatable, Sendable {
        case satisfied
        case missing
        case versionTooLow(actual: String)
    }
}

/// Validate peer dependencies for a manifest against registered packs.
enum PeerDependencyValidator {
    /// Check peer dependencies of a single manifest against the registry.
    /// Used by `mcs pack add` to warn about missing peers.
    static func validate(
        manifest: ExternalPackManifest,
        registeredPacks: [PackRegistryFile.PackEntry]
    ) -> [PeerDependencyResult] {
        guard let peers = manifest.peerDependencies, !peers.isEmpty else {
            return []
        }

        return peers.map { peer in
            if let entry = registeredPacks.first(where: { $0.identifier == peer.pack }) {
                if SemVer.isCompatible(current: entry.version, required: peer.minVersion) {
                    return PeerDependencyResult(
                        packIdentifier: manifest.identifier,
                        peerPack: peer.pack,
                        minVersion: peer.minVersion,
                        status: .satisfied
                    )
                } else {
                    return PeerDependencyResult(
                        packIdentifier: manifest.identifier,
                        peerPack: peer.pack,
                        minVersion: peer.minVersion,
                        status: .versionTooLow(actual: entry.version)
                    )
                }
            } else {
                return PeerDependencyResult(
                    packIdentifier: manifest.identifier,
                    peerPack: peer.pack,
                    minVersion: peer.minVersion,
                    status: .missing
                )
            }
        }
    }

    /// Check peer dependencies for all selected packs at configure time.
    /// Validates that each pack's peer dependencies are satisfied by the selected set.
    static func validateSelection(
        packs: [any TechPack],
        registeredPacks: [PackRegistryFile.PackEntry]
    ) -> [PeerDependencyResult] {
        let selectedIDs = Set(packs.map(\.identifier))
        var results: [PeerDependencyResult] = []

        // Check peer deps for each selected pack against the selected set
        for pack in packs {
            guard let adapter = pack as? ExternalPackAdapter else { continue }
            guard let peers = adapter.manifest.peerDependencies, !peers.isEmpty else { continue }

            for peer in peers {
                if !selectedIDs.contains(peer.pack) {
                    results.append(PeerDependencyResult(
                        packIdentifier: pack.identifier,
                        peerPack: peer.pack,
                        minVersion: peer.minVersion,
                        status: .missing
                    ))
                } else if let peerEntry = registeredPacks.first(where: { $0.identifier == peer.pack }) {
                    if !SemVer.isCompatible(current: peerEntry.version, required: peer.minVersion) {
                        results.append(PeerDependencyResult(
                            packIdentifier: pack.identifier,
                            peerPack: peer.pack,
                            minVersion: peer.minVersion,
                            status: .versionTooLow(actual: peerEntry.version)
                        ))
                    }
                }
            }
        }

        return results
    }
}

// MARK: - Semver Comparison

/// Minimal semver comparison for `minMCSVersion` checks.
enum SemVer {
    /// Check if `current` satisfies `>= required`.
    /// Both must be in `major.minor.patch` format.
    static func isCompatible(current: String, required: String) -> Bool {
        guard let currentParts = parse(current),
              let requiredParts = parse(required) else {
            return false  // Unparseable versions are incompatible
        }

        if currentParts.major != requiredParts.major {
            return currentParts.major > requiredParts.major
        }
        if currentParts.minor != requiredParts.minor {
            return currentParts.minor > requiredParts.minor
        }
        return currentParts.patch >= requiredParts.patch
    }

    /// Parse a version string into (major, minor, patch) components.
    /// Strips pre-release suffixes (e.g., "2.1.0-alpha" → 2.1.0).
    /// Returns nil if the string does not contain at least three numeric components.
    static func parse(_ version: String) -> (major: Int, minor: Int, patch: Int)? {
        // Strip pre-release suffix: "2.1.0-alpha" → "2.1.0"
        let base = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = base.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        return (major: parts[0], minor: parts[1], patch: parts[2])
    }
}
