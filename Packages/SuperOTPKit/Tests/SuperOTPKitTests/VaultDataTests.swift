import Foundation
import SuperOTPKit
import XCTest

final class VaultDataTests: XCTestCase {
    private func draft(_ issuer: String, account: String = "me") -> OtpAccount {
        OtpAccount(uid: "", issuer: issuer, secret: "JBSWY3DPEHPK3PXP", account: account)
    }

    func testSaveAssignsIdsSeqIconAndGroup() {
        var vault = VaultData()
        let group = vault.addGroup(title: "  Work ", now: 10)
        XCTAssertEqual(group.title, "Work")
        let first = vault.save(draft("GitHub"), groupUid: group.uid, now: 100)
        let second = vault.save(draft("Unknown Service"), groupUid: nil, now: 200)
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(first.imagePath, "github.png")
        XCTAssertEqual(second.imagePath, "")
        XCTAssertFalse(first.uid.isEmpty)
        XCTAssertEqual(vault.accounts.map(\.categoryUids), [[group.uid], []])
        XCTAssertEqual(vault.categories.first?.bindings, [first.uid])

        var edited = vault.accounts[0]
        edited.issuer = "GitHub Enterprise"
        vault.save(edited, groupUid: nil, now: 300)
        XCTAssertEqual(vault.accounts[0].issuer, "GitHub Enterprise")
        XCTAssertEqual(vault.accounts[0].editedAt, 300)
        XCTAssertEqual(vault.accounts[0].createdAt, 100)
        XCTAssertEqual(vault.accounts[0].categoryUids, [])
    }

    func testGroupsOrderMoveRemoveAndDelete() {
        var vault = VaultData()
        let a = vault.save(draft("A"), groupUid: nil)
        let b = vault.save(draft("B"), groupUid: nil)
        let work = vault.addGroup(title: "Work")
        let home = vault.addGroup(title: "Home")
        // New groups go first.
        XCTAssertEqual(vault.categories.map(\.title), ["Home", "Work"])
        vault.reorderGroups(ids: [work.id, home.id])
        XCTAssertEqual(vault.categories.map(\.title), ["Work", "Home"])

        vault.moveToGroup(ids: [a.id, b.id], groupUid: work.uid)
        XCTAssertEqual(vault.categories.first?.bindings.sorted(), [a.uid, b.uid].sorted())
        vault.moveToGroup(ids: [a.id], groupUid: home.uid)
        XCTAssertEqual(vault.account(id: a.id)?.categoryUids, [home.uid])
        vault.removeFromGroup(ids: [a.id], groupUid: home.uid)
        XCTAssertEqual(vault.account(id: a.id)?.categoryUids, [])

        vault.renameGroup(id: work.id, title: " Office ")
        XCTAssertEqual(vault.categories.first?.title, "Office")
        vault.deleteGroup(id: work.id)
        XCTAssertEqual(vault.categories.map(\.title), ["Home"])
        XCTAssertEqual(vault.account(id: b.id)?.categoryUids, [])
        XCTAssertEqual(vault.accounts.count, 2)
    }

    func testPinReorderHotpImageAndDelete() {
        var vault = VaultData()
        let a = vault.save(draft("A"), groupUid: nil)
        var counter = draft("B")
        counter.type = .hotp
        let b = vault.save(counter, groupUid: nil)
        let group = vault.addGroup(title: "G")
        vault.moveToGroup(ids: [a.id], groupUid: group.uid)

        vault.setPinned(ids: [b.id], true)
        XCTAssertEqual(sortAccounts(vault.accounts, .manual).map(\.id), [b.id, a.id])
        vault.setPinned(ids: [b.id], false)
        vault.reorder(ids: [b.id, a.id])
        XCTAssertEqual(sortAccounts(vault.accounts, .manual).map(\.id), [b.id, a.id])

        vault.nextHotp(id: b.id)
        vault.nextHotp(id: a.id)
        XCTAssertEqual(vault.account(id: b.id)?.counter, 1)
        XCTAssertEqual(vault.account(id: a.id)?.counter, 0)

        vault.setImage(id: a.id, imagePath: "letter:")
        XCTAssertEqual(vault.account(id: a.id)?.imagePath, "letter:")

        vault.delete(ids: [a.id])
        XCTAssertEqual(vault.accounts.map(\.id), [b.id])
        XCTAssertTrue(vault.categories.first?.bindings.isEmpty ?? false)
        // Ids are never reused.
        XCTAssertEqual(vault.save(draft("C"), groupUid: nil).id, 3)
    }

    func testCommitImportMergesCategoriesByUidThenTitle() throws {
        var vault = VaultData()
        let local = vault.save(draft("GitHub", account: "octocat"), groupUid: nil)
        let existingGroup = vault.addGroup(title: "Work")

        let document = try CloudOtpBackup.parse(backupFixture)
        let prepared = prepareImport(tokens: document.tokens, categories: document.categories, existing: vault.accounts)
        // The fixture has a GitHub token with the same issuer, account and secret.
        XCTAssertEqual(prepared.rows.count, 2)
        XCTAssertFalse(prepared.rows[1].isNew)
        XCTAssertEqual(prepared.rows[1].existingId, local.id)

        let resolved = resolveImport(rows: prepared.rows, choices: [.add, .skip], categories: prepared.categories)
        vault.commitImport(resolved)
        XCTAssertEqual(vault.accounts.count, 2)
        // "Work" matched by title, so no duplicate group appears and both accounts join it.
        XCTAssertEqual(vault.categories.count, 1)
        XCTAssertEqual(vault.categories.first?.id, existingGroup.id)
        XCTAssertEqual(Set(vault.categories.first?.bindings ?? []), Set(["totp-1", local.uid]))

        // Importing the same group again by uid updates it instead of adding another.
        var renamed = vault.categories[0]
        renamed.title = "Office"
        vault.commitImport(ResolvedImport(upserts: [], categories: [renamed]))
        XCTAssertEqual(vault.categories.map(\.title), ["Office"])
    }

    func testCodableRoundTripAndDocument() throws {
        var vault = VaultData()
        let group = vault.addGroup(title: "Work")
        vault.save(draft("GitHub"), groupUid: group.uid)
        let data = try JSONEncoder().encode(vault)
        let decoded = try JSONDecoder().decode(VaultData.self, from: data)
        XCTAssertEqual(decoded, vault)

        let document = vault.document(appVersion: "1.0.0", now: 42)
        XCTAssertEqual(document.createdAt, 42)
        XCTAssertEqual(document.tokens.count, 1)
        XCTAssertEqual(document.categories.first?.bindings, [document.tokens[0].uid])
        let parsed = try CloudOtpBackup.parse(CloudOtpBackup.toJson(document))
        XCTAssertEqual(parsed.categories.first?.bindings, [document.tokens[0].uid])
    }
}
