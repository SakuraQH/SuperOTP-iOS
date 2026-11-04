import CryptoKit
import Foundation
import SuperOTPKit

/// The account vault: a `VaultData` value kept in memory and persisted as one AES-256-GCM
/// sealed file. The key lives in the Keychain (this device only), so the file is useless
/// anywhere else; moving to a new device goes through encrypted backups instead.
@MainActor
final class VaultStore: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var accounts: [OtpAccount] = []
    @Published private(set) var categories: [OtpCategory] = []
    @Published private(set) var hasBackupPassword = false
    /// Set when the last write to disk failed; the change is still applied in memory.
    @Published var saveError: String?

    private var data = VaultData()
    private var key: SymmetricKey?

    private static let keyAccount = "vault-key"
    private static let backupPasswordAccount = "backup-password"

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SuperOTP", isDirectory: true)
    }

    private static var fileURL: URL { directory.appendingPathComponent("vault.bin") }

    var snapshot: VaultData { data }

    // MARK: Loading

    func loadIfNeeded() {
        if state != .ready { load() }
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            excludeFromBackup(Self.directory)
            let url = Self.fileURL
            let exists = FileManager.default.fileExists(atPath: url.path)
            if let stored = try Keychain.read(Self.keyAccount) {
                let key = SymmetricKey(data: stored)
                self.key = key
                if exists {
                    let blob = try Data(contentsOf: url)
                    let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key)
                    data = try JSONDecoder().decode(VaultData.self, from: plain)
                } else {
                    data = VaultData()
                }
            } else {
                if exists {
                    // The key is gone (for example after restoring a device backup): keep the
                    // unreadable file aside instead of overwriting it.
                    let aside = url.deletingLastPathComponent().appendingPathComponent("vault-orphaned-\(epochMillis()).bin")
                    try? FileManager.default.moveItem(at: url, to: aside)
                }
                let key = SymmetricKey(size: .bits256)
                try Keychain.write(key.withUnsafeBytes { Data($0) }, account: Self.keyAccount)
                self.key = key
                data = VaultData()
            }
            hasBackupPassword = (try? Keychain.read(Self.backupPasswordAccount))?.isEmpty == false
            publish()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Mutations (mirroring the Android Vault)

    @discardableResult
    func save(_ account: OtpAccount, groupUid: String?) -> OtpAccount {
        var stored = account
        mutate { stored = $0.save(account, groupUid: groupUid) }
        return stored
    }

    func delete(ids: [Int]) {
        let paths = accounts.filter { ids.contains($0.id) }.map(\.imagePath)
        mutate { $0.delete(ids: ids) }
        paths.forEach(IconStore.removeUserIcon)
    }

    func setPinned(ids: [Int], _ pinned: Bool) { mutate { $0.setPinned(ids: ids, pinned) } }
    func reorder(ids: [Int]) { mutate { $0.reorder(ids: ids) } }
    func moveToGroup(ids: [Int], groupUid: String?) { mutate { $0.moveToGroup(ids: ids, groupUid: groupUid) } }
    func removeFromGroup(ids: [Int], groupUid: String) { mutate { $0.removeFromGroup(ids: ids, groupUid: groupUid) } }
    func nextHotp(id: Int) { mutate { $0.nextHotp(id: id) } }

    func setImage(id: Int, imagePath: String) {
        let old = accounts.first { $0.id == id }?.imagePath
        mutate { $0.setImage(id: id, imagePath: imagePath) }
        if let old, old != imagePath { IconStore.removeUserIcon(old) }
    }

    @discardableResult
    func addGroup(title: String) -> OtpCategory {
        var group = OtpCategory(uid: "", title: title)
        mutate { group = $0.addGroup(title: title) }
        return group
    }

    func renameGroup(id: Int, title: String) { mutate { $0.renameGroup(id: id, title: title) } }
    func deleteGroup(id: Int) { mutate { $0.deleteGroup(id: id) } }
    func reorderGroups(ids: [Int]) { mutate { $0.reorderGroups(ids: ids) } }
    func commitImport(_ resolved: ResolvedImport) { mutate { $0.commitImport(resolved) } }

    // MARK: Backup password

    func backupPassword() -> String? {
        guard let stored = try? Keychain.read(Self.backupPasswordAccount), !stored.isEmpty else { return nil }
        return String(data: stored, encoding: .utf8)
    }

    func setBackupPassword(_ password: String) throws {
        try Keychain.write(Data(password.utf8), account: Self.backupPasswordAccount)
        hasBackupPassword = !password.isEmpty
    }

    // MARK: Internals

    private func mutate(_ change: (inout VaultData) -> Void) {
        var next = data
        change(&next)
        data = next
        publish()
        persist()
    }

    private func publish() {
        accounts = data.accounts
        categories = data.categories
    }

    private func persist() {
        guard let key else { return }
        do {
            let plain = try JSONEncoder().encode(data)
            let sealed = try AES.GCM.seal(plain, using: key)
            guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
            try combined.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
