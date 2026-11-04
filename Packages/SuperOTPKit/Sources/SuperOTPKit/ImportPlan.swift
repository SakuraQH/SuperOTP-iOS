import Foundation

public enum RowChoice: String, CaseIterable, Sendable {
    case add
    case skip
    case overwrite
}

public struct ImportRow: Identifiable, Sendable {
    public let id = UUID()
    public var account: OtpAccount
    public var existingId: Int?
    public var existingUid: String?
    public var existingSeq: Int?

    public init(account: OtpAccount, existingId: Int? = nil, existingUid: String? = nil, existingSeq: Int? = nil) {
        self.account = account
        self.existingId = existingId
        self.existingUid = existingUid
        self.existingSeq = existingSeq
    }

    public var isNew: Bool { existingId == nil }
}

public struct PreparedImport: Identifiable, Sendable {
    public let id = UUID()
    public var rows: [ImportRow]
    public var categories: [OtpCategory]
    public var skippedOtherTypes: Int
    public var invalid: Int

    public init(rows: [ImportRow], categories: [OtpCategory], skippedOtherTypes: Int, invalid: Int) {
        self.rows = rows
        self.categories = categories
        self.skippedOtherTypes = skippedOtherTypes
        self.invalid = invalid
    }

    /// Nothing was recognised at all (as opposed to "recognised but unsupported").
    public var isEmpty: Bool {
        rows.isEmpty && categories.isEmpty && skippedOtherTypes == 0 && invalid == 0
    }

    /// Default choice per row: add new accounts, skip ones that are already on the device.
    public var defaultChoices: [RowChoice] {
        rows.map { $0.isNew ? .add : .skip }
    }
}

public struct ResolvedImport: Sendable {
    public var upserts: [OtpAccount]
    public var categories: [OtpCategory]

    public init(upserts: [OtpAccount], categories: [OtpCategory]) {
        self.upserts = upserts
        self.categories = categories
    }
}

/// Same issuer, account name and (normalised) secret.
public func sameIdentity(_ left: OtpAccount, _ right: OtpAccount) -> Bool {
    left.issuer.trimmingCharacters(in: .whitespaces) == right.issuer.trimmingCharacters(in: .whitespaces) &&
        left.account.trimmingCharacters(in: .whitespaces) == right.account.trimmingCharacters(in: .whitespaces) &&
        normalizeSecret(left.secret) == normalizeSecret(right.secret)
}

public func prepareImport(tokens: [OtpAccount], categories: [OtpCategory], existing: [OtpAccount], invalid: Int = 0) -> PreparedImport {
    let standard = tokens.filter { $0.type.isStandard }
    let rows = standard.map { token -> ImportRow in
        guard let match = existing.first(where: { sameIdentity($0, token) }) else { return ImportRow(account: token) }
        return ImportRow(account: token, existingId: match.id, existingUid: match.uid, existingSeq: match.seq)
    }
    return PreparedImport(rows: rows, categories: categories, skippedOtherTypes: tokens.count - standard.count, invalid: invalid)
}

public func resolveImport(rows: [ImportRow], choices: [RowChoice], categories: [OtpCategory]) -> ResolvedImport {
    precondition(rows.count == choices.count)
    var uidMap: [String: String] = [:]
    var upserts: [OtpAccount] = []
    for (index, row) in rows.enumerated() {
        switch choices[index] {
        case .add:
            var stored = row.account
            stored.id = 0
            if !row.isNew { stored.uid = UUID().uuidString.lowercased() }
            uidMap[row.account.uid] = stored.uid
            upserts.append(stored)
        case .skip:
            if let existingUid = row.existingUid { uidMap[row.account.uid] = existingUid }
        case .overwrite:
            if let existingUid = row.existingUid, let existingId = row.existingId {
                uidMap[row.account.uid] = existingUid
                var stored = row.account
                stored.id = existingId
                stored.uid = existingUid
                stored.seq = row.existingSeq ?? row.account.seq
                upserts.append(stored)
            }
        }
    }
    let mapped = categories.map { category -> OtpCategory in
        var copy = category
        var seen = Set<String>()
        copy.bindings = category.bindings.compactMap { uidMap[$0] }.filter { seen.insert($0).inserted }
        return copy
    }
    return ResolvedImport(upserts: upserts, categories: mapped)
}
