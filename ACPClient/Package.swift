// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ACPClient",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ACPClient",
            targets: ["ACPClient"]),
    ],
    dependencies: [
        .package(path: "../../acp-swift-sdk")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ACPClient",
            dependencies: [
                .product(name: "ACP", package: "acp-swift-sdk")
            ]
        ),
        .target(
            name: "ACPClientMocks",
            dependencies: ["ACPClient"],
            path: "Sources/ACPClientMocks"
        ),
        .testTarget(
            name: "ACPClientTests",
            dependencies: ["ACPClient", "ACPClientMocks"]
        ),
    ]
)