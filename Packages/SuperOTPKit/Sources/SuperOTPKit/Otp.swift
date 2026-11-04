import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Base32 (RFC 4648, no padding on output)

private let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

private let base32Lookup: [UInt8: UInt8] = {
    var map: [UInt8: UInt8] = [:]
    for (index, char) in base32Alphabet.enumerated() { map[char] = UInt8(index) }
    return map
}()

public enum Base32Error: Error, Equatable {
    case empty
    case invalidCharacter
}

public func encodeBase32(_ data: [UInt8]) -> String {
    if data.isEmpty { return "" }
    var out: [UInt8] = []
    out.reserveCapacity((data.count * 8 + 4) / 5)
    var buffer: UInt32 = 0
    var bits = 0
    for byte in data {
        buffer = (buffer << 8) | UInt32(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            out.append(base32Alphabet[Int((buffer >> UInt32(bits)) & 31)])
        }
        buffer &= (1 << UInt32(bits)) - 1
    }
    if bits > 0 {
        out.append(base32Alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
    }
    return String(decoding: out, as: UTF8.self)
}

/// Lenient decoder: ignores case, spaces, dashes and padding.
public func decodeBase32(_ input: String) throws -> [UInt8] {
    let clean = input.uppercased().utf8.filter { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "=") && $0 != UInt8(ascii: "-") }
    if clean.isEmpty { throw Base32Error.empty }
    var out: [UInt8] = []
    out.reserveCapacity(clean.count * 5 / 8)
    var buffer: UInt32 = 0
    var bits = 0
    for char in clean {
        guard let value = base32Lookup[char] else { throw Base32Error.invalidCharacter }
        buffer = (buffer << 5) | UInt32(value)
        bits += 5
        if bits >= 8 {
            bits -= 8
            out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
        }
        buffer &= (1 << UInt32(bits)) - 1
    }
    if out.isEmpty { throw Base32Error.empty }
    return out
}

public func isBase32(_ input: String) -> Bool {
    (try? decodeBase32(input)) != nil
}

public func normalizeSecret(_ secret: String) -> String {
    var value = secret.uppercased().replacingOccurrences(of: " ", with: "")
    while value.hasSuffix("=") { value.removeLast() }
    return value
}

// MARK: - HOTP / TOTP (RFC 4226 / RFC 6238)

func hmac(_ algorithm: OtpAlgorithm, key: [UInt8], message: [UInt8]) -> [UInt8] {
    let symmetric = SymmetricKey(data: key)
    switch algorithm {
    case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
    case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
    case .sha512: return Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
    }
}

/// Returns nil for unsupported parameters instead of trapping.
public func hotp(key: [UInt8], counter: UInt64, digits: Int, algorithm: OtpAlgorithm) -> String? {
    guard (1...10).contains(digits), !key.isEmpty else { return nil }
    var message = [UInt8](repeating: 0, count: 8)
    for i in 0..<8 { message[7 - i] = UInt8((counter >> UInt64(8 * i)) & 0xFF) }
    let hash = hmac(algorithm, key: key, message: message)
    let offset = Int(hash[hash.count - 1] & 0x0F)
    let binary = (UInt64(hash[offset] & 0x7F) << 24) |
        (UInt64(hash[offset + 1]) << 16) |
        (UInt64(hash[offset + 2]) << 8) |
        UInt64(hash[offset + 3])
    var mod: UInt64 = 1
    for _ in 0..<digits { mod *= 10 }
    let value = String(binary % mod)
    return String(repeating: "0", count: max(0, digits - value.count)) + value
}

public func totp(key: [UInt8], unixSeconds: Int, period: Int, digits: Int, algorithm: OtpAlgorithm) -> String? {
    guard period > 0, unixSeconds >= 0 else { return nil }
    return hotp(key: key, counter: UInt64(unixSeconds / period), digits: digits, algorithm: algorithm)
}

/// The code an account shows at `date`, or nil for unsupported types and broken secrets.
public func currentCode(_ account: OtpAccount, at date: Date = Date()) -> String? {
    guard let key = try? decodeBase32(account.secret) else { return nil }
    switch account.type {
    case .hotp:
        return hotp(key: key, counter: UInt64(max(0, account.counter)), digits: account.digits, algorithm: account.algorithm)
    case .totp:
        return totp(key: key, unixSeconds: Int(date.timeIntervalSince1970), period: max(1, account.period), digits: account.digits, algorithm: account.algorithm)
    default:
        return nil
    }
}

/// Index of the TOTP time step at `date`; used to keep a revealed code visible for one period.
public func timeStep(_ account: OtpAccount, at date: Date) -> Int {
    Int((date.timeIntervalSince1970 / Double(max(1, account.period))).rounded(.down))
}

/// Seconds left in the current period (fractional, for smooth countdown rings).
public func secondsRemaining(_ account: OtpAccount, at date: Date) -> Double {
    let period = Double(max(1, account.period))
    let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
    return period - elapsed
}

/// "123456" -> "123 456", "12345678" -> "1234 5678".
public func groupCode(_ code: String) -> String {
    let chars = Array(code)
    switch chars.count {
    case 6: return String(chars[0..<3]) + " " + String(chars[3...])
    case 8: return String(chars[0..<4]) + " " + String(chars[4...])
    default: return code
    }
}

/// Bullet placeholder with the same grouping as the real code.
public func maskedCode(digits: Int) -> String {
    groupCode(String(repeating: "•", count: min(max(digits, 4), 8)))
}
