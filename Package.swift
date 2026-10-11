// swift-tools-version: 6.0
import PackageDescription

// Compile and test the location library on macOS without iOS signing or VPN setup.
let package = Package(
    name: "WLOCLocationLibrary",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [.library(name: "WLOCLocationLibrary", targets: ["WLOCLocationLibrary"])],
    targets: [
        .target(
            name: "WLOCLocationLibrary",
            path: "WLOC/MainApp/LocationLibrary"
        ),
        .testTarget(
            name: "WLOCLocationLibraryTests",
            dependencies: ["WLOCLocationLibrary"],
            path: "WLOCTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
