import SuperOTPKit
import XCTest

final class OtpAlgorithmsTests: XCTestCase {
    private let sha1Key = Array("12345678901234567890".utf8)
    private let sha256Key = Array("12345678901234567890123456789012".utf8)
    private let sha512Key = Array("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    func testRfc4226Hotp() {
        let expected = [
            "755224", "287082", "359152", "969429", "338314",
            "254676", "287922", "162583", "399871", "520489",
        ]
        for (counter, code) in expected.enumerated() {
            XCTAssertEqual(hotp(key: sha1Key, counter: UInt64(counter), digits: 6, algorithm: .sha1), code)
        }
    }

    func testRfc6238Totp() {
        let rows: [(Int, String, String, String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1_111_111_109, "07081804", "68084774", "25091201"),
            (1_111_111_111, "14050471", "67062674", "99943326"),
            (1_234_567_890, "89005924", "91819424", "93441116"),
            (2_000_000_000, "69279037", "90698825", "38618901"),
            (20_000_000_000, "65353130", "77737706", "47863826"),
        ]
        for (time, sha1, sha256, sha512) in rows {
            XCTAssertEqual(totp(key: sha1Key, unixSeconds: time, period: 30, digits: 8, algorithm: .sha1), sha1)
            XCTAssertEqual(totp(key: sha256Key, unixSeconds: time, period: 30, digits: 8, algorithm: .sha256), sha256)
            XCTAssertEqual(totp(key: sha512Key, unixSeconds: time, period: 30, digits: 8, algorithm: .sha512), sha512)
        }
    }

    func testBase32SecretMatchesRfcSeed() throws {
        let decoded = try decodeBase32("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(decoded, sha1Key)
        XCTAssertEqual(totp(key: decoded, unixSeconds: 59, period: 30, digits: 8, algorithm: .sha1), "94287082")
        XCTAssertEqual(encodeBase32(sha1Key), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    }

    func testBase32IsLenientButRejectsGarbage() throws {
        XCTAssertEqual(try decodeBase32("jbsw y3dp-ehpk 3pxp===="), try decodeBase32("JBSWY3DPEHPK3PXP"))
        XCTAssertFalse(isBase32("not base32!"))
        XCTAssertFalse(isBase32(""))
        XCTAssertFalse(isBase32("A"))
        XCTAssertEqual(normalizeSecret("jbsw y3dp===="), "JBSWY3DP")
        for length in 1...20 {
            let bytes = (0..<length).map { UInt8(($0 * 37 + 11) & 0xFF) }
            XCTAssertEqual(try decodeBase32(encodeBase32(bytes)), bytes, "length \(length)")
        }
    }

    func testInvalidParametersReturnNil() {
        XCTAssertNil(hotp(key: sha1Key, counter: 0, digits: 0, algorithm: .sha1))
        XCTAssertNil(hotp(key: sha1Key, counter: 0, digits: 11, algorithm: .sha1))
        XCTAssertNil(hotp(key: [], counter: 0, digits: 6, algorithm: .sha1))
        XCTAssertNil(totp(key: sha1Key, unixSeconds: 59, period: 0, digits: 6, algorithm: .sha1))
        XCTAssertEqual(hotp(key: sha1Key, counter: 0, digits: 10, algorithm: .sha1)?.count, 10)
    }

    func testCurrentCodeAndCountdown() {
        let account = OtpAccount(uid: "u", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", digits: 8)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(currentCode(account, at: date), "94287082")
        XCTAssertEqual(secondsRemaining(account, at: date), 1, accuracy: 0.0001)
        XCTAssertEqual(timeStep(account, at: date), 1)
        var counterBased = account
        counterBased.type = .hotp
        counterBased.counter = 1
        counterBased.digits = 6
        XCTAssertEqual(currentCode(counterBased, at: date), "287082")
        var steam = account
        steam.type = .steam
        XCTAssertNil(currentCode(steam, at: date))
        var broken = account
        broken.secret = "!!"
        XCTAssertNil(currentCode(broken, at: date))
    }

    func testCodeGrouping() {
        XCTAssertEqual(groupCode("123456"), "123 456")
        XCTAssertEqual(groupCode("12345678"), "1234 5678")
        XCTAssertEqual(groupCode("1234567"), "1234567")
        XCTAssertEqual(maskedCode(digits: 6), "••• •••")
        XCTAssertEqual(maskedCode(digits: 8), "•••• ••••")
    }
}
