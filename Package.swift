// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoAir",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MoAir", targets: ["MoAir"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orchetect/OSCKit.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "MoAir",
            dependencies: [
                .product(name: "OSCKit", package: "OSCKit"),
            ],
            path: "Sources/MoAir",
            resources: [
                .copy("Resources/blc.png"),
                .copy("Resources/MoAir.icns"),
                .copy("Resources/moair-menu.png"),
                .copy("Resources/moair-menu@2x.png"),
                .copy("Resources/moair-menu-off.png"),
                .copy("Resources/moair-menu-off@2x.png"),
                .copy("Resources/moair-menu-track.png"),
                .copy("Resources/moair-menu-track@2x.png"),
                .copy("Resources/moai-grid.png"),
                .copy("Resources/moai-grid@2x.png"),
            ]
        ),
    ]
)
