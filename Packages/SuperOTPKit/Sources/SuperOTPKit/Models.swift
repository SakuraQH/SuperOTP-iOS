import Foundation

/// Token types use CloudOTP's `token_type` indexes so backups stay compatible.
public enum OtpType: Int, CaseIterable, Codable, Sendable {
    case totp = 0
    case hotp = 1
    case motp = 2
    case steam = 3
    case yandex = 4
    case other = -1

    /// Only TOTP and HOTP can be generated; the other types are kept for round trips.
    public var isStandard: Bool { self == .totp || self == .hotp }

    public static func fromIndex(_ index: Int) -> OtpType {
        OtpType(rawValue: index) ?? .other
    }

    public var label: String {
        switch self {
        case .totp: return "TOTP"
        case .hotp: return "HOTP"
        case .motp: return "mOTP"
        case .steam: return "Steam"
        case .yandex: return "Yandex"
        case .other: return "OTP"
        }
    }
}

public enum OtpAlgorithm: String, CaseIterable, Codable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    public static func fromLabel(_ raw: String) -> OtpAlgorithm? {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "SHA1", "SHA-1": return .sha1
        case "SHA256", "SHA-256": return .sha256
        case "SHA512", "SHA-512": return .sha512
        default: return nil
        }
    }
}

public enum SortMode: String, CaseIterable, Sendable {
    case manual
    case name
    case created

    public static func from(_ raw: String) -> SortMode {
        SortMode(rawValue: raw) ?? .manual
    }
}

public struct OtpAccount: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var uid: String
    public var seq: Int
    public var issuer: String
    public var secret: String
    public var account: String
    public var imagePath: String
    public var type: OtpType
    public var algorithm: OtpAlgorithm
    public var digits: Int
    public var counter: Int
    public var period: Int
    public var pinned: Bool
    public var createdAt: Int
    public var editedAt: Int
    public var remark: String
    public var copyTimes: Int
    public var pin: String
    public var lastCopyAt: Int
    /// CloudOTP's free-form `description` field.
    public var note: String
    public var tags: String
    /// Groups the account belongs to; derived from the vault bindings, never stored on the row.
    public var categoryUids: [String]

    public init(
        id: Int = 0,
        uid: String,
        seq: Int = 0,
        issuer: String = "",
        secret: String,
        account: String = "",
        imagePath: String = "",
        type: OtpType = .totp,
        algorithm: OtpAlgorithm = .sha1,
        digits: Int = 6,
        counter: Int = 0,
        period: Int = 30,
        pinned: Bool = false,
        createdAt: Int = 0,
        editedAt: Int = 0,
        remark: String = "{}",
        copyTimes: Int = 0,
        pin: String = "",
        lastCopyAt: Int = 0,
        note: String = "",
        tags: String = "",
        categoryUids: [String] = []
    ) {
        self.id = id
        self.uid = uid
        self.seq = seq
        self.issuer = issuer
        self.secret = secret
        self.account = account
        self.imagePath = imagePath
        self.type = type
        self.algorithm = algorithm
        self.digits = digits
        self.counter = counter
        self.period = period
        self.pinned = pinned
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.remark = remark
        self.copyTimes = copyTimes
        self.pin = pin
        self.lastCopyAt = lastCopyAt
        self.note = note
        self.tags = tags
        self.categoryUids = categoryUids
    }
}

/// An account group. Stored as a CloudOTP "category" so backups stay compatible;
/// the app treats membership as one group per account.
public struct OtpCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var uid: String
    public var seq: Int
    public var title: String
    public var note: String
    public var createdAt: Int
    public var editedAt: Int
    public var pinned: Bool
    public var remark: String
    public var bindings: [String]

    public init(
        id: Int = 0,
        uid: String,
        seq: Int = 0,
        title: String,
        note: String = "",
        createdAt: Int = 0,
        editedAt: Int = 0,
        pinned: Bool = false,
        remark: String = "{}",
        bindings: [String] = []
    ) {
        self.id = id
        self.uid = uid
        self.seq = seq
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.pinned = pinned
        self.remark = remark
        self.bindings = bindings
    }
}

/// Milliseconds since 1970, the timestamp unit CloudOTP uses.
public func epochMillis(_ date: Date = Date()) -> Int {
    Int((date.timeIntervalSince1970 * 1000).rounded(.down))
}

private func nameOrder(_ left: String, _ right: String) -> ComparisonResult {
    left.compare(right, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: Locale.current)
}

public func sortAccounts(_ list: [OtpAccount], _ mode: SortMode) -> [OtpAccount] {
    list.sorted { a, b in
        if a.pinned != b.pinned { return a.pinned }
        switch mode {
        case .manual:
            if a.seq != b.seq { return a.seq < b.seq }
        case .name:
            let issuer = nameOrder(a.issuer, b.issuer)
            if issuer != .orderedSame { return issuer == .orderedAscending }
            let account = nameOrder(a.account, b.account)
            if account != .orderedSame { return account == .orderedAscending }
        case .created:
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        }
        return a.id < b.id
    }
}

/// Plain-text search over issuer and account name; secrets are never matched.
public func filterAccounts(_ list: [OtpAccount], _ query: String) -> [OtpAccount] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return list }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    return list.filter { item in
        item.issuer.range(of: q, options: options) != nil || item.account.range(of: q, options: options) != nil
    }
}

/// Key of the trailing home tab that collects accounts without a group.
public let otherTabKey = "@other"

public struct GroupTab: Hashable, Sendable {
    public let key: String
    public let group: OtpCategory?

    public init(key: String, group: OtpCategory?) {
        self.key = key
        self.group = group
    }

    public var isOther: Bool { group == nil }
}

public func sortGroups(_ groups: [OtpCategory]) -> [OtpCategory] {
    groups.sorted { a, b in
        if a.seq != b.seq { return a.seq < b.seq }
        return a.id > b.id
    }
}

/// The account's group, ignoring bindings that point at a group which no longer exists.
public func groupOf(_ account: OtpAccount, _ groups: [OtpCategory]) -> OtpCategory? {
    if account.categoryUids.isEmpty { return nil }
    return sortGroups(groups).first { account.categoryUids.contains($0.uid) }
}

public func isUngrouped(_ account: OtpAccount, _ groupUids: Set<String>) -> Bool {
    !account.categoryUids.contains { groupUids.contains($0) }
}

/// Home tabs: every group in its saved order (new groups come first), then "Other"
/// for ungrouped accounts. "Other" is only shown while at least one account has no group.
/// Without any group there are no tabs and the whole list is shown.
public func groupTabs(_ groups: [OtpCategory], _ accounts: [OtpAccount]) -> [GroupTab] {
    if groups.isEmpty { return [] }
    let tabs = sortGroups(groups).map { GroupTab(key: $0.uid, group: $0) }
    let uids = Set(groups.map(\.uid))
    if accounts.contains(where: { isUngrouped($0, uids) }) {
        return tabs + [GroupTab(key: otherTabKey, group: nil)]
    }
    return tabs
}

/// Falls back to the first tab when the remembered one is gone (deleted group, "Other" emptied).
public func resolveTab(_ tabs: [GroupTab], _ key: String?) -> GroupTab? {
    tabs.first { $0.key == key } ?? tabs.first
}

public func accountsInTab(_ list: [OtpAccount], _ tab: GroupTab?, _ groups: [OtpCategory]) -> [OtpAccount] {
    guard let tab else { return list }
    if tab.isOther {
        let uids = Set(groups.map(\.uid))
        return list.filter { isUngrouped($0, uids) }
    }
    return list.filter { $0.categoryUids.contains(tab.key) }
}

/// Applies a new order of a filtered subset to the full manual order: the subset keeps the
/// slots it already occupied, so accounts outside the current tab do not move.
public func mergeSubsetOrder(_ all: [Int], _ subset: [Int]) -> [Int] {
    let members = Set(subset)
    let allSet = Set(all)
    var queue = subset.filter { allSet.contains($0) }[...]
    return all.map { id in
        guard members.contains(id) else { return id }
        return queue.popFirst() ?? id
    }
}

/// Trimmed group name, or nil when it is blank or already taken (case-insensitive).
public func validGroupName(_ raw: String, _ groups: [OtpCategory], editingId: Int?, reserved: [String] = []) -> String? {
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty { return nil }
    let same: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame }
    let clash = groups.contains { $0.id != editingId && same($0.title) } || reserved.contains(where: same)
    return clash ? nil : title
}

public enum DisplayMode: String, CaseIterable, Sendable {
    case issuer
    case account
    case both

    public static func from(_ raw: String) -> DisplayMode {
        DisplayMode(rawValue: raw) ?? .both
    }
}

/// Title and optional subtitle for an account row.
public func displayLabels(_ account: OtpAccount, _ display: DisplayMode) -> (title: String, subtitle: String?) {
    let issuer = account.issuer.trimmingCharacters(in: .whitespaces)
    let name = account.account.trimmingCharacters(in: .whitespaces)
    switch display {
    case .issuer:
        return (issuer.isEmpty ? name : issuer, nil)
    case .account:
        return (name.isEmpty ? issuer : name, nil)
    case .both:
        if issuer.isEmpty { return (name, nil) }
        if name.isEmpty { return (issuer, nil) }
        return (issuer, name)
    }
}
