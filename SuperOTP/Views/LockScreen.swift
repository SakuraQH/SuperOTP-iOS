import SwiftUI

/// Brand-gradient lock screen: logo, prompt and a large biometric button that pulses.
struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock
    @State private var pulse = false

    var body: some View {
        ZStack {
            BrandBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                AppLogo(size: 96, onGradient: true)
                Text(verbatim: "SuperOTP")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .padding(.top, 20)
                Text("Verify your identity to view your codes")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Spacer()
                if lock.canAuthenticate {
                    unlockButton
                } else {
                    unavailable
                }
                Group {
                    if let message = lock.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.18), in: Capsule())
                    }
                }
                .frame(height: 56)
            }
            .padding(28)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var unlockButton: some View {
        VStack(spacing: 10) {
            Button {
                Task { await lock.unlock() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(pulse ? 0 : 0.35))
                        .frame(width: 80, height: 80)
                        .scaleEffect(pulse ? 1.4 : 1)
                    Circle()
                        .fill(.white)
                        .frame(width: 80, height: 80)
                    Image(systemName: lock.symbol)
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(Brand.gradientEnd)
                }
                .frame(width: 124, height: 124)
            }
            .buttonStyle(.plain)
            .disabled(lock.authenticating)
            .accessibilityLabel(Text("Unlock with \(lock.methodName)"))
            Text("Tap to unlock with \(lock.methodName)")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var unavailable: some View {
        VStack(spacing: 16) {
            Text("This device has no passcode or biometrics set up, so App Lock can't be used.")
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button {
                lock.enterWithoutLock()
            } label: {
                Text("Turn Off App Lock and Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.gradientEnd)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
