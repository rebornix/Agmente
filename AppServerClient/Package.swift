// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppServerClient",
    platforms: [
        .iOS(.v17),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "AppServerClient",
            targets: ["AppServerClient"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AppServerClient"
        ),
        .target(
            name: "AppServerClientMocks",
            dependencies: ["AppServerClient"],
            path: "Sources/AppServerClientMocks"
        ),
        .testTarget(
            name: "AppServerClientTests",
            dependencies: ["AppServerClient", "AppServerClientMocks"]
        )
    ]
)