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

    @Test("detectXcodeProject finds .xcodeproj")
    func detectXcodeproj() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projDir = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let result = IOSTechPack.detectXcodeProject(in: tmpDir)
        #expect(result == "MyApp.xcodeproj")
    }

    @Test("detectXcodeProject prefers .xcworkspace over .xcodeproj")
    func detectPrefersWorkspace() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projDir = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        let workDir = tmpDir.appendingPathComponent("MyApp.xcworkspace")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let result = IOSTechPack.detectXcodeProject(in: tmpDir)
        #expect(result == "MyApp.xcworkspace")
    }

    @Test("detectXcodeProject returns nil when no project found")
    func detectNoProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = IOSTechPack.detectXcodeProject(in: tmpDir)
        #expect(result == nil)
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
