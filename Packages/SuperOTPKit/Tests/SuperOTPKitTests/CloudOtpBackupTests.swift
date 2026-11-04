import SuperOTPKit
import XCTest

final class CloudOtpBackupTests: XCTestCase {
    func testParsesCloudOtpSchemaAndRoundTripsFields() throws {
        let document = try CloudOtpBackup.parse(backupFixture)
        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.createdAt, 1_700_000_000_000)
        XCTAssertEqual(document.appVersion, "2.0.0")
        XCTAssertEqual(document.tokens.count, 3)
        XCTAssertEqual(document.tokens[0].imagePath, "google.png")
        XCTAssertEqual(document.tokens[0].type, .totp)
        XCTAssertTrue(document.tokens[0].pinned)
        XCTAssertEqual(document.tokens[1].type, .hotp)
        XCTAssertEqual(document.tokens[1].counter, 7)
        XCTAssertEqual(document.tokens[1].digits, 8)
        XCTAssertEqual(document.tokens[1].algorithm, .sha256)
        XCTAssertEqual(document.tokens[1].tags, "ci")
        XCTAssertEqual(document.tokens[1].note, "work")
        XCTAssertEqual(document.tokens[2].type, .steam)
        XCTAssertEqual(document.categories.first?.bindings, ["totp-1", "hotp-1"])
        XCTAssertEqual(document.categories.first?.note, "office")

        let again = try CloudOtpBackup.parse(CloudOtpBackup.toJson(document))
        XCTAssertEqual(again, document)
    }

    func testParsesLegacyStringEntryPayload() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(backupFixture.utf8)) as? [String: Any])
        func stringify(_ list: Any?) throws -> [String] {
            let entries = try XCTUnwrap(list as? [Any])
            return try entries.map { entry in
                String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
            }
        }
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "tokens": try stringify(root["tokens"]),
            "categories": try stringify(root["categories"]),
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
        let document = try CloudOtpBackup.parse(text)
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.tokens.count, 3)
        XCTAssertEqual(document.tokens[0].uid, "totp-1")
        XCTAssertEqual(document.categories.first?.bindings, ["totp-1", "hotp-1"])
    }

    func testRejectsMismatchedCountsAndFutureSchema() throws {
        let json = CloudOtpBackup.toJson(try CloudOtpBackup.parse(backupFixture))
        XCTAssertTrue(json.contains("\"tokenCount\":3"))
        let broken = json.replacingOccurrences(of: "\"tokenCount\":3", with: "\"tokenCount\":1")
        XCTAssertThrowsError(try CloudOtpBackup.parse(broken)) { error in
            XCTAssertEqual(error as? BackupFailure, .badFormat("tokenCount"))
        }
        var future = try CloudOtpBackup.parse(backupFixture)
        future.schemaVersion = 3
        XCTAssertThrowsError(try CloudOtpBackup.parse(CloudOtpBackup.toJson(future))) { error in
            XCTAssertEqual(error as? BackupFailure, .unsupportedVersion)
        }
        XCTAssertThrowsError(try CloudOtpBackup.parse("not json"))
    }

    func testJsonEscapesText() throws {
        var document = try CloudOtpBackup.parse(backupFixture)
        document.tokens[0].issuer = "Quote \" backslash \\ newline \n tab \t 中文 \u{01}"
        let parsed = try CloudOtpBackup.parse(CloudOtpBackup.toJson(document))
        XCTAssertEqual(parsed.tokens[0].issuer, document.tokens[0].issuer)
    }

    func testBinLayoutAndPasswordRoundTrip() throws {
        let document = try CloudOtpBackup.parse(backupFixture)
        let salt = (0..<16).map { UInt8($0) }
        let iv = (0..<12).map { UInt8($0 + 3) }
        let encrypted = try CloudOtpBackup.encrypt(document, password: "test-password", salt: salt, iv: iv)
        let bytes = [UInt8](encrypted)
        let header = Array(CloudOtpBackup.header.utf8)
        XCTAssertEqual(Array(bytes[0..<header.count]), header)
        XCTAssertEqual(Array(bytes[header.count..<(header.count + 16)]), salt)
        XCTAssertEqual(Array(bytes[(header.count + 16)..<(header.count + 28)]), iv)

        let name = CloudOtpBackup.backupFileName(epochMillis: 1_700_000_000_123, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "SuperOTP-Backup-2023-11-14-22-13-20-123000-SuperOTP.bin")
        XCTAssertTrue(CloudOtpBackup.isBackupName(name))
        XCTAssertTrue(CloudOtpBackup.isBackupName("folder/CloudOTP-Backup-old.bin"))
        XCTAssertFalse(CloudOtpBackup.isBackupName("notes.bin"))

        let decrypted = try CloudOtpBackup.decrypt(encrypted, password: "test-password")
        XCTAssertEqual(decrypted.tokens.map(\.uid), document.tokens.map(\.uid))
        XCTAssertEqual(decrypted.tokens[0].imagePath, "google.png")
        XCTAssertEqual(decrypted.categories, document.categories)

        XCTAssertThrowsError(try CloudOtpBackup.decrypt(encrypted, password: "wrong")) { error in
            XCTAssertEqual(error as? BackupFailure, .badPassword)
        }
        var tampered = bytes
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try CloudOtpBackup.decrypt(Data(tampered), password: "test-password")) { error in
            XCTAssertEqual(error as? BackupFailure, .badPassword)
        }
        XCTAssertThrowsError(try CloudOtpBackup.decrypt(Data(header), password: "")) { error in
            XCTAssertEqual(error as? BackupFailure, .emptyPassword)
        }
        XCTAssertThrowsError(try CloudOtpBackup.decrypt(Data("hello".utf8), password: "x")) { error in
            XCTAssertEqual(error as? BackupFailure, .notBackup)
        }
    }

    /// A file written by another implementation (Python argon2-cffi + AES-GCM) must open.
    func testDecryptsBackupWrittenByReferenceImplementation() throws {
        let data = try XCTUnwrap(Data(base64Encoded: pythonEncryptedBackup, options: .ignoreUnknownCharacters))
        let document = try CloudOtpBackup.decrypt(data, password: "correct horse")
        XCTAssertEqual(document.tokens.count, 3)
        XCTAssertEqual(document.tokens[0].issuer, "Google 谷歌")
        XCTAssertEqual(document.tokens[1].counter, 7)
        XCTAssertEqual(document.categories.first?.title, "Work")
    }

    func testArgon2idMatchesRfc9106AndCloudOtpParameters() throws {
        let tag = try argon2id(
            password: [UInt8](repeating: 1, count: 32),
            salt: [UInt8](repeating: 2, count: 16),
            secret: [UInt8](repeating: 3, count: 8),
            associatedData: [UInt8](repeating: 4, count: 12),
            iterations: 3, memoryKiB: 32, lanes: 4, length: 32
        )
        XCTAssertEqual(hex(tag), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")

        // Reference value from argon2-cffi with the backup parameters (t=3, m=64 MiB, p=1).
        let key = try CloudOtpBackup.deriveKey(password: "correct horse", salt: (0..<16).map { UInt8($0) })
        XCTAssertEqual(hex(key), "e3c889ca40ed01e6b6771fc8a5bf16e35ad60b41c9bd5d7e6d63adf51e50b0fd")

        let small = try argon2id(password: Array("test-password".utf8), salt: (0..<16).map { UInt8($0) }, iterations: 3, memoryKiB: 256, lanes: 1, length: 32)
        XCTAssertEqual(hex(small), "a591cd25530d8bf2364661b3ace2728f47230c71ec87201f7e1a34ab6ebfe47d")

        XCTAssertEqual(
            hex(blake2b(Array("abc".utf8))),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        )
        XCTAssertThrowsError(try argon2id(password: [], salt: [], iterations: 0, memoryKiB: 8, lanes: 1, length: 32))
    }

    func testImportPlanSkipsNonTotpAndResolvesOverwrite() throws {
        let document = try CloudOtpBackup.parse(backupFixture)
        let existing = OtpAccount(id: 9, uid: "local-hotp", seq: 4, issuer: "GitHub", secret: "JBSWY3DPEHPK3PXP====", account: "octocat", type: .hotp)
        let prepared = prepareImport(tokens: document.tokens, categories: document.categories, existing: [existing])
        XCTAssertEqual(prepared.skippedOtherTypes, 1)
        XCTAssertEqual(prepared.rows.count, 2)
        XCTAssertTrue(prepared.rows[0].isNew)
        XCTAssertEqual(prepared.rows[1].existingId, 9)
        XCTAssertEqual(prepared.defaultChoices, [.add, .skip])

        let resolved = resolveImport(rows: prepared.rows, choices: [.add, .overwrite], categories: prepared.categories)
        XCTAssertEqual(resolved.upserts[0].uid, "totp-1")
        XCTAssertEqual(resolved.upserts[0].id, 0)
        XCTAssertEqual(resolved.upserts[0].imagePath, "google.png")
        XCTAssertEqual(resolved.upserts[1].uid, "local-hotp")
        XCTAssertEqual(resolved.upserts[1].id, 9)
        XCTAssertEqual(resolved.upserts[1].seq, 4)
        XCTAssertEqual(resolved.categories.first?.bindings, ["totp-1", "local-hotp"])

        let added = resolveImport(rows: prepared.rows, choices: [.add, .add], categories: prepared.categories)
        XCTAssertEqual(added.upserts[1].id, 0)
        XCTAssertNotEqual(added.upserts[1].uid, existing.uid)

        let skipped = resolveImport(rows: prepared.rows, choices: [.skip, .skip], categories: prepared.categories)
        XCTAssertTrue(skipped.upserts.isEmpty)
        XCTAssertEqual(skipped.categories.first?.bindings, ["local-hotp"])
    }

    func testOtpauthAndMigrationQr() throws {
        let account = OtpAccount(uid: "u", issuer: "GitHub", secret: "JBSWY3DPEHPK3PXP", account: "octocat", imagePath: "github.png", type: .hotp, counter: 4)
        let uri = otpauthUri(account)
        XCTAssertTrue(uri.hasPrefix("otpauth://hotp/GitHub%3Aoctocat?"))
        XCTAssertTrue(uri.contains("counter=5"))
        let parsed = parseImportText(uri, now: 5)
        XCTAssertEqual(parsed.tokens.count, 1)
        XCTAssertEqual(parsed.tokens[0].counter, 5)
        XCTAssertEqual(parsed.tokens[0].imagePath, "github.png")
        XCTAssertEqual(parsed.tokens[0].issuer, "GitHub")
        XCTAssertEqual(parsed.tokens[0].account, "octocat")
        XCTAssertEqual(parsed.tokens[0].type, .hotp)

        let steam = parseImportText("otpauth://steam/player?secret=JBSWY3DPEHPK3PXP", now: 5)
        let prepared = prepareImport(tokens: steam.tokens, categories: [], existing: [])
        XCTAssertEqual(prepared.skippedOtherTypes, 1)
        XCTAssertTrue(prepared.rows.isEmpty)
        XCTAssertEqual(steam.tokens.first?.digits, 5)

        let fromGoogle = parseImportText(googleMigrationUri(), now: 9)
        XCTAssertEqual(fromGoogle.tokens.count, 1)
        XCTAssertEqual(fromGoogle.tokens.first?.issuer, "Google")
        XCTAssertEqual(fromGoogle.tokens.first?.account, "user@gmail.com")
        XCTAssertEqual(fromGoogle.tokens.first?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(fromGoogle.tokens.first?.type, .totp)
        XCTAssertEqual(fromGoogle.tokens.first?.digits, 6)

        let fromCloud = parseImportText(cloudMigrationUri(), now: 9)
        XCTAssertEqual(fromCloud.tokens.first?.issuer, "Example")
        XCTAssertEqual(fromCloud.tokens.first?.imagePath, "logo.png")
        XCTAssertEqual(fromCloud.tokens.first?.uid, "keep-uid")

        let fromCategories = parseImportText(categoryMigrationUri(), now: 9)
        XCTAssertEqual(fromCategories.categories.first?.title, "Work")
        XCTAssertEqual(fromCategories.categories.first?.bindings, ["keep-uid"])
    }

    func testImportTextHandlesManyLinesAndRejectsJunk() {
        let text = """
        otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60

        OTPAUTH://TOTP/Label?secret=JBSWY3DPEHPK3PXP
        otpauth://totp/Broken?secret=not-base32!
        https://example.com
        otpauth://totp/NoSecret
        """
        let parsed = parseImportText(text, now: 1)
        XCTAssertEqual(parsed.tokens.count, 2)
        XCTAssertEqual(parsed.invalid, 3)
        let first = parsed.tokens[0]
        XCTAssertEqual(first.issuer, "ACME Co")
        XCTAssertEqual(first.account, "john@example.com")
        XCTAssertEqual(first.algorithm, .sha256)
        XCTAssertEqual(first.digits, 8)
        XCTAssertEqual(first.period, 60)
        XCTAssertEqual(parsed.tokens[1].account, "Label")
        XCTAssertEqual(parsed.tokens[1].issuer, "")
        XCTAssertEqual(parseImportText("   ").invalid, 1)
        // A migration payload whose Base64 '+' was turned into a space still decodes.
        let spaced = googleMigrationUri().replacingOccurrences(of: "%2B", with: " ")
        XCTAssertEqual(parseImportText(spaced, now: 1).tokens.count, 1)
        XCTAssertEqual(parseImportText("otpauth-migration://offline?data=%%%", now: 1).invalid, 1)
    }

    func testIconsMatchIssuerAndPath() {
        let files = ["google.png", "gmail.png", "github.png"]
        let brands = files.map { cleanBrand(String($0.dropLast(4))) }
        XCTAssertEqual(rankBrandFiles("Gmail", files: files, brands: brands).first, "gmail.png")
        XCTAssertEqual(rankBrandFiles("GitHub", files: files, brands: brands).first, "github.png")
        XCTAssertEqual(BrandIcons.matchFile("GitHub Enterprise"), "github.png")
        XCTAssertEqual(BrandIcons.matchFile("Microsoft Azure"), "microsoft_azure.png")
        XCTAssertNil(BrandIcons.matchFile(""))
        XCTAssertEqual(BrandIcons.lightFile(for: "github_dark.png"), "github.png")
        XCTAssertEqual(BrandIcons.lightFile(for: "builtin:assets/brand/google.png"), "google.png")
        XCTAssertNil(BrandIcons.lightFile(for: "unknown.png"))
        XCTAssertEqual(BrandIcons.assetName(forFile: "github.png"), "Brand/github")
        XCTAssertEqual(iconAssetName("assets/brand/google.png"), "google.png")
        XCTAssertNil(iconAssetName("file:/tmp/a.png"))
        XCTAssertNil(iconAssetName("letter:"))
        XCTAssertEqual(safeHost("https://GitHub.com/login"), "github.com")
        XCTAssertEqual(safeHost("user@accounts.google.com:443/x"), "accounts.google.com")
        XCTAssertNil(safeHost("http://127.0.0.1/favicon.ico"))
        XCTAssertNil(safeHost("localhost"))
        XCTAssertNil(safeHost("printer.local"))
        XCTAssertNil(safeHost("a..b.com"))
        XCTAssertEqual(faviconUrl("github.com"), "https://github.com/favicon.ico")
        XCTAssertEqual(letterColor("GitHub"), letterColor("github"))

        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
        var ico = [UInt8](repeating: 0, count: 22 + png.count)
        ico[2] = 1
        ico[4] = 1
        ico[6] = 16
        ico[7] = 16
        ico[14] = UInt8(png.count)
        ico[18] = 22
        ico.replaceSubrange(22..., with: png)
        XCTAssertEqual(extractIconBytes(ico), png)
        XCTAssertEqual(extractIconBytes(png), png)
        XCTAssertEqual(Array(dibToBmp([40, 0, 0, 0, 1, 2])[0..<2]), [0x42, 0x4D])
    }

    // MARK: Helpers

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func base64Query(_ bytes: [UInt8]) -> String {
        percentEncode(Data(bytes).base64EncodedString())
    }

    private func googleMigrationUri() -> String {
        var param = ProtoWriter()
        param.bytes(1, try! decodeBase32("JBSWY3DPEHPK3PXP"))
        param.string(2, "user@gmail.com")
        param.string(3, "Google")
        param.varint(4, 1)
        param.varint(5, 1)
        param.varint(6, 2)
        var payload = ProtoWriter()
        payload.message(1, param.output)
        // Pad the payload so its Base64 contains a '+' (exercises the space-for-plus fallback).
        payload.message(9, [0x0F, 0xBE, 0xFB])
        return "otpauth-migration://offline?data=" + base64Query(payload.output)
    }

    private func cloudMigrationUri() -> String {
        var param = ProtoWriter()
        param.bytes(1, Array("JBSWY3DPEHPK3PXP".utf8))
        param.string(2, "Example")
        param.string(3, "person")
        param.varint(5, 1)
        param.varint(6, 2)
        param.varint(7, 1)
        param.varint(8, 30)
        param.string(13, "logo.png")
        param.string(16, "keep-uid")
        var payload = ProtoWriter()
        payload.message(1, param.output)
        return "cloudotpauth-migration://offline?tokens=" + base64Query(payload.output)
    }

    private func categoryMigrationUri() -> String {
        var param = ProtoWriter()
        param.string(2, "Work")
        param.string(6, "cat")
        param.string(7, "keep-uid")
        var payload = ProtoWriter()
        payload.message(1, param.output)
        return "cloudotpauth-migration://offline?categories=" + base64Query(payload.output)
    }
}
