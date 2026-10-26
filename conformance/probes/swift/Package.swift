// swift-tools-version: 6.2
import PackageDescription

// swift-utils pinned to the release the contract was last proven on; with
// SWIFT_UTILS set (run.sh's LOCAL), the checkout at that path.
let swiftUtils: Package.Dependency =
    if let path = Context.environment["SWIFT_UTILS"] {
        .package(path: path)
    } else {
        .package(url: "https://github.com/adriangalilea/swift-utils", exact: "0.37.23")
    }

let package = Package(
    name: "probe",
    platforms: [.macOS(.v26)],
    dependencies: [swiftUtils],
    targets: [
        .executableTarget(name: "probe", dependencies: [.product(name: "Log", package: "swift-utils")])
    ]
)
