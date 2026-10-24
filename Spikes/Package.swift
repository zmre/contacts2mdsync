// swift-tools-version: 6.0
//
// C2MSpikes: throwaway harness for the spikes in docs/spikes.md that need a
// real address book (S1, S3, S4, S5, S9, S11, S12, S13, S14, S15, S16). S1–S12
// use only Contacts.framework directly. S13–S16 deliberately depend on
// Contacts2MdSyncKit (path dependency) so they can exercise the real M3 Apple
// write path (`CNContactStoreAdapter.apply` → `CardWriter`), the real notes
// provider (`ScriptingNotesProvider`) and the real write routing
// (`CardWriteRouter` → `ScriptingCardWriter`, SyncEngine) against scratch
// cards. The harness never changes the kit; it only wraps it in harness-only
// guards.
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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(path: "../Packages/Contacts2MdSyncKit"),
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
                .product(name: "ContactModel", package: "Contacts2MdSyncKit"),
                .product(name: "ContactsAdapter", package: "Contacts2MdSyncKit"),
                // S16 only (`CardWriteRouter`); imported by name in that one file.
                .product(name: "SyncEngine", package: "Contacts2MdSyncKit"),
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
