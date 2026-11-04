import SuperOTPKit
import SwiftUI
import UniformTypeIdentifiers

/// Backup & restore. A status card says whether backups are on and when the last one was made;
/// below are the settings, the automatic options and the ways to restore.
struct BackupView: View {
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var backups: BackupManager
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var importFlow = ImportFlow()

    @State private var editingPassword = false
    @State private var showingList = false
    @State private var showingPicker = false
    @State private var pickerMode: PickerMode = .backupFile
    @State private var exportDocument: BackupFileDocument?
    @State private var exportName = ""

    private enum PickerMode {
        case folder
        case backupFile
    }

    var body: some View {
        Form {
            Section {
                BackupStatusCard(
                    ready: vault.hasBackupPassword,
                    busy: backups.busy,
                    latest: backups.entries?.first?.modifiedAt,
                    count: backups.entries?.count,
                    onBackup: backupNow
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Backup Settings") {
                Button {
                    editingPassword = true
                } label: {
                    SetupRow(
                        symbol: "key.fill",
                        title: "Backup Password",
                        subtitle: vault.hasBackupPassword ? Text("Needed to restore a backup") : Text("Used to encrypt backup files"),
                        done: vault.hasBackupPassword,
                        action: vault.hasBackupPassword ? "Change" : "Set Up"
                    )
                }
                Menu {
                    Button {
                        pickerMode = .folder
                        showingPicker = true
                    } label: {
                        Label("Choose Folder…", systemImage: "folder.badge.plus")
                    }
                    if backups.isCustomFolder {
                        Button {
                            backups.useDefaultFolder()
                            Task { await backups.refresh() }
                        } label: {
                            Label("Use On My \(UIDevice.current.localizedModel)", systemImage: "iphone")
                        }
                    }
                } label: {
                    SetupRow(
                        symbol: "folder.fill",
                        title: "Backup Folder",
                        subtitle: Text(verbatim: backups.folderName),
                        done: true,
                        action: "Change"
                    )
                }
            }

            Section {
                Toggle("Back Up When the App Opens", isOn: $settings.backupOnLaunch)
                    .disabled(!vault.hasBackupPassword)
                Stepper(value: $settings.backupKeep, in: 0...99) {
                    HStack {
                        Text("Keep")
                        Spacer()
                        (settings.backupKeep == 0 ? Text("All Backups") : Text("\(settings.backupKeep) Backups"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Automatic")
            } footer: {
                Text("When there are more backups than this, the oldest ones are deleted. Set it to 0 to keep them all.")
            }

            Section {
                Button {
                    showingList = true
                    Task { await backups.refresh() }
                } label: {
                    LabeledContent {
                        if let entries = backups.entries {
                            Text("\(entries.count) Found")
                        } else {
                            ProgressView()
                        }
                    } label: {
                        Label("Restore from Backup Folder", systemImage: "clock.arrow.circlepath")
                    }
                }
                Button {
                    pickerMode = .backupFile
                    showingPicker = true
                } label: {
                    Label("Import a Backup File…", systemImage: "doc.badge.arrow.up")
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("Restoring shows a preview first; nothing on this device changes until you confirm.")
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    Label("Export Backup File…", systemImage: "square.and.arrow.up")
                }
                .disabled(!vault.hasBackupPassword || backups.busy)
                .fileExporter(
                    isPresented: Binding(isPresent: $exportDocument),
                    document: exportDocument,
                    contentType: .data,
                    defaultFilename: exportName
                ) { result in
                    switch result {
                    case .success: toasts.show(String(localized: "Backup exported"), style: .success)
                    case let .failure(error): toasts.show(error.localizedDescription, style: .failure)
                    }
                }
            } footer: {
                Label("Backup files are encrypted. Remember the backup password: without it a backup can't be restored.", systemImage: "lock.fill")
                    .font(.footnote)
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .task { await backups.refresh() }
        .refreshable { await backups.refresh() }
        .sheet(isPresented: $editingPassword) {
            BackupPasswordSheet(changing: vault.hasBackupPassword)
        }
        .sheet(isPresented: $showingList) {
            BackupListSheet { entry in
                showingList = false
                Task {
                    do {
                        let data = try await backups.read(entry)
                        try? await Task.sleep(for: .milliseconds(400))
                        importFlow.openBackup(data)
                    } catch {
                        toasts.show(error.localizedDescription, style: .failure)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: pickerMode == .folder ? [.folder] : [.data, .item]
        ) { result in
            handlePicked(result, mode: pickerMode)
        }
        .importFlow(importFlow)
    }

    private func backupNow() {
        Task {
            do {
                try await backups.backupNow()
                Haptics.success()
                toasts.show(String(localized: "Backup saved"), style: .success)
            } catch {
                Haptics.error()
                toasts.show(error.localizedDescription, style: .failure)
            }
        }
    }

    private func export() async {
        do {
            let data = try await backups.exportData()
            exportName = backups.exportFileName
            exportDocument = BackupFileDocument(data: data)
        } catch {
            toasts.show(error.localizedDescription, style: .failure)
        }
    }

    private func handlePicked(_ result: Result<URL, Error>, mode: PickerMode) {
        switch result {
        case let .failure(error):
            toasts.show(error.localizedDescription, style: .failure)
        case let .success(url):
            if mode == .folder {
                do {
                    try backups.useFolder(url)
                    Task { await backups.refresh() }
                } catch {
                    toasts.show(error.localizedDescription, style: .failure)
                }
            } else {
                Task {
                    do {
                        importFlow.openBackup(try await BackupManager.readPicked(url))
                    } catch {
                        toasts.show(error.localizedDescription, style: .failure)
                    }
                }
            }
        }
    }
}

/// Brand-gradient card when backups are on; a setup prompt otherwise.
private struct BackupStatusCard: View {
    let ready: Bool
    let busy: Bool
    let latest: Date?
    let count: Int?
    let onBackup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: ready ? "checkmark.icloud.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(ready ? Color.white : Color.orange)
                    .frame(width: 52, height: 52)
                    .background(ready ? Color.white.opacity(0.18) : Color.orange.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(ready ? "Backups Are On" : "Backups Are Off")
                        .font(.title3.weight(.semibold))
                    Text(ready ? "Backups are encrypted with your password and saved to the folder below." : "Set a backup password to start making encrypted backups.")
                        .font(.footnote)
                        .foregroundStyle(ready ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            if ready {
                HStack(spacing: 0) {
                    stat(title: "Last Backup") {
                        if let latest {
                            Text(latest, format: .relative(presentation: .named))
                        } else {
                            Text("Not Yet")
                        }
                    }
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 32)
                    stat(title: "Saved") {
                        if let count { Text(count, format: .number) } else { Text(verbatim: "—") }
                    }
                }
                .padding(.vertical, 12)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button(action: onBackup) {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().tint(Brand.gradientEnd)
                            Text("Backing Up…")
                        } else {
                            Image(systemName: "arrow.up.doc.fill")
                            Text("Back Up Now")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(Brand.gradientEnd)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .foregroundStyle(ready ? Color.white : Color.primary)
        .padding(20)
        .background {
            if ready {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Brand.gradient)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private func stat<Value: View>(title: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        VStack(spacing: 2) {
            value()
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
    }
}

/// A setup step: badge (with a tick once done), text and a capsule naming the action.
private struct SetupRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: Text
    let done: Bool
    let action: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                SettingsIcon(symbol: symbol, color: .accentColor)
                Image(systemName: done ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(done ? Color.green : Color(.systemGray3))
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-1.5))
                    .offset(x: 5, y: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                subtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(action)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(done ? Color.accentColor : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(done ? Color.accentColor.opacity(0.14) : Color.accentColor, in: Capsule())
        }
        .contentShape(Rectangle())
    }
}

/// New password typed twice; saving is blocked until both match.
private struct BackupPasswordSheet: View {
    let changing: Bool

    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @FocusState private var focus: Int?

    private var mismatch: Bool { !second.isEmpty && first != second }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $first)
                        .textContentType(.newPassword)
                        .focused($focus, equals: 0)
                        .submitLabel(.next)
                        .onSubmit { focus = 1 }
                    SecureField("Confirm Password", text: $second)
                        .textContentType(.newPassword)
                        .focused($focus, equals: 1)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if mismatch {
                        Text("The passwords don't match.").foregroundStyle(.red)
                    } else {
                        Text("This password only encrypts backup files and is separate from App Lock. If you forget it, your backups can't be restored.")
                    }
                }
            }
            .navigationTitle(changing ? Text("Change Backup Password") : Text("Set Backup Password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(first.isEmpty || first != second)
                }
            }
            .onAppear { focus = 0 }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !first.isEmpty, first == second else { return }
        do {
            try vault.setBackupPassword(first)
            Haptics.success()
            toasts.show(String(localized: "Backup password saved"), style: .success)
            dismiss()
        } catch {
            toasts.show(error.localizedDescription, style: .failure)
        }
    }
}

/// Backups in the folder, newest first.
private struct BackupListSheet: View {
    let onPick: (BackupEntry) -> Void

    @EnvironmentObject private var backups: BackupManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let entries = backups.entries, !entries.isEmpty {
                    Section {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Button { onPick(entry) } label: { row(entry, latest: index == 0) }
                        }
                    } footer: {
                        Text("Pick a backup, enter its password and review what will be imported.")
                    }
                }
            }
            .overlay {
                if let entries = backups.entries {
                    if entries.isEmpty {
                        ContentUnavailableView {
                            Label("No Backups", systemImage: "tray")
                        } description: {
                            Text("There are no backups in \(backups.folderName). Check the folder, or import a backup file instead.")
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Choose a Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .refreshable { await backups.refresh() }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ entry: BackupEntry, latest: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isPlaceholder ? "icloud.and.arrow.down" : "doc.fill")
                .font(.title3)
                .foregroundStyle(latest ? Color.accentColor : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.primary)
                    if latest {
                        Text("Latest")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                Text(verbatim: "\(entry.modifiedAt.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Encrypted backup bytes for `fileExporter`.
struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
