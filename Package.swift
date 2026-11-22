// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wattline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WattlineWidget",
            path: "Sources/WattlineWidget",
            swiftSettings: [.unsafeFlags(["-Osize", "-application-extension"])],
            linkerSettings: [.linkedFramework("WidgetKit"), .linkedFramework("IOKit"),
                             .unsafeFlags(["-Xlinker", "-dead_strip", "-Xlinker", "-application_extension",
                                            "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "Wattline",
            path: "Sources/Wattline",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("GameController"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WidgetKit"),
                .unsafeFlags(["-Xlinker", "-dead_strip"]),
            ]
        )
    ]
)
