import SuperOTPKit
import SwiftUI

/// Add (accountId == nil) or edit an account.
struct EditAccountView: View {
    let accountId: Int?
    let defaultGroupUid: String?

    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var issuer = ""
    @State private var accountName = ""
    @State private var secret = ""
    @State private var type: OtpType = .totp
    @State private var algorithm: OtpAlgorithm = .sha1
    @State private var digits = 6
    @State private var period = "30"
    @State private var counter = "0"
    @State private var groupUid: String?
    @State private var revealSecret = false
    @State private var advanced = false
    @State private var error: FieldError?
    @State private var duplicate: OtpAccount?

    private enum FieldError {
        case name
        case secret
        case period
        case counter

        var message: LocalizedStringKey {
            switch self {
            case .name: return "Enter a service name or an account name."
            case .secret: return "The setup key isn't valid Base32 (letters A–Z and digits 2–7)."
            case .period: return "The period must be a whole number of seconds greater than 0."
            case .counter: return "The counter must be a whole number of 0 or more."
            }
        }
    }

    private var existing: OtpAccount? {
        accountId.flatMap { id in vault.accounts.first { $0.id == id } }
    }

    private var digitOptions: [Int] {
        [6, 8].contains(digits) ? [6, 8] : [digits, 6, 8]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    TextField("Service (e.g. GitHub)", text: $issuer)
                        .textContentType(.organizationName)
                        .autocorrectionDisabled()
                    TextField("Account (e.g. name@example.com)", text: $accountName)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Group {
                            if revealSecret {
                                TextField("Setup Key", text: $secret)
                            } else {
                                SecureField("Setup Key", text: $secret)
                            }
                        }
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        Button {
                            revealSecret.toggle()
                        } label: {
                            Image(systemName: revealSecret ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(revealSecret ? Text("Hide Setup Key") : Text("Show Setup Key"))
                    }
                } header: {
                    Text("Account")
                } footer: {
                    if let error, error == .name || error == .secret {
                        Text(error.message).foregroundStyle(.red)
                    }
                }

                if !vault.categories.isEmpty {
                    Section {
                        Picker("Group", selection: $groupUid) {
                            Text("No Group").tag(String?.none)
                            ForEach(sortGroups(vault.categories)) { group in
                                Text(group.title).tag(String?.some(group.uid))
                            }
                        }
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Type").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Type", selection: $type) {
                                Text(verbatim: "TOTP").tag(OtpType.totp)
                                Text(verbatim: "HOTP").tag(OtpType.hotp)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Algorithm").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Algorithm", selection: $algorithm) {
                                ForEach(OtpAlgorithm.allCases, id: \.self) { item in
                                    Text(verbatim: item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Digits").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Digits", selection: $digits) {
                                ForEach(digitOptions, id: \.self) { value in
                                    Text(verbatim: "\(value)").tag(value)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                        if type == .hotp {
                            LabeledContent("Counter") {
                                TextField("0", text: $counter)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        } else {
                            LabeledContent("Period (seconds)") {
                                TextField("30", text: $period)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Advanced")
                            Text(verbatim: "\(type == .hotp ? "HOTP" : "TOTP") · \(algorithm.rawValue) · \(digits)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if let error, error == .period || error == .counter {
                        Text(error.message).foregroundStyle(.red)
                    } else {
                        Text("Most services use TOTP, SHA1, 6 digits and 30 seconds. Change these only if the service says so.")
                    }
                }
            }
            .navigationTitle(accountId == nil ? Text("Add Account") : Text("Edit Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(issuer.isBlank && accountName.isBlank)
                }
            }
            .onAppear(perform: load)
            .alert("Account Already Exists", isPresented: Binding(isPresent: $duplicate), presenting: duplicate) { match in
                Button("Replace") { commit(base: match) }
                Button("Add Anyway") { commit(base: nil) }
                Button("Cancel", role: .cancel) {}
            } message: { match in
                Text("“\(label(of: match))” is already on this device. Replace it, or keep both.")
            }
        }
    }

    private var preview: some View {
        let draft = OtpAccount(
            uid: existing?.uid ?? "preview",
            issuer: issuer,
            secret: "",
            account: accountName,
            imagePath: existing?.imagePath ?? ""
        )
        let title = issuer.isBlank ? accountName : issuer
        return VStack(spacing: 10) {
            AccountIcon(account: draft, size: 72)
                .animation(.default, value: issuer)
            Text(title.isBlank ? String(localized: "New Account") : title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(title.isBlank ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let account = existing {
            issuer = account.issuer
            accountName = account.account
            secret = account.secret
            type = account.type == .hotp ? .hotp : .totp
            algorithm = account.algorithm
            digits = account.digits
            period = String(account.period)
            counter = String(account.counter)
            groupUid = groupOf(account, vault.categories)?.uid
            advanced = account.type != .totp || account.algorithm != .sha1 || account.digits != 6 || account.period != 30
        } else {
            groupUid = defaultGroupUid.flatMap { uid in vault.categories.contains { $0.uid == uid } ? uid : nil }
        }
    }

    private func validated() -> OtpAccount? {
        let cleanSecret = secret.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let periodValue = Int(period.trimmingCharacters(in: .whitespaces)) ?? 0
        let counterValue = Int(counter.trimmingCharacters(in: .whitespaces))
        if issuer.isBlank && accountName.isBlank {
            error = .name
        } else if !isBase32(cleanSecret) {
            error = .secret
        } else if type == .totp && periodValue <= 0 {
            error = .period
            advanced = true
        } else if type == .hotp && (counterValue ?? -1) < 0 {
            error = .counter
            advanced = true
        } else {
            error = nil
        }
        if error != nil {
            Haptics.error()
            return nil
        }
        return OtpAccount(
            uid: UUID().uuidString.lowercased(),
            issuer: issuer.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: cleanSecret,
            account: accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            algorithm: algorithm,
            digits: digits,
            counter: type == .hotp ? (counterValue ?? 0) : 0,
            period: type == .totp ? periodValue : 30
        )
    }

    private func save() {
        guard let draft = validated() else { return }
        if existing == nil, let match = vault.accounts.first(where: { sameIdentity($0, draft) }) {
            duplicate = match
            return
        }
        commit(base: existing)
    }

    /// Writes the form over `base` (keeping its id, order, icon and pin) or as a new account.
    private func commit(base: OtpAccount?) {
        guard var stored = validated() else { return }
        if let base {
            stored.id = base.id
            stored.uid = base.uid
            stored.seq = base.seq
            stored.imagePath = base.imagePath
            stored.pinned = base.pinned
            stored.createdAt = base.createdAt
            stored.remark = base.remark
            stored.copyTimes = base.copyTimes
            stored.pin = base.pin
            stored.lastCopyAt = base.lastCopyAt
            stored.note = base.note
            stored.tags = base.tags
            if stored.type != .totp { stored.period = base.period }
            if stored.type != .hotp { stored.counter = base.counter }
        }
        let group = groupUid.flatMap { uid in vault.categories.contains { $0.uid == uid } ? uid : nil }
        vault.save(stored, groupUid: group)
        Haptics.success()
        dismiss()
    }

    private func label(of account: OtpAccount) -> String {
        account.issuer.isBlank ? account.account : account.issuer
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
