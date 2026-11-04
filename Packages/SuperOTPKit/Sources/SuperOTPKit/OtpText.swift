import Foundation

/// Result of parsing text that may hold several otpauth / migration links (one per line).
public struct ParsedBundle: Sendable {
    public var tokens: [OtpAccount]
    public var categories: [OtpCategory]
    public var invalid: Int

    public init(tokens: [OtpAccount], categories: [OtpCategory], invalid: Int) {
        self.tokens = tokens
        self.categories = categories
        self.invalid = invalid
    }
}

private enum LineResult {
    case accounts([OtpAccount])
    case categories([OtpCategory])
    case invalid
}

/// Parses `otpauth://`, Google Authenticator `otpauth-migration://` and CloudOTP
/// `cloudotpauth-migration://` links. Each non-empty line is one link.
public func parseImportText(_ text: String, now: Int = epochMillis()) -> ParsedBundle {
    var tokens: [OtpAccount] = []
    var categories: [OtpCategory] = []
    var invalid = 0
    let lines = text
        .components(separatedBy: CharacterSet.newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if lines.isEmpty { return ParsedBundle(tokens: [], categories: [], invalid: 1) }
    for line in lines {
        switch parseLine(line, now: now) {
        case let .accounts(items): tokens += items
        case let .categories(items): categories += items
        case .invalid: invalid += 1
        }
    }
    return ParsedBundle(tokens: tokens, categories: categories, invalid: invalid)
}

/// Returns the part after `prefix` when `text` starts with it (ASCII case-insensitive).
private func stripPrefix(_ text: String, _ prefix: String) -> String? {
    guard text.count >= prefix.count else { return nil }
    let head = text.prefix(prefix.count)
    guard head.lowercased() == prefix.lowercased() else { return nil }
    return String(text.dropFirst(prefix.count))
}

private func parseLine(_ line: String, now: Int) -> LineResult {
    if let query = stripPrefix(line, "otpauth-migration://offline?") {
        guard let data = queryValue(query, "data") else { return .invalid }
        let tokens = parseGoogleMigration(data, now: now)
        return tokens.isEmpty ? .invalid : .accounts(tokens)
    }
    if let query = stripPrefix(line, "cloudotpauth-migration://offline?") {
        if let raw = queryValue(query, "tokens") {
            let tokens = parseCloudTokens(raw, now: now)
            return tokens.isEmpty ? .invalid : .accounts(tokens)
        }
        if let raw = queryValue(query, "categories") {
            let categories = parseCloudCategories(raw, now: now)
            return categories.isEmpty ? .invalid : .categories(categories)
        }
        return .invalid
    }
    if let rest = stripPrefix(line, "otpauth://") {
        return parseOtpAuth(rest, now: now)
    }
    return .invalid
}

/// `rest` is everything after `otpauth://`: `type/label?query`.
private func parseOtpAuth(_ rest: String, now: Int) -> LineResult {
    guard let slash = rest.firstIndex(of: "/") else { return .invalid }
    let authority = rest[..<slash].lowercased()
    guard !authority.isEmpty, authority.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return .invalid }
    let afterSlash = rest[rest.index(after: slash)...]
    let rawPath: Substring
    let rawQuery: Substring
    if let mark = afterSlash.firstIndex(of: "?") {
        rawPath = afterSlash[..<mark]
        rawQuery = afterSlash[afterSlash.index(after: mark)...]
    } else {
        rawPath = afterSlash
        rawQuery = ""
    }
    let query = queryMap(String(rawQuery))
    guard let secret = query["secret"], !secret.trimmingCharacters(in: .whitespaces).isEmpty else { return .invalid }
    let type: OtpType
    if query["steam"] != nil || authority == "steam" {
        type = .steam
    } else {
        switch authority {
        case "motp": type = .motp
        case "yaotp", "yandex": type = .yandex
        case "hotp": type = .hotp
        case "totp": type = .totp
        default: return .invalid
        }
    }
    let algorithm: OtpAlgorithm
    if let raw = query["algorithm"], !raw.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let parsed = OtpAlgorithm.fromLabel(raw) else { return .invalid }
        algorithm = parsed
    } else {
        algorithm = .sha1
    }
    if type.isStandard && !isBase32(secret) { return .invalid }
    var path = percentDecode(String(rawPath))
    while path.hasPrefix("/") { path.removeFirst() }
    var issuerFromPath = ""
    var accountFromPath = path
    if let colon = path.firstIndex(of: ":") {
        issuerFromPath = String(path[..<colon])
        accountFromPath = String(path[path.index(after: colon)...])
    }
    let queryIssuer = query["issuer"]?.trimmingCharacters(in: .whitespaces) ?? ""
    let issuer = queryIssuer.isEmpty ? issuerFromPath : queryIssuer
    let digits = query["digits"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? (type == .steam ? 5 : 6)
    let period = query["period"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil } ?? 30
    let counter = query["counter"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    return .accounts([
        OtpAccount(
            uid: UUID().uuidString.lowercased(),
            issuer: issuer.trimmingCharacters(in: .whitespaces),
            secret: secret.replacingOccurrences(of: " ", with: ""),
            account: accountFromPath.trimmingCharacters(in: .whitespaces),
            imagePath: query["image"] ?? "",
            type: type,
            algorithm: algorithm,
            digits: digits,
            counter: max(0, counter),
            period: period,
            createdAt: now,
            editedAt: now
        ),
    ])
}

/// Standard `otpauth://` link for an account (contains the secret).
public func otpauthUri(_ account: OtpAccount) -> String {
    var label = ""
    if !account.issuer.isEmpty {
        label += account.issuer + ":"
    }
    label += account.account
    let type = account.type == .hotp ? "hotp" : "totp"
    var query = [
        "secret=" + percentEncode(account.secret.replacingOccurrences(of: " ", with: "")),
        "algorithm=" + account.algorithm.rawValue,
        "digits=\(account.digits)",
        "period=\(account.period)",
    ]
    if !account.issuer.isEmpty { query.append("issuer=" + percentEncode(account.issuer)) }
    if account.type == .hotp { query.append("counter=\(account.counter + 1)") }
    if !account.imagePath.isEmpty { query.append("image=" + percentEncode(account.imagePath)) }
    return "otpauth://\(type)/\(percentEncode(label))?" + query.joined(separator: "&")
}

// MARK: - Google Authenticator export

private func parseGoogleMigration(_ raw: String, now: Int) -> [OtpAccount] {
    guard let payload = decodeBase64Loose(raw), let fields = try? protoFields(payload) else { return [] }
    return fields.compactMap { field, value in
        guard field == 1, let data = value.data else { return nil }
        return googleToken(data, now: now)
    }
}

private func googleToken(_ data: [UInt8], now: Int) -> OtpAccount? {
    guard let fields = try? protoFields(data) else { return nil }
    var secret: [UInt8] = []
    var account = ""
    var issuer = ""
    var algorithm: UInt64 = 0
    var digits: UInt64 = 0
    var type: UInt64 = 0
    var counter: UInt64 = 0
    for (field, value) in fields {
        switch field {
        case 1: if let v = value.data { secret = v }
        case 2: if let v = value.text { account = v }
        case 3: if let v = value.text { issuer = v }
        case 4: if let v = value.uint { algorithm = v }
        case 5: if let v = value.uint { digits = v }
        case 6: if let v = value.uint { type = v }
        case 7: if let v = value.uint { counter = v }
        default: break
        }
    }
    let otpType: OtpType
    switch type {
    case 1: otpType = .hotp
    case 2: otpType = .totp
    default: return nil
    }
    let otpAlgorithm: OtpAlgorithm
    switch algorithm {
    case 0, 1: otpAlgorithm = .sha1
    case 2: otpAlgorithm = .sha256
    case 3: otpAlgorithm = .sha512
    default: return nil
    }
    if secret.isEmpty { return nil }
    let trimmedIssuer = issuer.trimmingCharacters(in: .whitespaces)
    return OtpAccount(
        uid: UUID().uuidString.lowercased(),
        issuer: trimmedIssuer.isEmpty ? account : issuer,
        secret: encodeBase32(secret),
        account: account,
        type: otpType,
        algorithm: otpAlgorithm,
        digits: digits == 2 ? 8 : 6,
        counter: otpType == .hotp ? Int(clamping: counter) : 0,
        period: 30,
        createdAt: now,
        editedAt: now
    )
}

// MARK: - CloudOTP export

private func parseCloudTokens(_ raw: String, now: Int) -> [OtpAccount] {
    guard let payload = decodeBase64Loose(raw), let fields = try? protoFields(payload) else { return [] }
    return fields.compactMap { field, value in
        guard field == 1, let data = value.data else { return nil }
        return cloudToken(data, now: now)
    }
}

private func cloudToken(_ data: [UInt8], now: Int) -> OtpAccount? {
    guard let fields = try? protoFields(data) else { return nil }
    var secret = ""
    var issuer = ""
    var account = ""
    var pin = ""
    var algorithm: UInt64 = 0
    var digits: UInt64 = 0
    var type: UInt64 = 0
    var period: UInt64 = 30
    var counter: UInt64 = 0
    var pinned: UInt64 = 0
    var copyTimes: UInt64 = 0
    var lastCopy: UInt64 = 0
    var image = ""
    var note = ""
    var remark = "{}"
    var uid = ""
    for (field, value) in fields {
        switch field {
        case 1: if let v = value.text { secret = v }
        case 2: if let v = value.text { issuer = v }
        case 3: if let v = value.text { account = v }
        case 4: if let v = value.text { pin = v }
        case 5: if let v = value.uint { algorithm = v }
        case 6: if let v = value.uint { digits = v }
        case 7: if let v = value.uint { type = v }
        case 8: if let v = value.uint { period = v }
        case 9: if let v = value.uint { counter = v }
        case 10: if let v = value.uint { pinned = v }
        case 11: if let v = value.uint { copyTimes = v }
        case 12: if let v = value.uint { lastCopy = v }
        case 13: if let v = value.text { image = v }
        case 14: if let v = value.text { note = v }
        case 15: if let v = value.text { remark = v.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : v }
        case 16: if let v = value.text { uid = v }
        default: break
        }
    }
    let otpType: OtpType
    switch type {
    case 1: otpType = .totp
    case 2: otpType = .hotp
    case 3: otpType = .motp
    case 4: otpType = .steam
    case 5: otpType = .yandex
    default: return nil
    }
    let otpAlgorithm: OtpAlgorithm
    switch algorithm {
    case 0, 1: otpAlgorithm = .sha1
    case 2: otpAlgorithm = .sha256
    case 3: otpAlgorithm = .sha512
    default: return nil
    }
    let digitCount: Int
    switch digits {
    case 1: digitCount = 5
    case 3: digitCount = 7
    case 4: digitCount = 8
    default: digitCount = 6
    }
    if otpType.isStandard && !isBase32(secret) { return nil }
    let periodValue = Int(clamping: period)
    return OtpAccount(
        uid: uid.trimmingCharacters(in: .whitespaces).isEmpty ? UUID().uuidString.lowercased() : uid,
        issuer: issuer,
        secret: secret,
        account: account,
        imagePath: image,
        type: otpType,
        algorithm: otpAlgorithm,
        digits: digitCount,
        counter: Int(clamping: counter),
        period: periodValue > 0 ? periodValue : 30,
        pinned: pinned == 1,
        createdAt: now,
        editedAt: now,
        remark: remark,
        copyTimes: Int(clamping: copyTimes),
        pin: pin,
        lastCopyAt: Int(clamping: lastCopy),
        note: note
    )
}

private func parseCloudCategories(_ raw: String, now: Int) -> [OtpCategory] {
    guard let payload = decodeBase64Loose(raw), let fields = try? protoFields(payload) else { return [] }
    return fields.compactMap { field, value in
        guard field == 1, let data = value.data else { return nil }
        return cloudCategory(data, now: now)
    }
}

private func cloudCategory(_ data: [UInt8], now: Int) -> OtpCategory? {
    guard let fields = try? protoFields(data) else { return nil }
    var title = ""
    var note = ""
    var remark = "{}"
    var uid = ""
    var bindings = ""
    var pinned = false
    var seq = 0
    for (field, value) in fields {
        switch field {
        case 2: if let v = value.text { title = v }
        case 3: if let v = value.text { note = v }
        case 5: if let v = value.text { remark = v.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : v }
        case 6: if let v = value.text { uid = v }
        case 7: if let v = value.text { bindings = v }
        case 8: if let v = value.uint { pinned = v != 0 }
        case 9: if let v = value.uint { seq = Int(Int64(bitPattern: v)) }
        default: break
        }
    }
    if title.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
    return OtpCategory(
        uid: uid.trimmingCharacters(in: .whitespaces).isEmpty ? UUID().uuidString.lowercased() : uid,
        seq: seq,
        title: title,
        note: note,
        createdAt: now,
        editedAt: now,
        pinned: pinned,
        remark: remark,
        bindings: splitList(bindings)
    )
}

// MARK: - URL helpers

func splitList(_ raw: String) -> [String] {
    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

public func queryValue(_ query: String, _ key: String) -> String? {
    queryMap(query)[key]
}

func queryMap(_ query: String) -> [String: String] {
    var map: [String: String] = [:]
    if query.isEmpty { return map }
    for part in query.split(separator: "&", omittingEmptySubsequences: true) {
        guard let eq = part.firstIndex(of: "=") else { continue }
        let key = percentDecode(String(part[..<eq]))
        let value = percentDecode(String(part[part.index(after: eq)...]))
        map[key] = value
    }
    return map
}

/// Decodes `%XX` escapes into UTF-8; `+` is kept as is (Base64 payloads rely on it).
public func percentDecode(_ raw: String) -> String {
    let input = Array(raw.utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(input.count)
    var i = 0
    while i < input.count {
        if input[i] == UInt8(ascii: "%"), i + 2 < input.count,
           let high = hexValue(input[i + 1]), let low = hexValue(input[i + 2]) {
            bytes.append(high << 4 | low)
            i += 3
            continue
        }
        bytes.append(input[i])
        i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
}

public func percentEncode(_ value: String) -> String {
    var out = ""
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
            out.append(Character(Unicode.Scalar(byte)))
        default:
            out += String(format: "%%%02X", UInt32(byte))
        }
    }
    return out
}

/// Standard or URL-safe Base64, with or without padding. Spaces are read as `+`
/// because some scanners turn an unescaped `+` in a link into a space.
func decodeBase64Loose(_ raw: String) -> [UInt8]? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "+")
    let remainder = text.count % 4
    if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
    if let data = Data(base64Encoded: text) { return Array(data) }
    let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if let data = Data(base64Encoded: standard) { return Array(data) }
    return nil
}
