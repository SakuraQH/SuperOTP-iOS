import SuperOTPKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lock: AppLock
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack(spacing: 14) {
                            AppLogo(size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "SuperOTP").font(.title3.weight(.semibold))
                                Text("Encrypted on this device · Works offline")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Appearance") {
                    Picker(selection: $settings.theme) {
                        ForEach(ThemeChoice.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    } label: {
                        SettingsLabel("Theme", symbol: "paintpalette.fill", color: .purple)
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        HStack {
                            SettingsLabel("Language", symbol: "globe", color: .blue)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(verbatim: currentLanguage)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Picker(selection: $settings.display) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        SettingsLabel("Show", symbol: "list.bullet.rectangle", color: .teal)
                    }
                }

                Section {
                    Toggle(isOn: $settings.tapToCopy) {
                        SettingsLabel("Tap to Copy", symbol: "doc.on.doc.fill", color: .green)
                    }
                    Toggle(isOn: $settings.hideCodes) {
                        SettingsLabel("Hide Codes Until Tapped", symbol: "eye.slash.fill", color: .indigo)
                    }
                    Picker(selection: $settings.clipboardTimeout) {
                        Text("Never").tag(0)
                        Text("After 30 Seconds").tag(30)
                        Text("After 1 Minute").tag(60)
                        Text("After 2 Minutes").tag(120)
                    } label: {
                        SettingsLabel("Clear Clipboard", symbol: "clipboard.fill", color: .orange)
                    }
                } header: {
                    Text("Codes")
                } footer: {
                    Text("Copied codes are removed from the clipboard automatically after the chosen time.")
                }

                Section {
                    Toggle(isOn: lockBinding) {
                        SettingsLabel(lockTitle, symbol: lock.symbol, color: .red)
                    }
                    .disabled(!lock.canAuthenticate && !settings.appLock)
                    if settings.appLock {
                        Picker(selection: $settings.lockTimeout) {
                            Text("Immediately").tag(0)
                            Text("After 30 Seconds").tag(30)
                            Text("After 1 Minute").tag(60)
                            Text("After 5 Minutes").tag(300)
                        } label: {
                            SettingsLabel("Require Unlock", symbol: "timer", color: .orange)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if lock.canAuthenticate {
                        Text("When on, SuperOTP asks for \(lock.methodName) when it opens and after it has been in the background.")
                    } else {
                        Text("Set up a passcode on this device to use App Lock.")
                    }
                }

                Section("Data") {
                    NavigationLink {
                        GroupsView()
                    } label: {
                        SettingsLabel("Groups", symbol: "folder.fill", color: .orange)
                    }
                    NavigationLink {
                        BackupView()
                    } label: {
                        SettingsLabel("Backup & Restore", symbol: "externaldrive.fill.badge.timemachine", color: .blue)
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsLabel("About", symbol: "info.circle.fill", color: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .animation(.default, value: settings.appLock)
        }
    }

    private var lockTitle: LocalizedStringKey {
        switch lock.biometry {
        case .faceID: return "Face ID Lock"
        case .touchID: return "Touch ID Lock"
        case .opticID: return "Optic ID Lock"
        case .passcode, .unavailable: return "Passcode Lock"
        }
    }

    /// Turning the lock on asks for authentication first.
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { settings.appLock },
            set: { wanted in
                if wanted {
                    Task {
                        if await lock.enable() { Haptics.success() }
                    }
                } else {
                    lock.disable()
                }
            }
        )
    }

    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AppLogo(size: 96)
                    .shadow(color: Brand.gradientEnd.opacity(0.3), radius: 16, y: 8)
                    .padding(.top, 48)
                Text(verbatim: "SuperOTP")
                    .font(.title.bold())
                    .padding(.top, 18)
                Text("Version \(version)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 14) {
                    feature("lock.shield.fill", "Accounts are encrypted with a key kept in this device's Keychain and never leave it unless you make a backup.")
                    feature("wifi.slash", "Works offline. The only network request is fetching a website icon when you ask for one.")
                    feature("arrow.triangle.2.circlepath", "Backups use the CloudOTP format, so they open in SuperOTP on Android and in CloudOTP.")
                }
                .padding(20)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 28)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func feature(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
