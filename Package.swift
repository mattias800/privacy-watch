// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PrivacyWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PrivacyWatch",
            path: "Sources/PrivacyWatch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
