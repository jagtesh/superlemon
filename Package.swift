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
        .library(name: "EditorHostKit", targets: ["EditorHostKit"]),
        .library(name: "EditorEmbed", targets: ["EditorEmbed"]),
        .library(name: "SSHKit", targets: ["SSHKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stackotter/swift-cross-ui", exact: "0.8.0")
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
        // the embeddable editor: EditorHostNSView owning the
        // InputHostView + GridSurfaceView stack, chrome, and NvimController
        .target(
            name: "EditorHostKit",
            dependencies: ["NvimKit", "GridKit", "InputKit", "SurfaceKit", "ChromeKit", "ShellKit"]
        ),
        // swift-cross-ui embedding (macOS/AppKitBackend only): EditorSurface,
        // an NSViewRepresentable wrapping EditorHostNSView for host apps
        // (lemon-tmux) that render the editor as a swift-cross-ui view
        .target(
            name: "EditorEmbed",
            dependencies: [
                "EditorHostKit",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "AppKitBackend", package: "swift-cross-ui"),
            ]
        ),
        // ssh connection agent (ported from lemon-tmux): ~/.ssh/config host
        // picker source, pty-wrapped interactive auth, persisted ControlMaster
        // with command channels that reuse it without re-auth
        .target(name: "SSHKit"),
        // app shell: windows, menus, session
        .executableTarget(
            name: "SuperlemonApp",
            dependencies: ["EditorHostKit", "NvimKit", "SSHKit", "ShellKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NvimKitTests", dependencies: ["NvimKit"]),
        .testTarget(name: "GridKitTests", dependencies: ["GridKit"]),
        .testTarget(name: "InputKitTests", dependencies: ["InputKit"]),
        .testTarget(name: "SurfaceKitTests", dependencies: ["SurfaceKit"]),
        .testTarget(name: "ChromeKitTests", dependencies: ["ChromeKit"]),
        .testTarget(name: "ShellKitTests", dependencies: ["ShellKit"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"]),
        .testTarget(
            name: "SuperlemonAppTests",
            dependencies: ["EditorHostKit", "NvimKit", "SurfaceKit"]),
    ]
)
