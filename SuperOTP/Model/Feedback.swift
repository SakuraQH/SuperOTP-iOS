import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

@MainActor
enum Clipboard {
    /// Copies text; with `expiresAfter` > 0 the system removes it from the clipboard later.
    static func copy(_ text: String, expiresAfter seconds: Int) {
        var options: [UIPasteboard.OptionsKey: Any] = [:]
        if seconds > 0 { options[.expirationDate] = Date().addingTimeInterval(TimeInterval(seconds)) }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: options)
    }

    static func readText() -> String? {
        UIPasteboard.general.string
    }
}

/// Short confirmation capsule ("Copied", "Backup saved") shown above everything, sheets included.
@MainActor
final class ToastCenter: ObservableObject {
    struct Toast: Identifiable, Equatable {
        enum Style { case info, success, failure }
        let id = UUID()
        let text: String
        let style: Style
    }

    @Published private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?
    private let window = OverlayWindow(level: UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 10), interactive: false)

    func show(_ text: String, style: Toast.Style = .info) {
        let toast = Toast(text: text, style: style)
        window.show(AnyView(ToastHost(center: self)))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { current = toast }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.25)) { self.current = nil }
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            self.window.hide()
        }
    }
}

private struct ToastHost: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 8) {
                    switch toast.style {
                    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    case .info: EmptyView()
                    }
                    Text(toast.text)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .combine)
    }
}

/// A window above the app's main window (and its sheets) for the lock screen, the privacy
/// cover and toasts.
@MainActor
final class OverlayWindow {
    private var window: UIWindow?
    private let level: UIWindow.Level
    private let interactive: Bool

    init(level: UIWindow.Level, interactive: Bool) {
        self.level = level
        self.interactive = interactive
    }

    var isVisible: Bool { window != nil }

    func show(_ content: AnyView, style: UIUserInterfaceStyle? = nil) {
        if let window {
            if let style { window.overrideUserInterfaceStyle = style }
            return
        }
        guard let scene = Self.activeScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = level
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = interactive
        window.overrideUserInterfaceStyle = style ?? Self.mainWindow?.overrideUserInterfaceStyle ?? .unspecified
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        window.rootViewController = host
        if interactive {
            window.makeKeyAndVisible()
        } else {
            window.isHidden = false
        }
        self.window = window
    }

    func hide() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        if interactive { Self.mainWindow?.makeKey() }
    }

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static var mainWindow: UIWindow? {
        activeScene?.windows.first { $0.windowLevel == .normal }
    }

    /// Applies the theme to every window, including sheets, alerts and overlays.
    static func applyStyle(_ style: UIUserInterfaceStyle) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}
