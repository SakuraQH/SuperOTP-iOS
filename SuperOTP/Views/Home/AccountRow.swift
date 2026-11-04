import SuperOTPKit
import SwiftUI

/// One account: icon, labels and the code; the countdown ring (TOTP) or the next-code button
/// (HOTP) on the right. Tapping copies or reveals; long press opens the context menu.
struct AccountRow: View {
    let account: OtpAccount
    let display: DisplayMode
    /// Time step at which the code was revealed (TOTP), or any value for counter-based codes.
    let revealedMark: Int?
    let hideCodes: Bool
    let tapToCopy: Bool
    let copied: Bool
    let editing: Bool
    let onTap: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                TimelineView(.periodic(from: Self.secondBoundary, by: 1)) { context in
                    content(now: context.date)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!editing)

            if account.type == .hotp {
                VStack(spacing: 3) {
                    Button(action: onNext) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(editing)
                    .accessibilityLabel(Text("Next Code"))
                    Text(verbatim: "#\(account.counter)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Whole seconds, so the code flips exactly at the period boundary.
    private static var secondBoundary: Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func content(now: Date) -> some View {
        let labels = displayLabels(account, display)
        let code = currentCode(account, at: now)
        let shown = isShown(now: now)
        let masked = code == nil || !shown
        let remaining = secondsRemaining(account, at: now)
        let urgent = account.type == .totp && remaining <= 5
        let codeStyle: AnyShapeStyle
        if masked {
            codeStyle = AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        } else if urgent {
            codeStyle = AnyShapeStyle(Color.red)
        } else {
            codeStyle = AnyShapeStyle(TintShapeStyle.tint)
        }
        let spoken: Text = masked ? Text("Code hidden") : Text(verbatim: (code ?? "").map { String($0) }.joined(separator: " "))
        return HStack(spacing: 14) {
            AccountIcon(account: account, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(labels.title.isEmpty ? "—" : labels.title)
                        .font(.headline)
                        .lineLimit(1)
                    if account.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .rotationEffect(.degrees(45))
                            .accessibilityLabel(Text("Pinned"))
                    }
                }
                if let subtitle = labels.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(verbatim: codeText(code, masked: masked))
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .tracking(1)
                        .foregroundStyle(codeStyle)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel(spoken)
                    if copied {
                        CopiedBadge().transition(.scale.combined(with: .opacity))
                    } else if masked && code != nil && !editing {
                        Text(tapToCopy ? "Tap to copy" : "Tap to reveal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
                .animation(.snappy, value: copied)
            }
            Spacer(minLength: 4)
            if account.type == .totp {
                CountdownRing(period: account.period)
            }
        }
    }

    private func isShown(now: Date) -> Bool {
        if !hideCodes { return true }
        guard let mark = revealedMark else { return false }
        return account.type != .totp || mark == timeStep(account, at: now)
    }

    private func codeText(_ code: String?, masked: Bool) -> String {
        guard let code else { return "—" }
        return masked ? maskedCode(digits: account.digits) : groupCode(code)
    }
}

/// Ring that drains clockwise with the seconds left in the middle.
struct CountdownRing: View {
    let period: Int
    var size: CGFloat = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let total = Double(max(1, period))
            let remaining = total - context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: total)
            let tint: Color = remaining <= 5 ? .red : remaining <= 10 ? .orange : .accentColor
            ZStack {
                Circle()
                    .stroke(Color(.systemFill), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: remaining / total)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: "\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.3), value: tint)
        }
        .accessibilityHidden(true)
    }
}

struct CopiedBadge: View {
    var body: some View {
        Label("Copied", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14), in: Capsule())
    }
}
