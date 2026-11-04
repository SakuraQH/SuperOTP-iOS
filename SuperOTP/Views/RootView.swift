import SuperOTPKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var backups: BackupManager
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    @State private var lockWindow = OverlayWindow(level: UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1), interactive: true)
    @State private var coverWindow = OverlayWindow(level: UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2), interactive: false)
    @State private var launchBackupDone = false

    var body: some View {
        ZStack {
            switch vault.state {
            case .loading:
                Color(.systemGroupedBackground).ignoresSafeArea()
            case let .failed(message):
                VaultErrorView(message: message) { vault.load() }
            case .ready:
                HomeView()
            }
            // Curtain under the lock window so nothing shows while it appears.
            if lock.isLocked {
                BrandBackground().ignoresSafeArea()
            }
        }
        .onAppear {
            vault.loadIfNeeded()
            OverlayWindow.applyStyle(settings.theme.interfaceStyle)
            updateLockWindow()
            if scenePhase == .active { lock.scenePhaseChanged(to: .active) }
            runLaunchBackup()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            lock.scenePhaseChanged(to: newPhase)
            if newPhase == .active {
                vault.loadIfNeeded()
                coverWindow.hide()
            } else if oldPhase == .active || newPhase == .background {
                // Hide codes from the app switcher snapshot and Control Center peeks.
                coverWindow.show(AnyView(PrivacyCover()), style: settings.theme.interfaceStyle)
            }
        }
        .onChange(of: lock.isLocked) { _, _ in updateLockWindow() }
        .onChange(of: settings.theme) { _, theme in OverlayWindow.applyStyle(theme.interfaceStyle) }
        .onChange(of: vault.state) { _, _ in runLaunchBackup() }
        .onOpenURL { url in router.pendingImportText = url.absoluteString }
    }

    private func updateLockWindow() {
        if lock.isLocked {
            // Dismiss the keyboard: it lives in its own window above ours.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            lockWindow.show(
                AnyView(LockScreen().environmentObject(lock).environmentObject(settings)),
                style: .dark
            )
        } else {
            lockWindow.hide()
        }
    }

    private func runLaunchBackup() {
        guard !launchBackupDone, vault.state == .ready else { return }
        launchBackupDone = true
        guard settings.backupOnLaunch, vault.hasBackupPassword else { return }
        Task {
            do {
                try await backups.backupNow()
            } catch {
                toasts.show(String(localized: "The launch backup did not finish"), style: .failure)
            }
        }
    }
}

/// Brand gradient used behind the lock screen and the privacy cover.
struct BrandBackground: View {
    var body: some View {
        LinearGradient(colors: [Brand.gradientStart, Brand.gradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Shown in the app switcher instead of the codes.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            BrandBackground()
            AppLogo(size: 88, onGradient: true)
        }
        .ignoresSafeArea()
    }
}

private struct VaultErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Vault Unavailable", systemImage: "exclamationmark.lock")
        } description: {
            Text("Your accounts could not be opened. If the device was just restarted, unlock it and try again.\n\n\(message)")
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
