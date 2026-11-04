import SuperOTPKit
import XCTest

final class GroupsTests: XCTestCase {
    private func account(_ id: Int, _ groups: String...) -> OtpAccount {
        OtpAccount(id: id, uid: "a\(id)", issuer: "Issuer \(id)", secret: "S", categoryUids: groups)
    }

    private let work = OtpCategory(id: 1, uid: "work", seq: 0, title: "Work")
    private let home = OtpCategory(id: 2, uid: "home", seq: -1, title: "Home")

    func testNoGroupsMeansNoTabs() {
        let accounts = [account(1), account(2)]
        let tabs = groupTabs([], accounts)
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertEqual(accountsInTab(accounts, resolveTab(tabs, nil), []).map(\.id), [1, 2])
    }

    func testNewestGroupFirstAndOtherLast() {
        let accounts = [account(1, "work"), account(2), account(3, "home")]
        let tabs = groupTabs([work, home], accounts)
        XCTAssertEqual(tabs.map(\.key), ["home", "work", otherTabKey])
        XCTAssertEqual(accountsInTab(accounts, tabs.last, [work, home]).map(\.id), [2])
        XCTAssertEqual(accountsInTab(accounts, tabs[1], [work, home]).map(\.id), [1])
    }

    func testOtherHiddenOnceEveryAccountHasAGroup() {
        let accounts = [account(1, "work"), account(2, "home")]
        XCTAssertEqual(groupTabs([work, home], accounts).map(\.key), ["home", "work"])
    }

    func testEmptyNewGroupStillGetsATab() {
        let tabs = groupTabs([work, home], [account(1, "work")])
        XCTAssertEqual(tabs.map(\.key), ["home", "work"])
    }

    func testBindingToDeletedGroupCountsAsUngrouped() {
        let accounts = [account(1, "gone"), account(2, "work")]
        let tabs = groupTabs([work], accounts)
        XCTAssertEqual(tabs.map(\.key), ["work", otherTabKey])
        XCTAssertEqual(accountsInTab(accounts, tabs.last, [work]).map(\.id), [1])
        XCTAssertNil(groupOf(accounts[0], [work]))
    }

    func testMissingTabFallsBackToFirst() {
        let tabs = groupTabs([work, home], [account(1, "work")])
        XCTAssertEqual(resolveTab(tabs, otherTabKey)?.key, "home")
        XCTAssertEqual(resolveTab(tabs, "work")?.key, "work")
        XCTAssertNil(resolveTab([], "work"))
    }

    func testReorderingATabKeepsOtherAccountsInPlace() {
        // Full order 1...5; the tab shows 2, 4, 5 and the user drags 5 to the top.
        XCTAssertEqual(mergeSubsetOrder([1, 2, 3, 4, 5], [5, 2, 4]), [1, 5, 3, 2, 4])
        XCTAssertEqual(mergeSubsetOrder([1, 2], [9]), [1, 2])
    }

    func testGroupNamesMustBeUniqueAndNotBlank() {
        let groups = [work, home]
        XCTAssertEqual(validGroupName("  Games ", groups, editingId: nil), "Games")
        XCTAssertNil(validGroupName("   ", groups, editingId: nil))
        XCTAssertNil(validGroupName("work", groups, editingId: nil))
        XCTAssertEqual(validGroupName("Work", groups, editingId: 1), "Work")
        XCTAssertNil(validGroupName("其他", groups, editingId: nil, reserved: ["其他"]))
    }

    func testSearchIsPlainTextAndSortPinsFirst() {
        let accounts = [
            OtpAccount(id: 1, uid: "a", seq: 2, issuer: "Zed", secret: "S", account: "one", pinned: false, createdAt: 2),
            OtpAccount(id: 2, uid: "b", seq: 5, issuer: "Alpha", secret: "S", account: "two", pinned: true, createdAt: 1),
            OtpAccount(id: 3, uid: "c", seq: 1, issuer: "Beta", secret: "S", account: "work", pinned: false, createdAt: 3),
        ]
        XCTAssertEqual(sortAccounts(accounts, .manual).map(\.id), [2, 3, 1])
        XCTAssertEqual(sortAccounts(accounts, .name).map(\.id), [2, 3, 1])
        XCTAssertEqual(sortAccounts(accounts, .created).map(\.id), [2, 3, 1])
        XCTAssertEqual(filterAccounts(accounts, "WORK").map(\.id), [3])
        XCTAssertEqual(filterAccounts(accounts, " ze ").map(\.id), [1])
        XCTAssertTrue(filterAccounts(accounts, "secret-should-not-match").isEmpty)
        XCTAssertEqual(filterAccounts(accounts, "").count, 3)
    }

    func testDisplayLabels() {
        let both = OtpAccount(uid: "u", issuer: "GitHub", secret: "S", account: "octocat")
        XCTAssertEqual(displayLabels(both, .both).title, "GitHub")
        XCTAssertEqual(displayLabels(both, .both).subtitle, "octocat")
        XCTAssertEqual(displayLabels(both, .account).title, "octocat")
        XCTAssertNil(displayLabels(both, .issuer).subtitle)
        let onlyAccount = OtpAccount(uid: "u", secret: "S", account: "me")
        XCTAssertEqual(displayLabels(onlyAccount, .issuer).title, "me")
        XCTAssertNil(displayLabels(onlyAccount, .both).subtitle)
    }
}
