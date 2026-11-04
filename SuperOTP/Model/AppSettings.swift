import SuperOTPKit
import SwiftUI

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension DisplayMode {
    var label: LocalizedStringKey {
        switch self {
        case .issuer: return "Service Only"
        case .account: return "Account Only"
        case .both: return "Service and Account"
        }
    }
}

extension SortMode {
    var label: LocalizedStringKey {
        switch self {
        case .manual: return "Manual Order"
        case .name: return "Name"
        case .created: return "Date Added"
        }
    }
}

/// User preferences, persisted in UserDefaults (nothing secret lives here).
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    @Published var display: DisplayMode { didSet { defaults.set(display.rawValue, forKey: Keys.display) } }
    @Published var tapToCopy: Bool { didSet { defaults.set(tapToCopy, forKey: Keys.tapToCopy) } }
    @Published var hideCodes: Bool { didSet { defaults.set(hideCodes, forKey: Keys.hideCodes) } }
    /// Seconds before a copied code is removed from the clipboard; 0 keeps it.
    @Published var clipboardTimeout: Int { didSet { defaults.set(clipboardTimeout, forKey: Keys.clipboardTimeout) } }
    @Published var appLock: Bool { didSet { defaults.set(appLock, forKey: Keys.appLock) } }
    /// Seconds in the background before the app locks again; 0 locks immediately.
    @Published var lockTimeout: Int { didSet { defaults.set(lockTimeout, forKey: Keys.lockTimeout) } }
    @Published var sort: SortMode { didSet { defaults.set(sort.rawValue, forKey: Keys.sort) } }
    @Published var lastTab: String? { didSet { defaults.set(lastTab, forKey: Keys.lastTab) } }
    /// Backups to keep in the folder; 0 keeps all of them.
    @Published var backupKeep: Int { didSet { defaults.set(backupKeep, forKey: Keys.backupKeep) } }
    @Published var backupOnLaunch: Bool { didSet { defaults.set(backupOnLaunch, forKey: Keys.backupOnLaunch) } }
    /// Bookmark of a folder the user picked; nil means the app's own Documents/Backups.
    @Published var backupFolderBookmark: Data? { didSet { defaults.set(backupFolderBookmark, forKey: Keys.backupFolder) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.tapToCopy: true,
            Keys.hideCodes: true,
            Keys.clipboardTimeout: 60,
            Keys.backupKeep: 10,
        ])
        theme = ThemeChoice(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        display = DisplayMode.from(defaults.string(forKey: Keys.display) ?? "")
        tapToCopy = defaults.bool(forKey: Keys.tapToCopy)
        hideCodes = defaults.bool(forKey: Keys.hideCodes)
        clipboardTimeout = defaults.integer(forKey: Keys.clipboardTimeout)
        appLock = defaults.bool(forKey: Keys.appLock)
        lockTimeout = defaults.integer(forKey: Keys.lockTimeout)
        sort = SortMode.from(defaults.string(forKey: Keys.sort) ?? "")
        lastTab = defaults.string(forKey: Keys.lastTab)
        backupKeep = defaults.integer(forKey: Keys.backupKeep)
        backupOnLaunch = defaults.bool(forKey: Keys.backupOnLaunch)
        backupFolderBookmark = defaults.data(forKey: Keys.backupFolder)
    }

    private enum Keys {
        static let theme = "theme"
        static let display = "display"
        static let tapToCopy = "tapToCopy"
        static let hideCodes = "hideCodes"
        static let clipboardTimeout = "clipboardTimeout"
        static let appLock = "appLock"
        static let lockTimeout = "lockTimeout"
        static let sort = "sort"
        static let lastTab = "lastTab"
        static let backupKeep = "backupKeep"
        static let backupOnLaunch = "backupOnLaunch"
        static let backupFolder = "backupFolderBookmark"
    }
}
