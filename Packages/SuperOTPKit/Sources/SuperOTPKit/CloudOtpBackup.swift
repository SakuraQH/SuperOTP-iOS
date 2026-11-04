import CArgon2
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum BackupFailure: Error, Equatable, Sendable {
    case emptyPassword
    case notBackup
    case badPassword
    case unsupportedVersion
    case badFormat(String)
}

public struct BackupDocument: Equatable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Int
    public var appVersion: String
    public var sourceDevice: String
    public var tokens: [OtpAccount]
    public var categories: [OtpCategory]

    public init(schemaVersion: Int, createdAt: Int, appVersion: String, sourceDevice: String, tokens: [OtpAccount], categories: [OtpCategory]) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.sourceDevice = sourceDevice
        self.tokens = tokens
        self.categories = categories
    }
}

/// CloudOTP-compatible encrypted backup (`CloudOTP-Backup-Encrypt-V01`):
/// header || salt(16) || iv(12) || AES-256-GCM(ciphertext || tag), keyed with Argon2id.
public enum CloudOtpBackup {
    public static let header = "CloudOTP-Backup-Encrypt-V01"
    public static let schema = 2
    public static let iterations: UInt32 = 3
    public static let memoryKiB: UInt32 = 65536
    public static let saltLength = 16
    public static let ivLength = 12
    public static let keyLength = 32
    public static let maxTokens = 50000
    public static let maxCategories = 10000
    public static let maxBindings = 500_000

    // MARK: JSON

    public static func toJson(_ document: BackupDocument) -> String {
        let bindingCount = document.categories.reduce(0) { $0 + $1.bindings.count }
        let json = JSONWriter()
        json.object {
            json.field("schemaVersion", document.schemaVersion)
            json.field("createdAt", document.createdAt)
            json.field("appVersion", document.appVersion)
            json.field("sourceDevice", document.sourceDevice)
            json.field("tokenCount", document.tokens.count)
            json.field("categoryCount", document.categories.count)
            json.field("bindingCount", bindingCount)
            json.key("tokens")
            json.array(document.tokens) { token in tokenJson(token, into: json) }
            json.key("categories")
            json.array(document.categories) { category in categoryJson(category, into: json) }
        }
        return json.text
    }

    public static func parse(_ text: String) throws -> BackupDocument {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw BackupFailure.badFormat("root")
        }
        let schema = try root.int("schemaVersion", default: 1)
        if schema < 1 { throw BackupFailure.badFormat("schemaVersion") }
        if schema > CloudOtpBackup.schema { throw BackupFailure.unsupportedVersion }
        let tokenData = try root.array("tokens")
        let categoryData = try root.array("categories")
        if tokenData.count > maxTokens { throw BackupFailure.badFormat("tokens") }
        if categoryData.count > maxCategories { throw BackupFailure.badFormat("categories") }
        let tokens = try tokenData.map { try parseToken(entryObject($0, "token")) }
        let categories = try categoryData.map { try parseCategory(entryObject($0, "category")) }
        let bindingCount = categories.reduce(0) { $0 + $1.bindings.count }
        if bindingCount > maxBindings { throw BackupFailure.badFormat("bindings") }
        try checkCount(root, "tokenCount", tokens.count)
        try checkCount(root, "categoryCount", categories.count)
        try checkCount(root, "bindingCount", bindingCount)
        return BackupDocument(
            schemaVersion: schema,
            createdAt: try root.long("createdAt", default: 0),
            appVersion: root.string("appVersion", default: ""),
            sourceDevice: root.string("sourceDevice", default: ""),
            tokens: tokens,
            categories: categories
        )
    }

    // MARK: Encryption

    public static func encrypt(_ document: BackupDocument, password: String, salt: [UInt8]? = nil, iv: [UInt8]? = nil) throws -> Data {
        if password.isEmpty { throw BackupFailure.emptyPassword }
        let salt = salt ?? randomBytes(saltLength)
        let iv = iv ?? randomBytes(ivLength)
        precondition(salt.count == saltLength && iv.count == ivLength)
        let key = try deriveKey(password: password, salt: salt)
        let plain = Data(toJson(document).utf8)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
        var out = Data(header.utf8)
        out.append(contentsOf: salt)
        out.append(contentsOf: iv)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public static func decrypt(_ data: Data, password: String) throws -> BackupDocument {
        if password.isEmpty { throw BackupFailure.emptyPassword }
        let bytes = [UInt8](data)
        let head = Array(header.utf8)
        guard bytes.count >= head.count + saltLength + ivLength + 16, Array(bytes[0..<head.count]) == head else {
            throw BackupFailure.notBackup
        }
        let saltStart = head.count
        let ivStart = saltStart + saltLength
        let bodyStart = ivStart + ivLength
        let salt = Array(bytes[saltStart..<ivStart])
        let iv = Array(bytes[ivStart..<bodyStart])
        let body = Array(bytes[bodyStart...])
        let plain: Data
        do {
            let key = try deriveKey(password: password, salt: salt)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: Data(body[0..<(body.count - 16)]),
                tag: Data(body[(body.count - 16)...])
            )
            plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw BackupFailure.badPassword
        }
        guard let text = String(data: plain, encoding: .utf8) else { throw BackupFailure.badPassword }
        do {
            return try parse(text)
        } catch BackupFailure.unsupportedVersion {
            throw BackupFailure.unsupportedVersion
        } catch {
            throw BackupFailure.badFormat("payload")
        }
    }

    /// CloudOTP BackupEncryptionV1: Argon2id v1.3, t=3, m=65536 KiB, p=1, 32-byte key, empty secret / ad.
    public static func deriveKey(password: String, salt: [UInt8]) throws -> [UInt8] {
        try argon2id(password: Array(password.utf8), salt: salt, iterations: iterations, memoryKiB: memoryKiB, lanes: 1, length: keyLength)
    }

    public static func backupFileName(epochMillis: Int, device: String = "SuperOTP", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let date = Date(timeIntervalSince1970: Double(epochMillis) / 1000)
        let stamp = formatter.string(from: date)
        let micros = String(((epochMillis % 1000) + 1000) % 1000 * 1000)
        let fraction = String(repeating: "0", count: max(0, 6 - micros.count)) + micros
        let trimmed = device.trimmingCharacters(in: .whitespaces)
        let safeDevice = String((trimmed.isEmpty ? "SuperOTP" : trimmed).map { char -> Character in
            char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "_" || char == "-") ? char : "_"
        })
        return "SuperOTP-Backup-\(stamp)-\(fraction)-\(safeDevice).bin"
    }

    public static func isBackupName(_ name: String) -> Bool {
        let file = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
        return file.hasSuffix(".bin") && (file.hasPrefix("SuperOTP-Backup-") || file.hasPrefix("CloudOTP-Backup-"))
    }

    // MARK: Entries

    private static func tokenJson(_ account: OtpAccount, into json: JSONWriter) {
        json.object {
            json.field("id", account.id)
            json.field("uid", account.uid)
            json.field("seq", account.seq)
            json.field("issuer", account.issuer)
            json.field("secret", account.secret)
            json.field("account", account.account)
            json.field("image_path", account.imagePath)
            json.field("token_type", account.type.rawValue)
            json.field("algorithm", account.algorithm.rawValue)
            json.field("digits", account.digits)
            json.field("counter", account.counter)
            json.field("period", account.period)
            json.field("pinned", account.pinned ? 1 : 0)
            json.field("create_timestamp", account.createdAt)
            json.field("edit_timestamp", account.editedAt)
            json.field("remark", account.remark.isBlank ? "{}" : account.remark)
            json.field("copy_times", account.copyTimes)
            json.field("pin", account.pin)
            json.field("last_copy_timestamp", account.lastCopyAt)
            json.field("description", account.note)
            json.field("tags", account.tags)
        }
    }

    private static func categoryJson(_ category: OtpCategory, into json: JSONWriter) {
        json.object {
            json.field("id", category.id)
            json.field("uid", category.uid)
            json.field("seq", category.seq)
            json.field("title", category.title)
            json.field("description", category.note)
            json.field("create_timestamp", category.createdAt)
            json.field("edit_timestamp", category.editedAt)
            json.field("pinned", category.pinned ? 1 : 0)
            json.field("remark", category.remark.isBlank ? "{}" : category.remark)
            json.field("bindings", category.bindings.joined(separator: ","))
        }
    }

    private static func parseToken(_ map: [String: Any]) throws -> OtpAccount {
        guard let algorithm = OtpAlgorithm.fromLabel(try map.requiredString("algorithm")) else {
            throw BackupFailure.badFormat("algorithm")
        }
        let uid = map.string("uid", default: "")
        return OtpAccount(
            id: try map.long("id"),
            uid: uid.isBlank ? UUID().uuidString.lowercased() : uid,
            seq: try map.int("seq", default: 0),
            issuer: map.string("issuer", default: ""),
            secret: try map.requiredString("secret"),
            account: map.string("account", default: ""),
            imagePath: map.string("image_path", default: ""),
            type: OtpType.fromIndex(try map.int("token_type")),
            algorithm: algorithm,
            digits: try map.int("digits"),
            counter: try map.long("counter"),
            period: try map.int("period"),
            pinned: map.flag("pinned"),
            createdAt: try map.long("create_timestamp", default: 0),
            editedAt: try map.long("edit_timestamp", default: 0),
            remark: map.remark("remark"),
            copyTimes: try map.int("copy_times", default: 0),
            pin: map.string("pin", default: ""),
            lastCopyAt: try map.long("last_copy_timestamp", default: 0),
            note: map.string("description", default: ""),
            tags: map.string("tags", default: "")
        )
    }

    private static func parseCategory(_ map: [String: Any]) throws -> OtpCategory {
        let uid = map.string("uid", default: "")
        return OtpCategory(
            id: try map.long("id", default: 0),
            uid: uid.isBlank ? UUID().uuidString.lowercased() : uid,
            seq: try map.int("seq", default: 0),
            title: try map.requiredString("title"),
            note: map.string("description", default: ""),
            createdAt: try map.long("create_timestamp", default: 0),
            editedAt: try map.long("edit_timestamp", default: 0),
            pinned: map.flag("pinned"),
            remark: map.remark("remark"),
            bindings: splitList(map.string("bindings", default: ""))
        )
    }

    /// CloudOTP legacy backups store each token / category as a JSON string, not an object.
    private static func entryObject(_ element: Any, _ field: String) throws -> [String: Any] {
        if let object = element as? [String: Any] { return object }
        if let text = element as? String,
           let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        throw BackupFailure.badFormat(field)
    }

    private static func checkCount(_ root: [String: Any], _ key: String, _ actual: Int) throws {
        guard root[key] != nil else { return }
        if try root.int(key) != actual { throw BackupFailure.badFormat(key) }
    }
}

public enum Argon2Error: Error {
    case invalidParameters
    case outOfMemory
}

/// Argon2id (v1.3). Memory-hard: call it off the main thread.
public func argon2id(
    password: [UInt8],
    salt: [UInt8],
    secret: [UInt8] = [],
    associatedData: [UInt8] = [],
    iterations: UInt32,
    memoryKiB: UInt32,
    lanes: UInt32,
    length: Int
) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: length)
    let status = password.withUnsafeBufferPointer { pwd in
        salt.withUnsafeBufferPointer { saltBuffer in
            secret.withUnsafeBufferPointer { secretBuffer in
                associatedData.withUnsafeBufferPointer { adBuffer in
                    out.withUnsafeMutableBufferPointer { outBuffer in
                        superotp_argon2id(
                            pwd.baseAddress, pwd.count,
                            saltBuffer.baseAddress, saltBuffer.count,
                            secretBuffer.baseAddress, secretBuffer.count,
                            adBuffer.baseAddress, adBuffer.count,
                            iterations, memoryKiB, lanes,
                            outBuffer.baseAddress, outBuffer.count
                        )
                    }
                }
            }
        }
    }
    switch status {
    case 0: return out
    case -2: throw Argon2Error.outOfMemory
    default: throw Argon2Error.invalidParameters
    }
}

public func blake2b(_ input: [UInt8], length: Int = 64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: length)
    _ = input.withUnsafeBufferPointer { inBuffer in
        out.withUnsafeMutableBufferPointer { outBuffer in
            superotp_blake2b(outBuffer.baseAddress, outBuffer.count, inBuffer.baseAddress, inBuffer.count)
        }
    }
    return out
}

func randomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Lenient JSON accessors (numbers may arrive as strings, flags as 0/1/true)

private extension Dictionary where Key == String, Value == Any {
    func array(_ key: String) throws -> [Any] {
        guard let value = self[key], !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else { throw BackupFailure.badFormat(key) }
        return list
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = self[key], let text = scalarText(value) else { throw BackupFailure.badFormat(key) }
        return text
    }

    func string(_ key: String, default fallback: String) -> String {
        guard let value = self[key], let text = scalarText(value) else { return fallback }
        return text
    }

    func long(_ key: String) throws -> Int {
        guard let value = self[key] else { throw BackupFailure.badFormat(key) }
        if let text = value as? String {
            guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { throw BackupFailure.badFormat(key) }
            return number
        }
        if let number = value as? NSNumber, !isBoolean(number) {
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), abs(double) < 9.2e18 else { throw BackupFailure.badFormat(key) }
            return number.intValue
        }
        throw BackupFailure.badFormat(key)
    }

    func long(_ key: String, default fallback: Int) throws -> Int {
        guard self[key] != nil else { return fallback }
        return try long(key)
    }

    func int(_ key: String) throws -> Int {
        let value = try long(key)
        guard value >= Int(Int32.min), value <= Int(Int32.max) else { throw BackupFailure.badFormat(key) }
        return value
    }

    func int(_ key: String, default fallback: Int) throws -> Int {
        guard self[key] != nil else { return fallback }
        return try int(key)
    }

    func flag(_ key: String) -> Bool {
        guard let value = self[key] else { return false }
        if let text = value as? String {
            let t = text.trimmingCharacters(in: .whitespaces)
            return t == "1" || t.caseInsensitiveCompare("true") == .orderedSame
        }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let bool = value as? Bool { return bool }
        return false
    }

    func remark(_ key: String) -> String {
        guard let value = self[key] else { return "{}" }
        if let object = value as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
        if let text = scalarText(value) { return text.isBlank ? "{}" : text }
        return "{}"
    }

    private func scalarText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if isBoolean(number) { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return nil
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(ObjectiveC)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return false
        #endif
    }
}

// MARK: - Ordered compact JSON writer

/// Writes compact JSON with keys in a fixed order (kept as a class so nested builders can
/// share it without overlapping inout access).
final class JSONWriter {
    private(set) var text = ""
    /// One entry per open container: true while it has no element yet.
    private var firstInContainer: [Bool] = []

    func object(_ body: () -> Void) {
        text += "{"
        firstInContainer.append(true)
        body()
        firstInContainer.removeLast()
        text += "}"
    }

    func array<T>(_ items: [T], _ element: (T) -> Void) {
        text += "["
        firstInContainer.append(true)
        for item in items {
            separate()
            element(item)
        }
        firstInContainer.removeLast()
        text += "]"
    }

    func key(_ name: String) {
        separate()
        text += JSONWriter.quote(name) + ":"
    }

    func field(_ name: String, _ value: Int) {
        key(name)
        text += String(value)
    }

    func field(_ name: String, _ value: String) {
        key(name)
        text += JSONWriter.quote(value)
    }

    private func separate() {
        guard let first = firstInContainer.last else { return }
        if !first { text += "," }
        firstInContainer[firstInContainer.count - 1] = false
    }

    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
