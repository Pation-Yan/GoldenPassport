import Foundation

/// Per-build configuration read from Info.plist, so the Dev build never touches
/// the data, port or hotkeys of the installed release build.
public struct AppEnvironment: Sendable {
    public struct Defaults: Sendable {
        public var httpPort: Int
        public var hotkeysEnabled: Bool

        public init(httpPort: Int, hotkeysEnabled: Bool) {
            self.httpPort = httpPort
            self.hotkeysEnabled = hotkeysEnabled
        }
    }

    public var dataDirectory: URL
    /// Directory to copy legacy data from on first launch (Dev build only). Never written to.
    public var seedDirectory: URL?
    public var defaults: Defaults

    public init(dataDirectory: URL, seedDirectory: URL?, defaults: Defaults) {
        self.dataDirectory = dataDirectory
        self.seedDirectory = seedDirectory
        self.defaults = defaults
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> AppEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dirName = info["GPDataDirectoryName"] as? String ?? "GoldenPassport"
        let seedName = (info["GPSeedDirectoryName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let port = (info["GPDefaultHTTPPort"] as? NSNumber)?.intValue ?? 17304
        let hotkeys = (info["GPHotkeysEnabledByDefault"] as? NSNumber)?.boolValue ?? true
        return AppEnvironment(
            dataDirectory: support.appendingPathComponent(dirName, isDirectory: true),
            seedDirectory: seedName.map { support.appendingPathComponent($0, isDirectory: true) },
            defaults: Defaults(httpPort: port, hotkeysEnabled: hotkeys))
    }

    /// Creates the data directory, seeds it (Dev only) and migrates legacy files.
    public func prepareDataDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let accountsURL = dataDirectory.appendingPathComponent(AccountStore.fileName)
        let legacySecretsURL = dataDirectory.appendingPathComponent(LegacyData.secretsFileName)
        let legacyConfigURL = dataDirectory.appendingPathComponent(LegacyData.configFileName)

        if let seed = seedDirectory,
           !fm.fileExists(atPath: accountsURL.path),
           !fm.fileExists(atPath: legacySecretsURL.path) {
            for name in [LegacyData.secretsFileName, LegacyData.configFileName] {
                let source = seed.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    try fm.copyItem(at: source, to: dataDirectory.appendingPathComponent(name))
                }
            }
        }

        // 0.1.x left the directory 0755 and its files 0644, readable by every local user.
        // Tightening permissions leaves the contents (and the old app's access) unchanged.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
        for url in [legacySecretsURL, legacyConfigURL] where fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        // Refuse to start on an unreadable accounts.json rather than risk overwriting it.
        _ = try AccountStore.load(from: accountsURL)

        if !fm.fileExists(atPath: accountsURL.path), fm.fileExists(atPath: legacySecretsURL.path) {
            // An unreadable gp.secrets stops startup too: carrying on would create an empty
            // accounts.json, and the accounts would never be migrated.
            let legacy = try LegacyData.readDictionary(at: legacySecretsURL)
            try AccountStore(directory: dataDirectory).replaceAll(with: LegacyData.accounts(from: legacy))

            let settingsURL = dataDirectory.appendingPathComponent(SettingsStore.fileName)
            if !fm.fileExists(atPath: settingsURL.path) {
                // 0.1.x wrote config.plist only once a setting was changed, and fell back
                // to defaults when it could not read it.
                let config = (try? LegacyData.readDictionary(at: legacyConfigURL)) ?? [:]
                let store = SettingsStore(directory: dataDirectory, defaults: defaults)
                // 0.1.x started the HTTP API unless the user had turned that off. New installs
                // start with it off; upgraders keep the old behaviour so their scripts still work.
                store.httpServerAutoStart = config["http_server_auto_start"].map { $0 == "true" } ?? true
                // Only a port the user explicitly changed carries over; Dev keeps its own default.
                if seedDirectory == nil, let port = config["http_server_port"].flatMap(Int.init) {
                    store.httpServerPort = port
                }
            }
        }
    }
}
