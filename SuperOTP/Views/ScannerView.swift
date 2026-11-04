import AVFoundation
import PhotosUI
import SwiftUI

/// Full-screen QR scanner with a viewfinder, torch and a shortcut to pick a photo.
struct ScannerView: View {
    let onResult: (String) -> Void

    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var camera = CameraModel()
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoItem: PhotosPickerItem?

    init(onResult: @escaping (String) -> Void) {
        self.onResult = onResult
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch permission {
            case .authorized:
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                Viewfinder()
                controls
            case .notDetermined:
                ProgressView().tint(.white)
            default:
                denied
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .task {
            if permission == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                permission = granted ? .authorized : .denied
            }
            if permission == .authorized {
                camera.onCode = { code in
                    Haptics.success()
                    onResult(code)
                }
                camera.start()
            }
        }
        .onDisappear { camera.stop() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let text = await QRImageReader.decode(item) {
                    onResult(text)
                } else {
                    toasts.show(String(localized: "No QR code found in this picture"), style: .failure)
                }
            }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(Text("Close"))
                Spacer()
                Text("Scan QR Code")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
            Text("Point the camera at the QR code shown by the service")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 48) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    ScanAction(symbol: "photo.on.rectangle", title: "Photos", active: false)
                }
                .buttonStyle(.plain)
                if camera.torchAvailable {
                    Button {
                        camera.torchOn.toggle()
                    } label: {
                        ScanAction(symbol: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", title: "Flashlight", active: camera.torchOn)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
    }

    private var denied: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close") { dismiss() }
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(16)
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "camera.fill")
            } description: {
                Text("Allow camera access in Settings to scan QR codes, or read a QR code from a photo instead.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text("Choose from Photos")
                }
            }
            .foregroundStyle(.white)
        }
    }
}

private struct ScanAction: View {
    let symbol: String
    let title: LocalizedStringKey
    let active: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(active ? .black : .white)
                .frame(width: 58, height: 58)
                .background(active ? Color.white : Color.white.opacity(0.18), in: Circle())
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
    }
}

/// Dimmed overlay with a rounded window, corner brackets and a sweeping scan line.
private struct Viewfinder: View {
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.68
            let rect = CGRect(
                x: (geo.size.width - side) / 2,
                y: (geo.size.height - side) / 2 - geo.size.height * 0.05,
                width: side,
                height: side
            )
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 24, height: 24), style: .continuous)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                CornerBrackets(rect: rect)
                    .stroke(Brand.gradientStart, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                LinearGradient(colors: [.clear, Brand.gradientStart.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: side - 32, height: 2)
                    .offset(x: rect.minX + 16, y: rect.minY + 12 + (sweep ? side - 24 : 0))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: true)) { sweep = true }
        }
    }
}

private struct CornerBrackets: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        let length: CGFloat = 28
        let radius: CGFloat = 24
        var path = Path()
        // Top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius + length, y: rect.minY))
        // Top right
        path.move(to: CGPoint(x: rect.maxX - radius - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius + length))
        // Bottom right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - radius - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius - length, y: rect.maxY))
        // Bottom left
        path.move(to: CGPoint(x: rect.minX + radius + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius - length))
        return path
    }
}

// MARK: - Camera

/// Capture session with a QR metadata output. Delegate callbacks arrive on the main queue.
final class CameraModel: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    @Published var torchAvailable = false
    @Published var torchOn = false {
        didSet { applyTorch() }
    }

    var onCode: ((String) -> Void)?
    private let queue = DispatchQueue(label: "app.superotp.camera")
    private var configured = false
    private var delivered = false
    private var device: AVCaptureDevice?

    func start() {
        delivered = false
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        if torchOn { torchOn = false }
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        }
        session.commitConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus), (try? device.lockForConfiguration()) != nil {
            device.focusMode = .continuousAutoFocus
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        let hasTorch = device.hasTorch
        DispatchQueue.main.async { [weak self] in
            self?.device = device
            self?.torchAvailable = hasTorch
        }
    }

    private func applyTorch() {
        guard let device, device.hasTorch else { return }
        let on = torchOn
        queue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject, let value = code.stringValue, !value.isEmpty else { continue }
            delivered = true
            onCode?(value)
            return
        }
    }
}

/// Live camera preview; keeps the video upright on iPad as the interface rotates.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection, let orientation = window?.windowScene?.interfaceOrientation else { return }
            let angle: CGFloat
            switch orientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}
