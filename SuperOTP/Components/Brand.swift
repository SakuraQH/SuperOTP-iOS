import CoreImage.CIFilterBuiltins
import SuperOTPKit
import SwiftUI

/// Design tokens: one indigo-blue brand colour (the asset catalog's AccentColor) on system
/// grouped backgrounds; colour is reserved for the brand, the countdown and destructive actions.
enum Brand {
    static let gradientStart = Color(red: 0x5C / 255, green: 0x7C / 255, blue: 0xFF / 255)
    static let gradientEnd = Color(red: 0x23 / 255, green: 0x38 / 255, blue: 0xC8 / 255)
    static let gradient = LinearGradient(colors: [gradientStart, gradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The app icon drawn in place: brand gradient tile with the shield-and-countdown mark.
struct AppLogo: View {
    var size: CGFloat
    /// On the brand gradient the tile becomes a translucent white square instead.
    var onGradient = false

    var body: some View {
        ZStack {
            if onGradient {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(.white.opacity(0.16))
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Brand.gradient)
            }
            LogoMark(color: .white)
                .frame(width: size * 1.3, height: size * 1.3)
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The launcher glyph from the Android project (108-unit viewport): a three-quarter countdown
/// ring, a tick in the gap and a shield with a keyhole cut out.
struct LogoMark: View {
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width, geo.size.height) / 108
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: 4.5 * unit, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 54 * unit, height: 54 * unit)
                Circle()
                    .fill(color.opacity(0.75))
                    .frame(width: 4.8 * unit, height: 4.8 * unit)
                    .position(x: 34.9 * unit, y: 34.9 * unit)
                ShieldShape()
                    .fill(color, style: FillStyle(eoFill: true))
            }
            .frame(width: 108 * unit, height: 108 * unit)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Shield with a keyhole (even-odd), scaled by 0.86 around the centre like the vector drawable.
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 108
        let originX = rect.midX - 54 * unit
        let originY = rect.midY - 54 * unit
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + (54 + (x - 54) * 0.86) * unit, y: originY + (54 + (y - 54) * 0.86) * unit)
        }
        var path = Path()
        path.move(to: p(54, 32.5))
        path.addCurve(to: p(70, 37.6), control1: p(58.8, 35.2), control2: p(64.2, 37))
        path.addLine(to: p(70, 52))
        path.addCurve(to: p(54, 75.5), control1: p(70, 63), control2: p(63.2, 71.2))
        path.addCurve(to: p(38, 52), control1: p(44.8, 71.2), control2: p(38, 63))
        path.addLine(to: p(38, 37.6))
        path.addCurve(to: p(54, 32.5), control1: p(43.8, 37), control2: p(49.2, 35.2))
        path.closeSubpath()

        // Keyhole: circle of radius 5 around (54, 49) over the top, then the tapered stem.
        let start = atan2(53.54 - 49, 51.9 - 54)
        let end = atan2(53.54 - 49, 56.1 - 54) + 2 * Double.pi
        let steps = 40
        path.move(to: p(51.9, 53.54))
        for step in 1...steps {
            let angle = start + (end - start) * Double(step) / Double(steps)
            path.addLine(to: p(54 + 5 * CGFloat(cos(angle)), 49 + 5 * CGFloat(sin(angle))))
        }
        path.addLine(to: p(57.3, 61.2))
        path.addQuadCurve(to: p(56, 62.6), control: p(57.5, 62.6))
        path.addLine(to: p(52, 62.6))
        path.addQuadCurve(to: p(50.7, 61.2), control: p(50.5, 62.6))
        path.closeSubpath()
        return path
    }
}

/// Initial on a soft gradient tile; the hue is stable per name (same palette as Android).
struct LetterAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = Brand.color(hex: letterColor(trimmed.isEmpty ? "?" : trimmed))
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [base.opacity(0.78), base], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(trimmed.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

/// Account icon: picked picture or favicon, else the bundled brand icon, else a letter.
struct AccountIcon: View {
    let account: OtpAccount
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            if let image = IconStore.image(for: account.imagePath) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let asset = brandAsset {
                Image(asset).resizable().scaledToFill()
            } else {
                LetterAvatar(name: account.issuer.isEmpty ? account.account : account.issuer, size: size)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var brandAsset: String? {
        let path = account.imagePath
        if path == "letter" || path.hasPrefix("letter:") { return nil }
        guard let file = BrandIcons.lightFile(for: path) ?? BrandIcons.matchFile(account.issuer) else { return nil }
        return BrandIcons.assetName(forFile: file)
    }
}

/// A bundled brand icon by file name.
struct BrandGlyph: View {
    let file: String
    var size: CGFloat = 44

    var body: some View {
        Image(BrandIcons.assetName(forFile: file))
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Coloured rounded square with a white SF Symbol, as in the iOS Settings app.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Settings-style row label: badge + title.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color

    init(_ title: LocalizedStringKey, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol, color: color)
        }
    }
}

/// Capsule filter chip; brand colour when selected.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum QRCode {
    /// Crisp black-on-white QR image for the text.
    static func image(for text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
