import Testing

@testable import mcs

@Suite("SyncCommand argument parsing")
struct SyncCommandTests {

    @Test("Parses with no arguments (defaults)")
    func parsesDefaults() throws {
        let cmd = try SyncCommand.parse([])
        #expect(cmd.path == nil)
        #expect(cmd.pack.isEmpty)
        #expect(cmd.all == false)
        #expect(cmd.dryRun == false)
        #expect(cmd.lock == false)
        #expect(cmd.update == false)
    }

    @Test("Parses path argument")
    func parsesPath() throws {
        let cmd = try SyncCommand.parse(["/tmp/my-project"])
        #expect(cmd.path == "/tmp/my-project")
    }

    @Test("Parses --pack flag (repeatable)")
    func parsesPackRepeatable() throws {
        let cmd = try SyncCommand.parse(["--pack", "ios", "--pack", "android"])
        #expect(cmd.pack == ["ios", "android"])
    }

    @Test("Parses --all flag")
    func parsesAll() throws {
        let cmd = try SyncCommand.parse(["--all"])
        #expect(cmd.all == true)
    }

    @Test("Parses --dry-run flag")
    func parsesDryRun() throws {
        let cmd = try SyncCommand.parse(["--dry-run"])
        #expect(cmd.dryRun == true)
    }

    @Test("Parses --lock flag")
    func parsesLock() throws {
        let cmd = try SyncCommand.parse(["--lock"])
        #expect(cmd.lock == true)
    }

    @Test("Parses --update flag")
    func parsesUpdate() throws {
        let cmd = try SyncCommand.parse(["--update"])
        #expect(cmd.update == true)
    }

    @Test("skipLock is true when --dry-run is set")
    func skipLockWhenDryRun() throws {
        let cmd = try SyncCommand.parse(["--dry-run"])
        #expect(cmd.skipLock == true)
    }

    @Test("skipLock is false by default")
    func skipLockDefaultFalse() throws {
        let cmd = try SyncCommand.parse([])
        #expect(cmd.skipLock == false)
    }

    @Test("Parses combined flags with path")
    func parsesCombined() throws {
        let cmd = try SyncCommand.parse(["--pack", "ios", "--dry-run", "--lock", "/tmp/proj"])
        #expect(cmd.path == "/tmp/proj")
        #expect(cmd.pack == ["ios"])
        #expect(cmd.dryRun == true)
        #expect(cmd.lock == true)
        #expect(cmd.update == false)
        #expect(cmd.all == false)
    }
}
