import Testing

@testable import mcs

@Suite("Hook injection markers")
struct HookInjectionTests {
    /// Helper that simulates hook injection logic using the same marker format as Installer.
    private func inject(
        into hookContent: String,
        packID: String,
        version: String = MCSVersion.current,
        fragment: String,
        position: HookContribution.HookPosition
    ) -> String {
        var content = hookContent
        let beginMarker = "# --- mcs:begin \(packID) v\(version) ---"
        let endMarker = "# --- mcs:end \(packID) ---"

        // Remove existing section for idempotency (matches both versioned and unversioned markers)
        let pattern = #"# --- mcs:begin \#(packID)( v[0-9]+\.[0-9]+\.[0-9]+)? ---"#
        if let beginRange = content.range(of: pattern, options: .regularExpression),
           let endRange = content.range(of: endMarker) {
            var removeEnd = endRange.upperBound
            if removeEnd < content.endIndex && content[removeEnd] == "\n" {
                removeEnd = content.index(after: removeEnd)
            }
            var removeStart = beginRange.lowerBound
            if removeStart > content.startIndex {
                let before = content.index(before: removeStart)
                if content[before] == "\n" {
                    removeStart = before
                }
            }
            content.removeSubrange(removeStart..<removeEnd)
        }

        let section = "\(beginMarker)\n\(fragment)\n\(endMarker)"

        switch position {
        case .after:
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n\(section)\n"
        case .before:
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
        return content
    }

    @Test("Inject fragment after core hook content with version")
    func injectAfter() {
        let hook = """
            #!/bin/bash
            trap 'exit 0' ERR

            echo "core content"
            """
        let result = inject(into: hook, packID: "ios", fragment: "echo \"ios check\"", position: .after)
        let version = MCSVersion.current
        #expect(result.contains("# --- mcs:begin ios v\(version) ---"))
        #expect(result.contains("echo \"ios check\""))
        #expect(result.contains("# --- mcs:end ios ---"))
        // Fragment should come after core content
        let coreRange = result.range(of: "core content")!
        let markerRange = result.range(of: "# --- mcs:begin ios v\(version) ---")!
        #expect(coreRange.upperBound < markerRange.lowerBound)
    }

    @Test("Inject fragment before core hook content with version")
    func injectBefore() {
        let hook = """
            #!/bin/bash
            trap 'exit 0' ERR

            echo "core content"
            """
        let result = inject(
            into: hook, packID: "web", fragment: "echo \"web setup\"", position: .before
        )
        let version = MCSVersion.current
        #expect(result.contains("# --- mcs:begin web v\(version) ---"))
        #expect(result.contains("echo \"web setup\""))
        // Fragment should come before core content
        let markerRange = result.range(of: "# --- mcs:begin web v\(version) ---")!
        let coreRange = result.range(of: "core content")!
        #expect(markerRange.lowerBound < coreRange.lowerBound)
    }

    @Test("Re-injection replaces existing versioned section (idempotent)")
    func idempotentVersioned() {
        let version = MCSVersion.current
        let hook = """
            #!/bin/bash

            echo "core"

            # --- mcs:begin ios v\(version) ---
            echo "old fragment"
            # --- mcs:end ios ---
            """
        let result = inject(
            into: hook, packID: "ios", fragment: "echo \"new fragment\"", position: .after
        )
        // Should contain new fragment, not old
        #expect(result.contains("echo \"new fragment\""))
        #expect(!result.contains("echo \"old fragment\""))
        // Should have exactly one begin marker
        let count = result.components(separatedBy: "# --- mcs:begin ios").count - 1
        #expect(count == 1)
    }

    @Test("Re-injection replaces old unversioned marker (backward compat)")
    func backwardCompatUnversioned() {
        let hook = """
            #!/bin/bash

            echo "core"

            # --- mcs:begin ios ---
            echo "old unversioned fragment"
            # --- mcs:end ios ---
            """
        let result = inject(
            into: hook, packID: "ios", fragment: "echo \"new fragment\"", position: .after
        )
        let version = MCSVersion.current
        // Should contain new versioned marker
        #expect(result.contains("# --- mcs:begin ios v\(version) ---"))
        #expect(result.contains("echo \"new fragment\""))
        #expect(!result.contains("echo \"old unversioned fragment\""))
        // Old unversioned marker should be gone
        #expect(!result.contains("# --- mcs:begin ios ---\n"))
    }

    @Test("Multiple packs can inject into the same hook")
    func multiplePacks() {
        var hook = """
            #!/bin/bash

            echo "core"
            """
        hook = inject(into: hook, packID: "ios", fragment: "echo \"ios\"", position: .after)
        hook = inject(into: hook, packID: "web", fragment: "echo \"web\"", position: .after)

        let version = MCSVersion.current
        #expect(hook.contains("# --- mcs:begin ios v\(version) ---"))
        #expect(hook.contains("# --- mcs:begin web v\(version) ---"))
        #expect(hook.contains("echo \"ios\""))
        #expect(hook.contains("echo \"web\""))
    }

    @Test("PackMigrationCheck reports needed migration")
    func migrationCheckNeeded() {
        struct TestMigration: PackMigration {
            var name: String { "test-migration" }
            var version: String { "1.0.0" }
            var displayName: String { "Test migration" }
            func isNeeded() -> Bool { true }
            func perform() throws -> String { "migrated" }
        }

        let check = PackMigrationCheck(
            migration: TestMigration(),
            packName: "TestPack"
        )
        let result = check.check()
        if case .warn = result {
            // Expected
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("PackMigrationCheck reports up-to-date")
    func migrationCheckUpToDate() {
        struct NoopMigration: PackMigration {
            var name: String { "noop" }
            var version: String { "1.0.0" }
            var displayName: String { "No-op" }
            func isNeeded() -> Bool { false }
            func perform() throws -> String { "" }
        }

        let check = PackMigrationCheck(
            migration: NoopMigration(),
            packName: "TestPack"
        )
        let result = check.check()
        if case .pass = result {
            // Expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("PackMigrationCheck fix runs migration")
    func migrationCheckFix() {
        struct FixableMigration: PackMigration {
            var name: String { "fixable" }
            var version: String { "1.0.0" }
            var displayName: String { "Fixable" }
            func isNeeded() -> Bool { true }
            func perform() throws -> String { "applied v1 migration" }
        }

        let check = PackMigrationCheck(
            migration: FixableMigration(),
            packName: "TestPack"
        )
        let result = check.fix()
        if case .fixed(let msg) = result {
            #expect(msg == "applied v1 migration")
        } else {
            Issue.record("Expected .fixed, got \(result)")
        }
    }
}
