// swift-tools-version:6.0
import PackageDescription

// FFmpeg is built from source and linked statically (Vendor/ffmpeg/build-mac.sh),
// so the app runs on any Apple Silicon Mac without Homebrew.
let ffmpeg = "Vendor/ffmpeg/mac"

let package = Package(
    name: "TapoCam",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CStream",
            path: "Sources/CStream",
            cSettings: [.unsafeFlags(["-I\(ffmpeg)/include"])],
            linkerSettings: [
                .unsafeFlags([
                    "\(ffmpeg)/lib/libavformat.a",
                    "\(ffmpeg)/lib/libavcodec.a",
                    "\(ffmpeg)/lib/libswscale.a",
                    "\(ffmpeg)/lib/libavutil.a",
                ]),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "TapoCam",
            dependencies: ["CStream"],
            path: "Sources/TapoCam",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
