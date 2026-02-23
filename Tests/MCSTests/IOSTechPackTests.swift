import Foundation
import Testing

@testable import mcs

@Suite("IOSTechPack")
struct IOSTechPackTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-ios-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Project detection

    @Test("detectXcodeProjects finds .xcodeproj")
    func detectXcodeproj() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projDir = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let result = try IOSTechPack.detectXcodeProjects(in: tmpDir)
        #expect(result == ["MyApp.xcodeproj"])
    }

    @Test("detectXcodeProjects lists workspaces before projects")
    func detectListsWorkspacesFirst() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projDir = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        let workDir = tmpDir.appendingPathComponent("MyApp.xcworkspace")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let result = try IOSTechPack.detectXcodeProjects(in: tmpDir)
        #expect(result == ["MyApp.xcworkspace", "MyApp.xcodeproj"])
    }

    @Test("detectXcodeProjects returns empty when no project found")
    func detectNoProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try IOSTechPack.detectXcodeProjects(in: tmpDir)
        #expect(result.isEmpty)
    }

    @Test("detectXcodeProjects sorts alphabetically within groups")
    func detectSortsAlphabetically() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for name in ["Z.xcworkspace", "A.xcworkspace", "Z.xcodeproj", "A.xcodeproj"] {
            try FileManager.default.createDirectory(
                at: tmpDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let result = try IOSTechPack.detectXcodeProjects(in: tmpDir)
        #expect(result == ["A.xcworkspace", "Z.xcworkspace", "A.xcodeproj", "Z.xcodeproj"])
    }

    @Test("detectXcodeProjects throws for non-existent directory")
    func detectThrowsForMissingDir() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-nonexistent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try IOSTechPack.detectXcodeProjects(in: bogus)
        }
    }

    @Test("templateValues returns PROJECT for single-project directory")
    func templateValuesSingleProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("MyApp.xcodeproj"),
            withIntermediateDirectories: true
        )

        let pack = IOSTechPack()
        let context = ProjectConfigContext(
            projectPath: tmpDir,
            repoName: "test",
            output: CLIOutput()
        )
        let values = pack.templateValues(context: context)
        #expect(values[IOSConstants.TemplateKeys.project] == "MyApp.xcodeproj")
    }

    @Test("configureProject skips when no PROJECT in resolvedValues")
    func configureProjectSkipsWithoutProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = IOSTechPack()
        let context = ProjectConfigContext(
            projectPath: tmpDir,
            repoName: "test",
            output: CLIOutput()
        )
        try pack.configureProject(at: tmpDir, context: context)

        // config.yaml should not be created
        let configFile = tmpDir
            .appendingPathComponent(IOSConstants.FileNames.xcodeBuildMCPDirectory)
            .appendingPathComponent("config.yaml")
        #expect(!FileManager.default.fileExists(atPath: configFile.path))
    }

    // MARK: - Pack identity

    @Test("iOS pack has correct identifier and display name")
    func packIdentity() {
        let pack = IOSTechPack()
        #expect(pack.identifier == "ios")
        #expect(pack.displayName == "iOS Development")
    }

    @Test("iOS pack provides gitignore entries")
    func gitignoreEntries() {
        let pack = IOSTechPack()
        #expect(pack.gitignoreEntries.contains(".xcodebuildmcp"))
    }

    @Test("iOS pack provides template contributions")
    func templateContributions() {
        let pack = IOSTechPack()
        #expect(!pack.templates.isEmpty)
        #expect(pack.templates.first?.sectionIdentifier == "ios")
    }
}
