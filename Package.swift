// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swiftui_macos_debug_server_layout_action_demo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "swiftui_macos_debug_server_layout_action_demo",
            targets: ["swiftui_macos_debug_server_layout_action_demo"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "swiftui_macos_debug_server_layout_action_demo"
        ),
    ]
)
