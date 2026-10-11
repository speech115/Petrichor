// swift-tools-version:5.9
// Wraps the Rust core built by Scripts/build-rust-core.sh.
import PackageDescription

let package = Package(
    name: "PetrichorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PetrichorCore", targets: ["PetrichorCore"]),
    ],
    targets: [
        .binaryTarget(name: "petrichor_coreFFI", path: "build/PetrichorCoreFFI.xcframework"),
        .target(name: "PetrichorCore", dependencies: ["petrichor_coreFFI"], path: "build/swift"),
    ]
)
