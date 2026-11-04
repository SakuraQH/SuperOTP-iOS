import Foundation
import SuperOTPKit
import UIKit

struct BackupEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let modifiedAt: Date
    let size: Int
    /// iCloud Drive placeholder that has not been downloaded yet.
    let isPlaceholder: Bool

    var id: URL { url }
}

enum BackupError: LocalizedError {
    case noPassword
    case folderUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPassword: return String(localized: "Set a backup password first")
        case .folderUnavailable: return String(localized: "The backup folder is no longer available")
        case let .failed(message): return message
        }
    }
}

/// Encrypted backups in a folder: by default the app's own Documents/Backups (visible in
/// Files under "On My iPhone"), or any folder the user picks, such as one in iCloud Drive.
@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var entries: [BackupEntry]?
    @Published private(set) var folderName = ""
    @Published private(set) var isCustomFolder = false
    @Published private(set) var busy = false

    private let settings: AppSettings
    private let vault: VaultStore

    init(settings: AppSettings, vault: VaultStore) {
        self.settings = settings
        self.vault = vault
        updateFolderName()
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: Folder

    /// Stores a bookmark for a folder picked with the document picker.
    func useFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        settings.backupFolderBookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        updateFolderName()
        entries = nil
    }

    func useDefaultFolder() {
        settings.backupFolderBookmark = nil
        updateFolderName()
        entries = nil
    }

    private func updateFolderName() {
        if let url = resolveCustomFolder() {
            isCustomFolder = true
            folderName = FileManager.default.displayName(atPath: url.path)
        } else {
            isCustomFolder = false
            folderName = String(localized: "On My \(UIDevice.current.localizedModel)")
        }
    }

    private func resolveCustomFolder() -> URL? {
        guard let bookmark = settings.backupFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                settings.backupFolderBookmark = fresh
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    /// The folder to use plus whether it is security scoped (must be released after use).
    private func currentFolder() -> (url: URL, scoped: Bool)? {
        if settings.backupFolderBookmark != nil {
            guard let url = resolveCustomFolder() else { return nil }
            return (url, true)
        }
        let url = Self.defaultFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, false)
    }

    // MARK: Listing

    func refresh() async {
        guard let folder = currentFolder() else {
            entries = []
            return
        }
        let listed = await Task.detached(priority: .userInitiated) {
            BackupFiles.withAccess(folder.url, scoped: folder.scoped) { BackupFiles.list(folder.url) }
        }.value
        entries = listed
        updateFolderName()
    }

    // MARK: Writing

    /// Encrypts everything with the backup password and writes it to the backup folder.
    func backupNow() async throws {
        guard let password = vault.backupPassword() else { throw BackupError.noPassword }
        guard let folder = currentFolder() else { throw BackupError.folderUnavailable }
        busy = true
        defer { busy = false }
        let document = vault.snapshot.document(appVersion: appVersion)
        let keep = settings.backupKeep
        let name = CloudOtpBackup.backupFileName(epochMillis: epochMillis())
        try await Task.detached(priority: .userInitiated) {
            let data = try CloudOtpBackup.encrypt(document, password: password)
            try BackupFiles.withAccess(folder.url, scoped: folder.scoped) {
                try BackupFiles.write(data, to: folder.url.appendingPathComponent(name))
                BackupFiles.prune(folder.url, keep: keep)
            }
        }.value
        await refresh()
    }

    /// An encrypted backup as bytes, for exporting to a place the user picks.
    func exportData() async throws -> Data {
        guard let password = vault.backupPassword() else { throw BackupError.noPassword }
        busy = true
        defer { busy = false }
        let document = vault.snapshot.document(appVersion: appVersion)
        return try await Task.detached(priority: .userInitiated) {
            try CloudOtpBackup.encrypt(document, password: password)
        }.value
    }

    var exportFileName: String {
        CloudOtpBackup.backupFileName(epochMillis: epochMillis())
    }

    // MARK: Reading

    func read(_ entry: BackupEntry) async throws -> Data {
        guard let folder = currentFolder() else { throw BackupError.folderUnavailable }
        return try await Task.detached(priority: .userInitiated) {
            try BackupFiles.withAccess(folder.url, scoped: folder.scoped) { try BackupFiles.read(entry.url) }
        }.value
    }

    /// Reads a file picked with the document picker.
    static func readPicked(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try BackupFiles.withAccess(url, scoped: true) { try BackupFiles.read(url) }
        }.value
    }
}

/// File operations, coordinated so iCloud Drive and other providers stay consistent.
enum BackupFiles {
    static func withAccess<T>(_ url: URL, scoped: Bool, _ body: () throws -> T) rethrows -> T {
        let accessing = scoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func list(_ folder: URL) -> [BackupEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var coordinationError: NSError?
        var urls: [URL] = []
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.immediatelyAvailableMetadataOnly], error: &coordinationError) { url in
            urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        }
        return urls.compactMap { url -> BackupEntry? in
            var name = url.lastPathComponent
            var placeholder = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                placeholder = true
            }
            guard CloudOtpBackup.isBackupName(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return BackupEntry(
                url: placeholder ? folder.appendingPathComponent(name) : url,
                name: name,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0,
                isPlaceholder: placeholder
            )
        }
        .sorted { $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.name > $1.name }
    }

    static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { target in
            do {
                try data.write(to: target, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Deletes the oldest backups beyond `keep` (0 keeps everything).
    static func prune(_ folder: URL, keep: Int) {
        guard keep > 0 else { return }
        let all = list(folder)
        guard all.count > keep else { return }
        for entry in all.suffix(from: keep) {
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: entry.url, options: [.forDeleting], error: &coordinationError) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }
    }
}
