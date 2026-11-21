// swift-tools-version: 6.0

import Foundation
import PackageDescription

let swiftTestingPluginPath: String? = {
    let swiftcPath: String
    if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
        swiftcPath = "\(developerDirectory)/usr/bin/swiftc"
    } else {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swiftc"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        swiftcPath = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let developerRoot = URL(fileURLWithPath: swiftcPath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let path = developerRoot
        .appendingPathComponent("lib/swift/host/plugins/testing")
        .path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}()

let package = Package(
    name: "Ports",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortsCore", targets: ["PortsCore"]),
        .executable(name: "PortsApp", targets: ["PortsApp"]),
        .executable(name: "ports", targets: ["ports"])
    ],
    dependencies: [
        // The only third-party dependency (spec §1.6): the CLI's argument parsing.
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0")
    ],
    targets: [
        .target(
            name: "PortsCore",
            path: "Sources/PortsCore"
        ),
        .executableTarget(
            name: "PortsApp",
            dependencies: ["PortsCore"],
            path: "Sources/PortsApp"
        ),
        .executableTarget(
            name: "ports",
            dependencies: ["PortsCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/ports"
        ),
        .testTarget(
            name: "PortsCoreTests",
            dependencies: ["PortsCore"],
            path: "Tests/PortsCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: swiftTestingPluginPath.map {
                [
                    .unsafeFlags([
                        "-Xfrontend",
                        "-plugin-path",
                        "-Xfrontend",
                        $0
                    ])
                ]
            } ?? []
        )
    ],
    swiftLanguageModes: [.v5]
)
