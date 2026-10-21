// swift-tools-version: 6.0
//
// C2MSpikes: throwaway harness for the spikes in docs/spikes.md that need a
// real address book (S1, S3, S4, S5, S9, S11). Deliberately standalone: it does
// not depend on Contacts2MdSyncKit so it can't be broken by (or break) the app.
//
// The executable embeds Info.plist into its __TEXT,__info_plist section so a
// bare command-line binary carries NSContactsUsageDescription for TCC.

import PackageDescription

let infoPlistPath = Context.packageDirectory + "/Info.plist"

let package = Package(
    name: "C2MSpikes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "c2m-spike", targets: ["c2m-spike"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SpikeShim",
            linkerSettings: [.linkedFramework("Contacts")]
        ),
        .executableTarget(
            name: "c2m-spike",
            dependencies: [
                "SpikeShim",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedFramework("Contacts"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ]),
            ]
        ),
    ]
)
