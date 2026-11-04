import CoreImage
import PhotosUI
import SuperOTPKit
import SwiftUI
import Vision

/// Turns scanned / pasted text and backup files into an import preview. Each screen that can
/// start an import owns one and attaches `.importFlow(_:)`, so the preview is presented from
/// the topmost view.
@MainActor
final class ImportFlow: ObservableObject {
    @Published var prepared: PreparedImport?
    @Published var askPassword = false
    @Published var password = ""
    @Published private(set) var decrypting = false
    private var pendingBackup: Data?

    func openText(_ text: String, vault: VaultStore, toasts: ToastCenter) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toasts.show(String(localized: "No verification code found"), style: .failure)
            return
        }
        let bundle = parseImportText(trimmed)
        show(prepareImport(tokens: bundle.tokens, categories: bundle.categories, existing: vault.accounts, invalid: bundle.invalid), toasts: toasts)
    }

    func openBackup(_ data: Data) {
        pendingBackup = data
        password = ""
        askPassword = true
    }

    func submitPassword(vault: VaultStore, toasts: ToastCenter) async {
        guard let data = pendingBackup else { return }
        let password = self.password
        self.password = ""
        decrypting = true
        defer { decrypting = false }
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try CloudOtpBackup.decrypt(data, password: password)
            }.value
            pendingBackup = nil
            show(prepareImport(tokens: document.tokens, categories: document.categories, existing: vault.accounts), toasts: toasts)
        } catch let failure as BackupFailure {
            pendingBackup = nil
            toasts.show(Self.message(for: failure), style: .failure)
        } catch {
            pendingBackup = nil
            toasts.show(error.localizedDescription, style: .failure)
        }
    }

    func cancelPassword() {
        pendingBackup = nil
        password = ""
    }

    private func show(_ prepared: PreparedImport, toasts: ToastCenter) {
        if prepared.isEmpty {
            toasts.show(String(localized: "No verification code found"), style: .failure)
        } else {
            Haptics.success()
            self.prepared = prepared
        }
    }

    static func message(for failure: BackupFailure) -> String {
        switch failure {
        case .emptyPassword: return String(localized: "Enter the backup password")
        case .notBackup: return String(localized: "This is not a SuperOTP or CloudOTP backup")
        case .badPassword: return String(localized: "Wrong password, or the file is damaged")
        case .unsupportedVersion: return String(localized: "This backup was made by a newer version")
        case .badFormat: return String(localized: "The backup could not be read")
        }
    }
}

struct ImportFlowModifier: ViewModifier {
    @ObservedObject var flow: ImportFlow
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var toasts: ToastCenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.prepared) { prepared in
                ImportPreviewView(prepared: prepared)
            }
            .alert("Backup Password", isPresented: $flow.askPassword) {
                SecureField("Password", text: $flow.password)
                Button("Cancel", role: .cancel) { flow.cancelPassword() }
                Button("Open") {
                    Task { await flow.submitPassword(vault: vault, toasts: toasts) }
                }
            } message: {
                Text("Enter the password that was used to encrypt this backup.")
            }
            .overlay {
                if flow.decrypting {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Decrypting…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
    }
}

extension View {
    func importFlow(_ flow: ImportFlow) -> some View {
        modifier(ImportFlowModifier(flow: flow))
    }
}

/// QR codes in a picture. Several codes (for example a multi-page Google export) become
/// several lines, which the importer reads one by one.
enum QRImageReader {
    static func decode(_ data: Data) async -> String? {
        await Task.detached(priority: .userInitiated) { QRImageReader.decodeSync(data) }.value
    }

    static func decodeSync(_ data: Data) -> String? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        var found: [String] = []
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        if (try? handler.perform([request])) != nil {
            for observation in request.results ?? [] {
                if let value = observation.payloadStringValue, !value.isEmpty, !found.contains(value) { found.append(value) }
            }
        }
        if found.isEmpty {
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            for feature in detector?.features(in: image) ?? [] {
                if let value = (feature as? CIQRCodeFeature)?.messageString, !value.isEmpty, !found.contains(value) { found.append(value) }
            }
        }
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    /// Loads a picked photo and decodes the QR codes in it.
    static func decode(_ item: PhotosPickerItem) async -> String? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await decode(data)
    }
}
