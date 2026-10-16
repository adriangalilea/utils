// swift-tools-version: 6.2
import PackageDescription

// swift-utils pinned by revision; with SWIFT_UTILS set (run.sh's LOCAL), the
// checkout at that path.
let swiftUtils: Package.Dependency =
    if let path = Context.environment["SWIFT_UTILS"] {
        .package(path: path)
    } else {
        .package(url: "https://github.com/adriangalilea/swift-utils", revision: "09a71f087f60b26eb6b0b4e378b0a0535553e3b5")
    }

let package = Package(
    name: "probe",
    platforms: [.macOS(.v26)],
    dependencies: [swiftUtils],
    targets: [
        .executableTarget(name: "probe", dependencies: [.product(name: "Log", package: "swift-utils")])
    ]
)
