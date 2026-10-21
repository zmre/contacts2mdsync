// swift-tools-version: 6.0
//
// Contacts2MdSyncKit: all non-UI logic for Contacts2MdSync lives here so it can
// be built and tested with `swift test` without Xcode or the app target.
//
// Dependency graph (arrows point at dependencies):
//
//   SyncTestSupport -> SyncEngine -> ContactsAdapter -> ContactModel, ContactsShim
//                                 -> VaultIndex      -> ContactModel, MarkdownCodec
//                                 -> MarkdownCodec   -> Yams
//                                 -> ContactModel
//
// TODO(M1+): add PhoneNumberKit (phone normalization), GRDB (sync state store),
// and swift-argument-parser (contacts2md-cli) when the features that need them
// land. Deferred to keep M0 lean.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Contacts2MdSyncKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "ContactModel", targets: ["ContactModel"]),
        .library(name: "MarkdownCodec", targets: ["MarkdownCodec"]),
        .library(name: "ContactsShim", targets: ["ContactsShim"]),
        .library(name: "ContactsAdapter", targets: ["ContactsAdapter"]),
        .library(name: "VaultIndex", targets: ["VaultIndex"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "SyncTestSupport", targets: ["SyncTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0")
    ],
    targets: [
        .target(
            name: "ContactModel",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MarkdownCodec",
            dependencies: [
                "ContactModel",
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ContactsShim",
            linkerSettings: [.linkedFramework("Contacts")]
        ),
        .target(
            name: "ContactsAdapter",
            dependencies: ["ContactModel", "ContactsShim"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VaultIndex",
            dependencies: ["ContactModel", "MarkdownCodec"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SyncEngine",
            dependencies: [
                "ContactModel",
                "MarkdownCodec",
                "ContactsAdapter",
                "VaultIndex",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SyncTestSupport",
            dependencies: ["SyncEngine"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ContactModelTests",
            dependencies: ["ContactModel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MarkdownCodecTests",
            dependencies: ["MarkdownCodec"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine", "SyncTestSupport"],
            swiftSettings: swiftSettings
        ),
    ]
)
