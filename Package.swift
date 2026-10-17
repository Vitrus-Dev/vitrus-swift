// swift-tools-version:5.9
// Vitrus for Swift — cookie-free, privacy-first analytics for iOS, iPadOS
// and macOS apps. Zero dependencies: Foundation and CryptoKit only.
import PackageDescription

let package = Package(
    name: "Vitrus",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "Vitrus", targets: ["Vitrus"]),
    ],
    targets: [
        .target(
            name: "Vitrus",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "VitrusTests", dependencies: ["Vitrus"]),
    ]
)
