import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID (with passcode fallback) gate in front of the vault.
@MainActor
final class AppLock: ObservableObject {
    enum Biometry {
        case faceID
        case touchID
        case opticID
        case passcode
        case unavailable
    }

    @Published private(set) var isLocked: Bool
    @Published var message: String?
    @Published private(set) var authenticating = false

    private let settings: AppSettings
    private var backgroundedAt: Date?
    /// Prompt automatically once per lock (launch or return from background), not after a cancel.
    private var promptPending: Bool

    init(settings: AppSettings) {
        self.settings = settings
        isLocked = settings.appLock
        promptPending = settings.appLock
    }

    var biometry: Biometry {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    var canAuthenticate: Bool { biometry != .unavailable }

    var symbol: String {
        switch biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .passcode, .unavailable: return "lock.fill"
        }
    }

    var methodName: String {
        switch biometry {
        case .faceID: return String(localized: "Face ID")
        case .touchID: return String(localized: "Touch ID")
        case .opticID: return String(localized: "Optic ID")
        case .passcode, .unavailable: return String(localized: "Passcode")
        }
    }

    // MARK: Lifecycle

    func scenePhaseChanged(to phase: ScenePhase) {
        guard settings.appLock else {
            isLocked = false
            return
        }
        switch phase {
        case .background:
            if settings.lockTimeout <= 0 {
                lock()
            } else if backgroundedAt == nil {
                backgroundedAt = Date()
            }
        case .active:
            if let since = backgroundedAt, Date().timeIntervalSince(since) >= Double(settings.lockTimeout) {
                lock()
            }
            backgroundedAt = nil
            if isLocked && promptPending {
                promptPending = false
                Task { await unlock() }
            }
        default:
            break
        }
    }

    private func lock() {
        guard !isLocked else { return }
        isLocked = true
        promptPending = true
        message = nil
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        guard canAuthenticate else { return }
        authenticating = true
        defer { authenticating = false }
        if await Self.authenticate(reason: String(localized: "Unlock to view your verification codes")) {
            isLocked = false
            message = nil
        } else {
            message = String(localized: "Authentication was cancelled")
        }
    }

    /// Lock unavailable (no passcode set any more): turn it off and let the user in, as on Android.
    func enterWithoutLock() {
        settings.appLock = false
        isLocked = false
    }

    /// Turning the lock on requires one successful authentication first.
    func enable() async -> Bool {
        guard await Self.authenticate(reason: String(localized: "Confirm it's you to turn on App Lock")) else { return false }
        settings.appLock = true
        return true
    }

    func disable() {
        settings.appLock = false
        isLocked = false
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
