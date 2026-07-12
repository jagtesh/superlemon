// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "superlemon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "superlemon", targets: ["SuperlemonApp"]),
        .library(name: "NvimKit", targets: ["NvimKit"]),
        .library(name: "GridKit", targets: ["GridKit"]),
        .library(name: "InputKit", targets: ["InputKit"]),
        .library(name: "SurfaceKit", targets: ["SurfaceKit"]),
        .library(name: "ChromeKit", targets: ["ChromeKit"]),
        .library(name: "ShellKit", targets: ["ShellKit"]),
    ],
    targets: [
        // msgpack-RPC session, nvim process lifecycle, redraw-event decoding
        .target(name: "NvimKit"),
        // grid model: cells, highlight table, damage tracking, event application
        .target(name: "GridKit", dependencies: ["NvimKit"]),
        // NSEvent -> nvim key notation, IME glue, mouse/trackpad accumulator
        .target(name: "InputKit"),
        // GridSurfaceView: CALayer tree, Core Text raster, cursor
        .target(name: "SurfaceKit", dependencies: ["GridKit"]),
        // externalized nvim UI as native AppKit: cmdline, popupmenu, messages
        .target(name: "ChromeKit", dependencies: ["NvimKit"], exclude: ["WIRING.md"]),
        // native workspace chrome: sidebar, status bar, quick-open palette
        .target(name: "ShellKit", exclude: ["WIRING.md"]),
        // app shell: windows, menus, session
        .executableTarget(
            name: "SuperlemonApp",
            dependencies: ["NvimKit", "GridKit", "InputKit", "SurfaceKit", "ChromeKit", "ShellKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NvimKitTests", dependencies: ["NvimKit"]),
        .testTarget(name: "GridKitTests", dependencies: ["GridKit"]),
        .testTarget(name: "InputKitTests", dependencies: ["InputKit"]),
        .testTarget(name: "SurfaceKitTests", dependencies: ["SurfaceKit"]),
        .testTarget(name: "ChromeKitTests", dependencies: ["ChromeKit"]),
        .testTarget(name: "ShellKitTests", dependencies: ["ShellKit"]),
        .testTarget(
            name: "SuperlemonAppTests",
            dependencies: ["SuperlemonApp", "NvimKit", "SurfaceKit"]),
    ]
)
