import SwiftUI

@main
struct SuperOTPApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var vault: VaultStore
    @StateObject private var backups: BackupManager
    @StateObject private var lock: AppLock
    @StateObject private var toasts = ToastCenter()
    @StateObject private var router = AppRouter()

    init() {
        let settings = AppSettings()
        let vault = VaultStore()
        _settings = StateObject(wrappedValue: settings)
        _vault = StateObject(wrappedValue: vault)
        _backups = StateObject(wrappedValue: BackupManager(settings: settings, vault: vault))
        _lock = StateObject(wrappedValue: AppLock(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(vault)
                .environmentObject(backups)
                .environmentObject(lock)
                .environmentObject(toasts)
                .environmentObject(router)
        }
    }
}

/// Hand-off for links opened from outside (otpauth:// and otpauth-migration://).
@MainActor
final class AppRouter: ObservableObject {
    @Published var pendingImportText: String?
}
