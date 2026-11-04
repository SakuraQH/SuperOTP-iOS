import Foundation

/// Membership of an account in a category (CloudOTP keeps these as a separate table).
public struct VaultBinding: Hashable, Codable, Sendable {
    public var categoryUid: String
    public var accountUid: String

    public init(categoryUid: String, accountUid: String) {
        self.categoryUid = categoryUid
        self.accountUid = accountUid
    }
}

/// Everything the app stores, as one value. The app persists it encrypted; all mutations
/// live here so they can be unit tested without storage.
public struct VaultData: Codable, Equatable, Sendable {
    public var version = 1
    /// Rows as stored; `categoryUids` is always empty here (see `accounts`).
    public private(set) var accountRows: [OtpAccount] = []
    public private(set) var categoryRows: [OtpCategory] = []
    public private(set) var bindings: [VaultBinding] = []
    public private(set) var nextAccountId = 1
    public private(set) var nextCategoryId = 1

    public init() {}

    // MARK: Reading

    /// Accounts by id, each with the uids of the groups it is bound to.
    public var accounts: [OtpAccount] {
        var byAccount: [String: [String]] = [:]
        for binding in bindings { byAccount[binding.accountUid, default: []].append(binding.categoryUid) }
        return accountRows.sorted { $0.id < $1.id }.map { row in
            var copy = row
            copy.categoryUids = byAccount[row.uid] ?? []
            return copy
        }
    }

    /// Categories in tab order, each with the uids of its bound accounts.
    public var categories: [OtpCategory] {
        var byCategory: [String: [String]] = [:]
        for binding in bindings { byCategory[binding.categoryUid, default: []].append(binding.accountUid) }
        return categoryRows
            .sorted { $0.seq != $1.seq ? $0.seq < $1.seq : $0.id < $1.id }
            .map { row in
                var copy = row
                copy.bindings = byCategory[row.uid] ?? []
                return copy
            }
    }

    public func account(id: Int) -> OtpAccount? {
        accounts.first { $0.id == id }
    }

    var maxSeq: Int { accountRows.map(\.seq).max() ?? 0 }
    var minCategorySeq: Int { categoryRows.map(\.seq).min() ?? 0 }

    // MARK: Accounts

    /// Inserts with a fresh id; a uid that is already taken is replaced by a new one.
    @discardableResult
    public mutating func insert(_ account: OtpAccount) -> OtpAccount {
        var stored = account
        var uid = stored.uid.isBlank ? newUid() : stored.uid
        while accountRows.contains(where: { $0.uid == uid }) { uid = newUid() }
        stored.uid = uid
        stored.id = nextAccountId
        stored.categoryUids = []
        nextAccountId += 1
        accountRows.append(stored)
        return stored
    }

    public mutating func update(_ account: OtpAccount) {
        guard let index = accountRows.firstIndex(where: { $0.id == account.id }) else { return }
        var stored = account
        stored.categoryUids = []
        accountRows[index] = stored
    }

    /// Adds (id == 0) or updates an account and puts it into `groupUid` (nil = no group).
    @discardableResult
    public mutating func save(_ account: OtpAccount, groupUid: String?, now: Int = epochMillis()) -> OtpAccount {
        let stored: OtpAccount
        if account.id == 0 {
            var draft = account
            if draft.imagePath.isEmpty { draft.imagePath = BrandIcons.matchFile(draft.issuer) ?? "" }
            draft.seq = maxSeq + 1
            draft.createdAt = now
            draft.editedAt = now
            stored = insert(draft)
        } else {
            var draft = account
            draft.editedAt = now
            update(draft)
            stored = draft
        }
        replaceCategories(accountUids: [stored.uid], categoryUids: groupUid.map { [$0] } ?? [])
        return stored
    }

    public mutating func delete(ids: [Int]) {
        let idSet = Set(ids)
        let uids = Set(accountRows.filter { idSet.contains($0.id) }.map(\.uid))
        bindings.removeAll { uids.contains($0.accountUid) }
        accountRows.removeAll { idSet.contains($0.id) }
    }

    public mutating func setPinned(ids: [Int], _ pinned: Bool) {
        let idSet = Set(ids)
        for index in accountRows.indices where idSet.contains(accountRows[index].id) {
            accountRows[index].pinned = pinned
        }
    }

    /// Manual order: `ids[i]` gets `seq = i`.
    public mutating func reorder(ids: [Int]) {
        var position: [Int: Int] = [:]
        for (index, id) in ids.enumerated() { position[id] = index }
        for index in accountRows.indices {
            if let seq = position[accountRows[index].id] { accountRows[index].seq = seq }
        }
    }

    public mutating func nextHotp(id: Int, now: Int = epochMillis()) {
        guard let index = accountRows.firstIndex(where: { $0.id == id }), accountRows[index].type == .hotp else { return }
        accountRows[index].counter += 1
        accountRows[index].editedAt = now
    }

    public mutating func setImage(id: Int, imagePath: String, now: Int = epochMillis()) {
        guard let index = accountRows.firstIndex(where: { $0.id == id }) else { return }
        accountRows[index].imagePath = imagePath
        accountRows[index].editedAt = now
    }

    // MARK: Groups

    /// Moves accounts into `groupUid` (an account belongs to one group); nil makes them ungrouped.
    public mutating func moveToGroup(ids: [Int], groupUid: String?) {
        let idSet = Set(ids)
        let uids = accountRows.filter { idSet.contains($0.id) }.map(\.uid)
        replaceCategories(accountUids: uids, categoryUids: groupUid.map { [$0] } ?? [])
    }

    public mutating func removeFromGroup(ids: [Int], groupUid: String) {
        let idSet = Set(ids)
        let uids = Set(accountRows.filter { idSet.contains($0.id) }.map(\.uid))
        bindings.removeAll { $0.categoryUid == groupUid && uids.contains($0.accountUid) }
    }

    /// Creates a group at the front of the tab order.
    @discardableResult
    public mutating func addGroup(title: String, now: Int = epochMillis()) -> OtpCategory {
        insertCategory(OtpCategory(
            uid: newUid(),
            seq: minCategorySeq - 1,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            editedAt: now
        ))
    }

    public mutating func renameGroup(id: Int, title: String, now: Int = epochMillis()) {
        guard let index = categoryRows.firstIndex(where: { $0.id == id }) else { return }
        categoryRows[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        categoryRows[index].editedAt = now
    }

    /// Deletes the group only; its accounts become ungrouped.
    public mutating func deleteGroup(id: Int) {
        guard let index = categoryRows.firstIndex(where: { $0.id == id }) else { return }
        let uid = categoryRows[index].uid
        bindings.removeAll { $0.categoryUid == uid }
        categoryRows.remove(at: index)
    }

    public mutating func reorderGroups(ids: [Int]) {
        var position: [Int: Int] = [:]
        for (index, id) in ids.enumerated() { position[id] = index }
        for index in categoryRows.indices {
            if let seq = position[categoryRows[index].id] { categoryRows[index].seq = seq }
        }
    }

    // MARK: Import

    public mutating func commitImport(_ resolved: ResolvedImport) {
        for account in resolved.upserts {
            var stored = account
            if stored.imagePath.isEmpty { stored.imagePath = BrandIcons.matchFile(stored.issuer) ?? "" }
            if stored.id == 0 { insert(stored) } else { update(stored) }
        }
        for category in resolved.categories { mergeCategory(category) }
    }

    /// Matches by uid, then by title; new categories are inserted. Bindings are added, never removed.
    mutating func mergeCategory(_ category: OtpCategory) {
        let byUid: OtpCategory? = category.uid.isBlank ? nil : categoryRows.first(where: { $0.uid == category.uid })
        let byTitle: OtpCategory? = category.title.isBlank ? nil : categoryRows.first(where: { $0.title == category.title })
        let existing = byUid ?? byTitle
        guard let existing else {
            let inserted = insertCategory(category)
            for accountUid in category.bindings { bind(categoryUid: inserted.uid, accountUid: accountUid) }
            return
        }
        if byUid != nil, let index = categoryRows.firstIndex(where: { $0.id == existing.id }) {
            if !category.title.isBlank { categoryRows[index].title = category.title }
            categoryRows[index].note = category.note
            categoryRows[index].pinned = category.pinned
            categoryRows[index].remark = category.remark
            categoryRows[index].editedAt = category.editedAt
        }
        for accountUid in category.bindings { bind(categoryUid: existing.uid, accountUid: accountUid) }
    }

    /// Everything as a backup document (`tokens` carry ids so CloudOTP can keep them).
    public func document(appVersion: String, sourceDevice: String = "SuperOTP", now: Int = epochMillis()) -> BackupDocument {
        BackupDocument(
            schemaVersion: CloudOtpBackup.schema,
            createdAt: now,
            appVersion: appVersion,
            sourceDevice: sourceDevice,
            tokens: accounts,
            categories: categories
        )
    }

    // MARK: Internals

    @discardableResult
    mutating func insertCategory(_ category: OtpCategory) -> OtpCategory {
        var stored = category
        var uid = stored.uid.isBlank ? newUid() : stored.uid
        while categoryRows.contains(where: { $0.uid == uid }) { uid = newUid() }
        stored.uid = uid
        stored.id = nextCategoryId
        stored.bindings = []
        nextCategoryId += 1
        categoryRows.append(stored)
        return stored
    }

    mutating func replaceCategories(accountUids: [String], categoryUids: [String]) {
        let targets = Set(accountUids)
        bindings.removeAll { targets.contains($0.accountUid) }
        var seen = Set<String>()
        let unique = categoryUids.filter { seen.insert($0).inserted }
        for accountUid in accountUids {
            for categoryUid in unique { bind(categoryUid: categoryUid, accountUid: accountUid) }
        }
    }

    mutating func bind(categoryUid: String, accountUid: String) {
        let binding = VaultBinding(categoryUid: categoryUid, accountUid: accountUid)
        if !bindings.contains(binding) { bindings.append(binding) }
    }

    private func newUid() -> String {
        UUID().uuidString.lowercased()
    }
}
