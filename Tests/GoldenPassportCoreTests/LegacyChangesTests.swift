import Foundation
import Testing
@testable import GoldenPassportCore

/// I6: changes 0.1.x makes to gp.secrets after the migration (docs/design/i6-legacy-changes.md).
struct LegacyChangesTests {
    private func url(_ label: String, secret: String = "MZXW6YTBOI") -> String {
        "otpauth://totp/\(label)?secret=\(secret)"
    }

    private func environment(_ dir: URL) -> AppEnvironment {
        AppEnvironment(dataDirectory: dir, seedDirectory: nil, defaults: .init(httpPort: 17304, hotkeysEnabled: true))
    }

    private func legacyURL(_ dir: URL) -> URL { dir.appendingPathComponent(LegacyData.secretsFileName) }
    private func baselineURL(_ dir: URL) -> URL { dir.appendingPathComponent(LegacyBaseline.fileName) }

    /// A data directory upgraded from 0.1.x with `legacy` as gp.secrets.
    private func migrated(_ legacy: [String: String]) throws -> URL {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(legacy, to: legacyURL(dir))
        try environment(dir).prepareDataDirectory()
        return dir
    }

    /// What 0.1.x writes after a rollback.
    private func edit01x(_ dir: URL, _ legacy: [String: String]) throws {
        try LegacyData.writeDictionary(legacy, to: legacyURL(dir))
    }

    private func detect(_ dir: URL) throws -> LegacyChanges? {
        LegacyChanges.detect(in: dir, accounts: try AccountStore(directory: dir).accounts)
    }

    @Test func migrationRecordsNamesAndFingerprintsOnly() throws {
        let dir = try migrated(["GitHub:alice": url("GitHub:alice", secret: "JBSWY3DPEHPK3PXP")])
        let text = try String(contentsOf: baselineURL(dir), encoding: .utf8)
        #expect(text.contains("GitHub:alice"))
        #expect(!text.contains("JBSWY3DPEHPK3PXP") && !text.contains("otpauth"))
        let permissions = try FileManager.default.attributesOfItem(atPath: baselineURL(dir).path)[.posixPermissions]
        #expect((permissions as? NSNumber)?.intValue == 0o600)
        #expect(try LegacyBaseline.load(from: dir)?.entries.keys.sorted() == ["GitHub:alice"])
        #expect(try detect(dir) == nil)
    }

    @Test func rewrittenButUnchangedFileIsNoChange() throws {
        let dir = try migrated(["a": url("a"), "b": url("b")])
        // Same content, different bytes: 0.1.x rewrites the whole file on every save.
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.outputFormat = .xml
        archiver.encode(NSDictionary(dictionary: ["b": url("b"), "a": url("a")]), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        #expect(try archiver.encodedData != Data(contentsOf: legacyURL(dir)))
        try archiver.encodedData.write(to: legacyURL(dir))
        #expect(try LegacyData.readDictionary(at: legacyURL(dir)) == ["a": url("a"), "b": url("b")])
        #expect(try detect(dir) == nil)
    }

    @Test func accountAddedIn01xIsOfferedUntilImported() throws {
        let dir = try migrated(["a": url("a")])
        try edit01x(dir, ["a": url("a"), "b": url("b")])
        let store = try AccountStore(directory: dir)
        let changes = try #require(LegacyChanges.detect(in: dir, accounts: store.accounts))
        #expect(changes.imports == [.init(kind: .added, name: "b", importName: "b", url: url("b"))])
        #expect(changes.removed.isEmpty)

        #expect(try changes.importAccounts(named: ["b"], into: store, directory: dir) == 1)
        #expect(store.accounts.map(\.name) == ["a", "b"])
        #expect(store.accounts[1].url == url("b"))
        #expect(LegacyChanges.detect(in: dir, accounts: store.accounts) == nil)
    }

    @Test func changedURLIsImportedNextToTheExistingAccount() throws {
        let dir = try migrated(["a": url("a"), "a (0.1.x)": url("other")])
        try edit01x(dir, ["a": url("a", secret: "JBSWY3DPEHPK3PXP"), "a (0.1.x)": url("other")])
        let store = try AccountStore(directory: dir)
        let changes = try #require(LegacyChanges.detect(in: dir, accounts: store.accounts))
        #expect(changes.imports.map(\.kind) == [.changed])
        #expect(changes.imports.map(\.importName) == ["a (0.1.x 2)"])

        _ = try changes.importAccounts(named: ["a"], into: store, directory: dir)
        #expect(store.accounts.map(\.name) == ["a", "a (0.1.x)", "a (0.1.x 2)"])
        #expect(store.accounts[0].url == url("a"))
        #expect(store.accounts[2].url == url("a", secret: "JBSWY3DPEHPK3PXP"))
    }

    @Test func accountDeletedIn01xIsOnlyReported() throws {
        let dir = try migrated(["a": url("a"), "b": url("b")])
        try edit01x(dir, ["a": url("a")])
        let changes = try #require(try detect(dir))
        #expect(changes.imports.isEmpty)
        #expect(changes.removed == ["b"])
        #expect(changes.summary == ["removed:b"])

        try changes.acknowledge(in: dir)
        #expect(try AccountStore(directory: dir).accounts.map(\.name) == ["a", "b"])
        #expect(try detect(dir) == nil)
    }

    @Test func accountThat02xAlreadyHasIsNotOffered() throws {
        let dir = try migrated(["a": url("a")])
        try AccountStore(directory: dir).add(name: "b in 0.2.x", url: url("b"))
        // Say, exported from 0.2.x and imported into 0.1.x; 0.1.x keeps pasted whitespace.
        try edit01x(dir, ["a": url("a"), "b": " \(url("b"))\n"])
        let changes = try #require(try detect(dir))
        #expect(changes.isEmpty)
    }

    @Test func accountDeletedIn02xIsNotOfferedBack() throws {
        let dir = try migrated(["a": url("a"), "b": url("b")])
        let store = try AccountStore(directory: dir)
        try store.remove(id: store.accounts[1].id)
        #expect(LegacyChanges.detect(in: dir, accounts: store.accounts) == nil)

        try edit01x(dir, ["a": url("a"), "b": url("b"), "c": url("c")])
        let changes = try #require(LegacyChanges.detect(in: dir, accounts: store.accounts))
        #expect(changes.summary == ["added:c"])
    }

    @Test func installMigratedBeforeI6GetsABaselineSilently() throws {
        let dir = try migrated(["a": url("a")])
        try FileManager.default.removeItem(at: baselineURL(dir))
        try edit01x(dir, ["a": url("a"), "b": url("b")])

        try environment(dir).prepareDataDirectory()
        #expect(try LegacyBaseline.load(from: dir)?.entries.keys.sorted() == ["a", "b"])
        #expect(try detect(dir) == nil)
    }

    @Test func unreadableLegacyFileNoLongerStopsStartup() throws {
        let dir = try migrated(["a": url("a")])
        try Data("not a keyed archive".utf8).write(to: legacyURL(dir))
        try environment(dir).prepareDataDirectory()
        #expect(try detect(dir) == nil)

        try FileManager.default.removeItem(at: baselineURL(dir))
        try environment(dir).prepareDataDirectory()
        #expect(try AccountStore(directory: dir).accounts.map(\.name) == ["a"])
        #expect(!FileManager.default.fileExists(atPath: baselineURL(dir).path))
    }

    @Test func unreadableBaselineIsKeptAndRecordedAgain() throws {
        let dir = try migrated(["a": url("a")])
        try Data("not json".utf8).write(to: baselineURL(dir))
        try environment(dir).prepareDataDirectory()

        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("\(LegacyBaseline.fileName).unreadable-") }
        #expect(kept.count == 1)
        #expect(try LegacyBaseline.load(from: dir)?.entries.keys.sorted() == ["a"])
    }

    @Test func migrationCheckReportsChangesWithoutSettlingThem() throws {
        let dir = try migrated(["a": url("a"), "b": url("b")])
        try edit01x(dir, ["a": url("a", secret: "JBSWY3DPEHPK3PXP"), "c": url("c")])
        let baseline = try Data(contentsOf: baselineURL(dir))

        let check = try MigrationCheck.run(environment: environment(dir))
        #expect(check.status == .alreadyMigrated && check.isConsistent)
        #expect(check.legacyImportCount == 2)
        let report = check.report.split(separator: "\n").map(String.init)
        #expect(report.contains("legacy_imports=2"))
        #expect(report.filter { $0.hasPrefix("legacy_change=") }
            == ["legacy_change=changed:a", "legacy_change=added:c", "legacy_change=removed:b"])
        #expect(!check.report.contains("otpauth") && !check.report.contains("MZXW6YTBOI"))
        #expect(try Data(contentsOf: baselineURL(dir)) == baseline)
    }

    @Test func freshMigrationReportsNoChanges() throws {
        let dir = try makeTempDirectory()
        try LegacyData.writeDictionary(["a": url("a")], to: legacyURL(dir))
        let check = try MigrationCheck.run(environment: environment(dir))
        #expect(check.status == .migrated)
        #expect(check.report.contains("legacy_imports=0"))
        #expect(!check.report.contains("legacy_change="))
    }

    @Test func reportKeepsEachNameOnOneLine() {
        let check = MigrationCheck(status: .alreadyMigrated, legacyCount: 1, accountCount: 1, mismatchedNames: [],
                                   legacyChanges: ["added:two\nlines"], legacyImportCount: 1)
        #expect(check.report.split(separator: "\n").last == "legacy_change=added:two lines")
    }
}
