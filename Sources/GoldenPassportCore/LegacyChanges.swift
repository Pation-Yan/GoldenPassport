import CryptoKit
import Foundation

/// What `gp.secrets` held when 0.2.x last settled it: each account's name and a fingerprint
/// of its otpauth URL, never the secret or the URL. Changes 0.1.x makes later (say, after
/// rollback.sh) show up as differences from it, while accounts deleted in 0.2.x, which stay
/// in `gp.secrets`, do not. See docs/design/i6-legacy-changes.md.
public struct LegacyBaseline: Codable, Equatable, Sendable {
    public static let fileName = "legacy-baseline.json"

    public var version = 1
    public var source = LegacyData.secretsFileName
    public var recordedAt: Date
    /// Account name → fingerprint of its otpauth URL.
    public var entries: [String: String]

    public init(legacy: [String: String], recordedAt: Date = Date()) {
        self.recordedAt = recordedAt
        entries = legacy.mapValues(Self.fingerprint)
    }

    /// Shows whether a URL changed without storing it. TOTP secrets are random enough that
    /// they can't be recovered from the hash.
    public static func fingerprint(_ url: String) -> String {
        SHA256.hash(data: Data("gp-legacy-v1\n\(url)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The baseline in `directory`, or nil if there is none. Throws `UnreadableDataFileError`
    /// if the file can't be read or is in a format this version doesn't know.
    public static func load(from directory: URL) throws -> LegacyBaseline? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let baseline = try decoder.decode(LegacyBaseline.self, from: Data(contentsOf: url))
            guard baseline.version == 1, baseline.source == LegacyData.secretsFileName else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return baseline
        } catch {
            throw UnreadableDataFileError(file: url, underlying: error)
        }
    }

    /// Records `legacy` as the baseline. A file that can't be read is kept as
    /// `legacy-baseline.json.unreadable-<time>` instead of being overwritten; it holds no
    /// accounts, so starting over costs at most one prompt.
    public static func record(_ legacy: [String: String], in directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        if (try? load(from: directory)) == nil, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: FileStorage.keptCopy(of: url))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileStorage.writeProtected(encoder.encode(LegacyBaseline(legacy: legacy)), to: url)
    }
}

/// Accounts that 0.1.x added, changed or deleted in `gp.secrets` since the baseline, for
/// example after rollback.sh, matched against the accounts 0.2.x has now (I6). 0.2.x never
/// writes `gp.secrets`, and importing never overwrites or deletes an account.
public struct LegacyChanges: Sendable {
    public struct Import: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case added, changed
        }

        public var kind: Kind
        /// The account's name in `gp.secrets`.
        public var name: String
        /// The name it is imported under: `name`, or "name (0.1.x)" if an account already has `name`.
        public var importName: String
        var url: String
    }

    /// Accounts to offer for import, in name order.
    public var imports: [Import]
    /// Accounts deleted in 0.1.x that 0.2.x still has as they were at the baseline. Only reported.
    public var removed: [String]
    /// `gp.secrets` as compared: recording it as the baseline settles these changes.
    let legacy: [String: String]
    let baseline: LegacyBaseline

    /// `gp.secrets` changed, but there is nothing to ask about (0.2.x has those accounts already).
    public var isEmpty: Bool { imports.isEmpty && removed.isEmpty }

    /// One line per change, names only: `added:<name>`, `changed:<name>` or `removed:<name>`.
    public var summary: [String] {
        imports.map { "\($0.kind.rawValue):\($0.name)" } + removed.map { "removed:\($0)" }
    }

    /// Compares `gp.secrets` in `directory` with its baseline. nil when there is nothing to
    /// compare (no `gp.secrets`, no baseline, or either can't be read) or nothing changed.
    public static func detect(in directory: URL, accounts: [Account]) -> LegacyChanges? {
        let legacyURL = directory.appendingPathComponent(LegacyData.secretsFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let baseline = try? LegacyBaseline.load(from: directory),
              let legacy = try? LegacyData.readDictionary(at: legacyURL) else { return nil }
        return compare(legacy: legacy, baseline: baseline, accounts: accounts)
    }

    static func compare(legacy: [String: String], baseline: LegacyBaseline, accounts: [Account]) -> LegacyChanges? {
        let changed = legacy.filter { baseline.entries[$0.key] != LegacyBaseline.fingerprint($0.value) }
        let deleted = baseline.entries.filter { legacy[$0.key] == nil }
        guard !changed.isEmpty || !deleted.isEmpty else { return nil }

        // An account 0.2.x already has under any name, e.g. exported from 0.2.x and imported
        // into 0.1.x, is not offered again.
        let urls = Set(accounts.map { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) })
        var takenNames = Set(accounts.map(\.name))
        var imports: [Import] = []
        for (name, url) in changed.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
        where !urls.contains(url.trimmingCharacters(in: .whitespacesAndNewlines)) {
            var importName = name
            var attempt = 1
            while takenNames.contains(importName) {
                importName = attempt == 1 ? "\(name) (0.1.x)" : "\(name) (0.1.x \(attempt))"
                attempt += 1
            }
            takenNames.insert(importName)
            imports.append(Import(kind: baseline.entries[name] == nil ? .added : .changed,
                                  name: name, importName: importName, url: url))
        }
        let removed = accounts
            .filter { deleted[$0.name] == LegacyBaseline.fingerprint($0.url) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return LegacyChanges(imports: imports, removed: removed, legacy: legacy, baseline: baseline)
    }

    /// Imports the chosen accounts (by their name in `gp.secrets`) at the end of the list, then
    /// records `gp.secrets` as compared as the baseline, so neither these changes nor the ones
    /// not chosen are offered again. Import names are worked out again against the accounts as
    /// they are now. Returns how many accounts were added.
    public func importAccounts(named names: Set<String>, into store: AccountStore, directory: URL) throws -> Int {
        let current = Self.compare(legacy: legacy, baseline: baseline, accounts: store.accounts)?.imports ?? []
        let added = try store.importAccounts(current.filter { names.contains($0.name) }
            .map { (name: $0.importName, url: $0.url) })
        try LegacyBaseline.record(legacy, in: directory)
        return added
    }

    /// Records `gp.secrets` as compared as the baseline without importing anything.
    public func acknowledge(in directory: URL) throws {
        try LegacyBaseline.record(legacy, in: directory)
    }
}
