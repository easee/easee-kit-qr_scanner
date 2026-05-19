// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "qr_code_scanner",
    platforms: [
        .iOS("16.1")
    ],
    products: [
        .library(name: "qr-code-scanner", targets: ["qr_code_scanner"])
    ],
    targets: [
        .target(
            name: "qr_code_scanner",
            dependencies: [],
            path: "Sources/qr_code_scanner"
        )
    ]
)
