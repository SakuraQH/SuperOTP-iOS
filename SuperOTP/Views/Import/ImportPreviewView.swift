import SuperOTPKit
import SwiftUI

/// What an import would do: new accounts can be switched off, accounts already on the device
/// can be added again, skipped or overwritten.
struct ImportPreviewView: View {
    let prepared: PreparedImport

    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [RowChoice]
    @State private var result: (added: Int, replaced: Int, skipped: Int)?

    init(prepared: PreparedImport) {
        self.prepared = prepared
        _choices = State(initialValue: prepared.defaultChoices)
    }

    private var newIndexes: [Int] { prepared.rows.indices.filter { prepared.rows[$0].isNew } }
    private var existingIndexes: [Int] { prepared.rows.indices.filter { !prepared.rows[$0].isNew } }
    private var writeCount: Int { choices.filter { $0 != .skip }.count }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    done(result)
                } else {
                    list
                }
            }
            .navigationTitle(result == nil ? Text("Import") : Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(result == nil && writeCount > 0)
    }

    private var list: some View {
        List {
            Section {
                summary
            }
            if !newIndexes.isEmpty {
                Section {
                    ForEach(newIndexes, id: \.self) { index in
                        ImportAccountRow(account: prepared.rows[index].account) {
                            Toggle("Import", isOn: Binding(
                                get: { choices[index] == .add },
                                set: { choices[index] = $0 ? .add : .skip }
                            ))
                            .labelsHidden()
                        }
                    }
                } header: {
                    HStack {
                        Text("New Accounts")
                        Spacer()
                        Menu {
                            Button("Import All") { set(newIndexes, .add) }
                            Button("Import None") { set(newIndexes, .skip) }
                        } label: {
                            Text("Quick Select").font(.footnote.weight(.semibold))
                        }
                        .textCase(nil)
                    }
                }
            }
            if !existingIndexes.isEmpty {
                Section {
                    ForEach(existingIndexes, id: \.self) { index in
                        ImportAccountRow(account: prepared.rows[index].account) {
                            Picker("Action", selection: $choices[index]) {
                                Text("Skip").tag(RowChoice.skip)
                                Text("Add New").tag(RowChoice.add)
                                Text("Overwrite").tag(RowChoice.overwrite)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(choices[index] == .overwrite ? .red : .accentColor)
                        }
                    }
                } header: {
                    HStack {
                        Text("Already on This Device")
                        Spacer()
                        Menu {
                            Button("Skip All") { set(existingIndexes, .skip) }
                            Button("Add All as New") { set(existingIndexes, .add) }
                            Button("Overwrite All", role: .destructive) { set(existingIndexes, .overwrite) }
                        } label: {
                            Text("Set All").font(.footnote.weight(.semibold))
                        }
                        .textCase(nil)
                    }
                } footer: {
                    Text("Overwrite replaces the account on this device and keeps its place in the list.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: apply) {
                Group {
                    if writeCount > 0 {
                        Text("Import \(writeCount) Accounts")
                    } else if !prepared.categories.isEmpty {
                        Text("Merge Groups")
                    } else {
                        Text("Nothing to Import")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(writeCount == 0 && prepared.categories.isEmpty)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("\(prepared.rows.count) accounts found")
                    .font(.headline)
                if !prepared.rows.isEmpty {
                    Text("\(newIndexes.count) new, \(existingIndexes.count) already on this device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !prepared.categories.isEmpty {
                    Text("\(prepared.categories.count) groups will be merged")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if prepared.skippedOtherTypes > 0 {
                    Text("\(prepared.skippedOtherTypes) skipped: only TOTP and HOTP are supported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if prepared.invalid > 0 {
                    Text("\(prepared.invalid) entries could not be read")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func done(_ result: (added: Int, replaced: Int, skipped: Int)) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Import Complete")
                .font(.title2.bold())
            Text("Added \(result.added), overwritten \(result.replaced), skipped \(result.skipped).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(24)
    }

    private func set(_ indexes: [Int], _ choice: RowChoice) {
        for index in indexes { choices[index] = choice }
    }

    private func apply() {
        let resolved = resolveImport(rows: prepared.rows, choices: choices, categories: prepared.categories)
        vault.commitImport(resolved)
        Haptics.success()
        withAnimation {
            result = (
                choices.filter { $0 == .add }.count,
                choices.filter { $0 == .overwrite }.count,
                choices.filter { $0 == .skip }.count
            )
        }
    }
}

private struct ImportAccountRow<Trailing: View>: View {
    let account: OtpAccount
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            AccountIcon(account: account, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                let title = account.issuer.isBlank ? account.account : account.issuer
                Text(title.isBlank ? "—" : title)
                    .font(.headline)
                    .lineLimit(1)
                if !account.account.isBlank && account.account != title {
                    Text(account.account)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: "\(account.type.label) · \(account.algorithm.rawValue) · \(account.digits)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
