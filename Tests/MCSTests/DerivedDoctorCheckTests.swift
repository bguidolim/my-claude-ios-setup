import Foundation
import Testing

@testable import mcs

@Suite("DerivedDoctorChecks")
struct DerivedDoctorCheckTests {
    // MARK: - deriveDoctorCheck() generation

    @Test("mcpServer action derives MCPServerCheck")
    func mcpServerDerivation() {
        let component = ComponentDefinition(
            id: "test.mcp",
            displayName: "TestServer",
            description: "test",
            type: .mcpServer,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            installAction: .mcpServer(MCPServerConfig(
                name: "test-server", command: "cmd", args: [], env: [:]
            ))
        )
        let check = component.deriveDoctorCheck()
        #expect(check != nil)
        #expect(check?.name == "TestServer")
        #expect(check?.section == "MCP Servers")
    }

    @Test("plugin action derives PluginCheck")
    func pluginDerivation() {
        let component = ComponentDefinition(
            id: "test.plugin",
            displayName: "test-plugin",
            description: "test",
            type: .plugin,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            installAction: .plugin(name: "test-plugin@test-org")
        )
        let check = component.deriveDoctorCheck()
        #expect(check != nil)
        #expect(check?.name == "test-plugin")
        #expect(check?.section == "Plugins")
    }

    @Test("brewInstall action derives CommandCheck")
    func brewInstallDerivation() {
        let component = ComponentDefinition(
            id: "test.brew",
            displayName: "TestPkg",
            description: "test",
            type: .brewPackage,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            installAction: .brewInstall(package: "testpkg")
        )
        let check = component.deriveDoctorCheck()
        #expect(check != nil)
        #expect(check?.name == "TestPkg")
        #expect(check?.section == "Dependencies")
    }

    @Test("shellCommand action returns nil (not derivable)")
    func shellCommandReturnsNil() {
        let component = ComponentDefinition(
            id: "test.shell",
            displayName: "test",
            description: "test",
            type: .brewPackage,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            installAction: .shellCommand(command: "echo hello")
        )
        #expect(component.deriveDoctorCheck() == nil)
    }

    @Test("settingsMerge action returns nil (not derivable)")
    func settingsMergeReturnsNil() {
        let component = ComponentDefinition(
            id: "test.settings",
            displayName: "test",
            description: "test",
            type: .configuration,
            packIdentifier: nil,
            dependencies: [],
            isRequired: true,
            installAction: .settingsMerge(source: nil)
        )
        #expect(component.deriveDoctorCheck() == nil)
    }

    @Test("gitignoreEntries action returns nil (not derivable)")
    func gitignoreReturnsNil() {
        let component = ComponentDefinition(
            id: "test.gitignore",
            displayName: "test",
            description: "test",
            type: .configuration,
            packIdentifier: nil,
            dependencies: [],
            isRequired: true,
            installAction: .gitignoreEntries(entries: [".test"])
        )
        #expect(component.deriveDoctorCheck() == nil)
    }

    // MARK: - allDoctorChecks combines derived + supplementary

    @Test("allDoctorChecks returns derived + supplementary")
    func allDoctorChecksCombines() {
        let supplementary = CommandCheck(
            name: "test", section: "Dependencies", command: "test"        )
        let component = ComponentDefinition(
            id: "test.combined",
            displayName: "TestPkg",
            description: "test",
            type: .brewPackage,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            installAction: .brewInstall(package: "testpkg"),
            supplementaryChecks: [supplementary]
        )
        let checks = component.allDoctorChecks()
        // 1 derived (CommandCheck from brewInstall) + 1 supplementary
        #expect(checks.count == 2)
    }

    @Test("shellCommand with supplementaryChecks returns only supplementary")
    func shellCommandWithSupplementary() {
        let supplementary = CommandCheck(
            name: "brew", section: "Dependencies", command: "brew"        )
        let component = ComponentDefinition(
            id: "test.shell",
            displayName: "test",
            description: "test",
            type: .brewPackage,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            installAction: .shellCommand(command: "curl ..."),
            supplementaryChecks: [supplementary]
        )
        let checks = component.allDoctorChecks()
        #expect(checks.count == 1)
        #expect(checks.first?.name == "brew")
    }

}

// MARK: - FileHasher directory hashing

@Suite("FileHasherDirectoryHashing")
struct FileHasherDirectoryHashingTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-dirhash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("directoryFileHashes enumerates files recursively")
    func recursiveEnumeration() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create nested structure
        let subDir = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "file1".write(to: tmpDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "file2".write(to: subDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let hashes = try FileHasher.directoryFileHashes(at: tmpDir)
        let paths = hashes.map(\.relativePath)

        #expect(paths.contains("a.txt"))
        #expect(paths.contains("sub/b.txt"))
        #expect(hashes.count == 2)
    }

    @Test("directoryFileHashes returns sorted results")
    func sortedResults() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "c".write(to: tmpDir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: tmpDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: tmpDir.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)

        let hashes = try FileHasher.directoryFileHashes(at: tmpDir)
        let paths = hashes.map(\.relativePath)

        #expect(paths == ["a.txt", "m.txt", "z.txt"])
    }

    @Test("directoryFileHashes skips hidden files")
    func skipsHidden() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "visible".write(to: tmpDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: tmpDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let hashes = try FileHasher.directoryFileHashes(at: tmpDir)
        #expect(hashes.count == 1)
        #expect(hashes.first?.relativePath == "visible.txt")
    }
}
