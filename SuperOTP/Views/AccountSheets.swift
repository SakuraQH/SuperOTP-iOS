import PhotosUI
import SuperOTPKit
import SwiftUI

/// The account as a QR code, for moving it to another authenticator.
struct QRCodeSheet: View {
    let account: OtpAccount

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false

    var body: some View {
        let labels = displayLabels(account, settings.display)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AccountIcon(account: account, size: 52)
                    VStack(spacing: 2) {
                        Text(labels.title.isEmpty ? "—" : labels.title)
                            .font(.title3.weight(.semibold))
                        if let subtitle = labels.subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    ZStack {
                        if let image = QRCode.image(for: otpauthUri(account)) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(16)
                                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .blur(radius: revealed ? 0 : 14)
                                .accessibilityLabel(Text("QR Code"))
                        }
                        if !revealed {
                            Button {
                                withAnimation(.easeOut(duration: 0.25)) { revealed = true }
                            } label: {
                                Label("Tap to Show", systemImage: "eye")
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 280)
                    Label("This QR code contains the secret key. Don't take screenshots of it or share it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(24)
            }
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Change an account's icon: a photo, a website favicon, a bundled brand icon or a letter.
struct IconPickerView: View {
    let account: OtpAccount

    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var search = ""
    @State private var fetching = false
    @State private var photoItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AccountIcon(account: vault.accounts.first { $0.id == account.id } ?? account, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.issuer.isBlank ? account.account : account.issuer)
                                .font(.headline)
                            Text("Current Icon")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        pick("letter:")
                    } label: {
                        Label("Use Letter Avatar", systemImage: "character.textbox")
                    }
                }

                Section {
                    HStack {
                        TextField("example.com", text: $domain)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(fetch)
                        if fetching {
                            ProgressView()
                        } else {
                            Button("Fetch", action: fetch)
                                .disabled(safeHost(domain) == nil)
                        }
                    }
                } header: {
                    Text("Website Icon")
                } footer: {
                    Text("Downloads https://\(safeHost(domain) ?? "example.com")/favicon.ico. This is the only time SuperOTP goes online.")
                }

                Section {
                    TextField("Search Icons", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    let matches = BrandIcons.search(search, limit: 120)
                    if matches.isEmpty {
                        Text("No matching icons").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(matches, id: \.self) { file in
                                Button {
                                    pick(file)
                                } label: {
                                    BrandGlyph(file: file, size: 48)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: String(file.dropLast(4))))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("Built-in Icons")
                }
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if domain.isEmpty { domain = Self.guessDomain(account.issuer) }
                if search.isEmpty { search = account.issuer }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let path = IconStore.saveUserIcon(uid: account.uid, data: data) else {
                        toasts.show(String(localized: "That picture couldn't be used"), style: .failure)
                        return
                    }
                    pick(path)
                }
            }
        }
    }

    private func pick(_ path: String) {
        vault.setImage(id: account.id, imagePath: path)
        Haptics.success()
        dismiss()
    }

    private func fetch() {
        guard !fetching, safeHost(domain) != nil else { return }
        fetching = true
        Task {
            let path = await FaviconFetcher.fetch(domain)
            fetching = false
            if let path {
                pick(path)
            } else {
                Haptics.error()
                toasts.show(String(localized: "Couldn't get an icon from this website"), style: .failure)
            }
        }
    }

    /// "GitHub" -> "github.com"; leaves anything that already looks like a domain alone.
    private static func guessDomain(_ issuer: String) -> String {
        let trimmed = issuer.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return "" }
        if trimmed.contains(".") { return trimmed }
        let letters = trimmed.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return letters.isEmpty ? "" : letters + ".com"
    }
}
