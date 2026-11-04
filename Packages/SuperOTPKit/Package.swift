// swift-tools-version:5.9
import PackageDescription

// Platform-independent core of SuperOTP: OTP algorithms, import/export formats, the
// CloudOTP-compatible encrypted backup and the vault data model. The iOS app adds
// storage, Keychain and UI on top of it.
var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = ["CArgon2"]

#if os(Linux)
// CryptoKit only exists on Apple platforms; swift-crypto provides the same API elsewhere.
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "SuperOTPKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SuperOTPKit", targets: ["SuperOTPKit"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "CArgon2"),
        .target(name: "SuperOTPKit", dependencies: coreDependencies),
        .testTarget(name: "SuperOTPKitTests", dependencies: ["SuperOTPKit"]),
    ]
)
