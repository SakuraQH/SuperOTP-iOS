#if DEBUG
import Foundation
import SuperOTPKit

/// Debug-only launch arguments for previews and screenshots, e.g.
/// `-demoData YES -screen settings -hideCodes NO -theme dark`.
/// Values arrive through UserDefaults' argument domain; none of this exists in Release builds.
enum DebugLaunch {
    static var demoData: Bool { UserDefaults.standard.bool(forKey: "demoData") }
    static var screen: String? { UserDefaults.standard.string(forKey: "screen") }

    /// Fills an empty vault with sample accounts and groups.
    static func seedIfRequested(_ data: inout VaultData) -> Bool {
        guard demoData, data.accounts.isEmpty else { return false }
        let personal = data.addGroup(title: String(localized: "Personal"))
        let work = data.addGroup(title: String(localized: "Work"))
        let samples: [(issuer: String, account: String, group: OtpCategory?, pinned: Bool, type: OtpType)] = [
            ("Google", "jane.doe@gmail.com", personal, true, .totp),
            ("GitHub", "octocat@example.com", work, true, .totp),
            ("Microsoft", "jane@contoso.com", work, false, .totp),
            ("AWS", "root@acme.io", work, false, .totp),
            ("Slack", "jane@acme.slack.com", work, false, .totp),
            ("Discord", "jane#1024", personal, false, .totp),
            ("Dropbox", "jane@example.com", personal, false, .totp),
            ("Example Bank", "Online banking", nil, false, .hotp),
            ("Nextcloud", "jane", nil, false, .totp),
        ]
        var generator = SystemRandomNumberGenerator()
        for sample in samples {
            let secret = encodeBase32((0..<20).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            var account = OtpAccount(uid: "", issuer: sample.issuer, secret: secret, account: sample.account, type: sample.type)
            if sample.type == .hotp { account.counter = 3 }
            let stored = data.save(account, groupUid: sample.group?.uid)
            if sample.pinned { data.setPinned(ids: [stored.id], true) }
        }
        return true
    }

    static let sampleImport = """
    otpauth://totp/GitLab:jane@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitLab
    otpauth://totp/Cloudflare:jane@example.com?secret=KRSXG5CTMVRXEZLU&issuer=Cloudflare&digits=8
    otpauth://totp/Notion:jane@example.com?secret=MFRGGZDFMZTWQ2LK&issuer=Notion
    otpauth://steam/Steam:player?secret=JBSWY3DPEHPK3PXP
    not a link
    """
}
#endif
