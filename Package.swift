// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "BluetoothWatchCore", targets: ["BluetoothWatchCore"])]
var targets: [Target] = [
    .target(name: "BluetoothWatchCore"),
    .testTarget(name: "BluetoothWatchCoreTests", dependencies: ["BluetoothWatchCore"])
]

#if os(macOS)
products.append(.executable(name: "BluetoothWatch", targets: ["BluetoothWatch"]))
targets.append(.executableTarget(
    name: "BluetoothWatch",
    dependencies: ["BluetoothWatchCore"],
    linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
        .linkedFramework("CoreBluetooth"), .linkedFramework("IOBluetooth"),
        .linkedFramework("UserNotifications"), .linkedFramework("ServiceManagement")
    ]
))
targets.append(.testTarget(
    name: "BluetoothWatchNativeTests",
    dependencies: ["BluetoothWatch", "BluetoothWatchCore"],
    path: "Tests/BluetoothWatchNativeTests"
))
#endif

let package = Package(
    name: "BluetoothWatch",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageVersions: [.v5]
)
