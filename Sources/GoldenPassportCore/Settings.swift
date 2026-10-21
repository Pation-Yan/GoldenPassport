import Foundation

/// Modifier combinations offered for the "fill in code N" global hotkeys (N = 0–9).
public enum HotkeyModifiers: String, CaseIterable, Codable, Sendable {
    case controlOptionCommand
    case shiftCommand
    case controlOption

    public var symbols: String {
        switch self {
        case .controlOptionCommand: return "⌃⌥⌘"
        case .shiftCommand: return "⇧⌘"
        case .controlOption: return "⌃⌥"
        }
    }

    /// Hotkey digit for the account at `index` (first account is 0, as in 0.1.x), or nil past the tenth.
    public static func digit(forAccountAt index: Int) -> Int? {
        (0..<10).contains(index) ? index : nil
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var httpServerAutoStart: Bool?
    public var httpServerPort: Int?
    public var hotkeysEnabled: Bool?
    public var hotkeyModifiers: HotkeyModifiers?
    public var httpNoticeSuppressed: Bool?
    public var automaticUpdateChecks: Bool?

    public init(httpServerAutoStart: Bool? = nil, httpServerPort: Int? = nil,
                hotkeysEnabled: Bool? = nil, hotkeyModifiers: HotkeyModifiers? = nil,
                httpNoticeSuppressed: Bool? = nil, automaticUpdateChecks: Bool? = nil) {
        self.httpServerAutoStart = httpServerAutoStart
        self.httpServerPort = httpServerPort
        self.hotkeysEnabled = hotkeysEnabled
        self.hotkeyModifiers = hotkeyModifiers
        self.httpNoticeSuppressed = httpNoticeSuppressed
        self.automaticUpdateChecks = automaticUpdateChecks
    }

    /// Decodes setting by setting: a value this version does not understand (say, a hotkey
    /// choice added by a later version) resets only that setting, not the whole file.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        httpServerAutoStart = try? values.decodeIfPresent(Bool.self, forKey: .httpServerAutoStart)
        httpServerPort = try? values.decodeIfPresent(Int.self, forKey: .httpServerPort)
        hotkeysEnabled = try? values.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled)
        hotkeyModifiers = try? values.decodeIfPresent(HotkeyModifiers.self, forKey: .hotkeyModifiers)
        httpNoticeSuppressed = try? values.decodeIfPresent(Bool.self, forKey: .httpNoticeSuppressed)
        automaticUpdateChecks = try? values.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks)
    }
}

public final class SettingsStore {
    public static let fileName = "settings.json"

    private let fileURL: URL
    private let defaults: AppEnvironment.Defaults
    /// The file exists but is not a settings object at all. It is renamed before the
    /// first save instead of being overwritten.
    private var unreadableFileInPlace: Bool
    public private(set) var settings: Settings

    public init(directory: URL, defaults: AppEnvironment.Defaults) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.defaults = defaults
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
            unreadableFileInPlace = false
        } else {
            settings = Settings()
            unreadableFileInPlace = FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    /// Off unless the user turned it on: anything running as the user can read every code
    /// through the API. Upgraders from 0.1.x get their old value written at migration.
    public var httpServerAutoStart: Bool {
        get { settings.httpServerAutoStart ?? false }
        set { update { $0.httpServerAutoStart = newValue } }
    }

    public var httpServerPort: Int {
        get { settings.httpServerPort ?? defaults.httpPort }
        set { update { $0.httpServerPort = newValue } }
    }

    public var hotkeysEnabled: Bool {
        get { settings.hotkeysEnabled ?? defaults.hotkeysEnabled }
        set { update { $0.hotkeysEnabled = newValue } }
    }

    public var hotkeyModifiers: HotkeyModifiers {
        get { settings.hotkeyModifiers ?? .controlOptionCommand }
        set { update { $0.hotkeyModifiers = newValue } }
    }

    /// "Don't show again" for the notice shown when the HTTP API is switched on.
    public var httpNoticeSuppressed: Bool {
        get { settings.httpNoticeSuppressed ?? false }
        set { update { $0.httpNoticeSuppressed = newValue } }
    }

    /// Off unless the user turns it on: the app makes no network requests on its own.
    public var automaticUpdateChecks: Bool {
        get { settings.automaticUpdateChecks ?? false }
        set { update { $0.automaticUpdateChecks = newValue } }
    }

    private func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        if unreadableFileInPlace {
            // If the file cannot be kept, leave it alone and keep this session's changes in memory.
            guard (try? FileManager.default.moveItem(at: fileURL, to: FileStorage.keptCopy(of: fileURL))) != nil else { return }
            unreadableFileInPlace = false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? FileStorage.writeProtected(data, to: fileURL)
        }
    }
}
