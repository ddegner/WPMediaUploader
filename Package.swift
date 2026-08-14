// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WordpressMediaUploader",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "WordpressMediaUploaderApp",
            targets: ["WordpressMediaUploaderApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WordpressMediaUploaderApp",
            path: "Sources/WordpressImageUploaderApp",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "WPMediaUploader.entitlements",
                "AvifencHelper.entitlements"
            ]
        ),
        .testTarget(
            name: "WordpressMediaUploaderAppTests",
            dependencies: ["WordpressMediaUploaderApp"],
            path: "Tests"
        )
    ]
)
